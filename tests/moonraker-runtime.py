"""Exercise installed Moonraker and Klippy without printer hardware.

Usage: python3 tests/moonraker-runtime.py MOONRAKER-PACKAGE KLIPPER-PACKAGE
"""

import configparser
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


moonraker, klipper = (Path(arg).resolve() for arg in sys.argv[1:])
default_file = Path(__file__).resolve().parents[1] / "modules/spartan/services/moonraker.conf"
# Avoid inherited proxy settings as well as Python/virtualenv configuration.
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(base, path, *, data=None, headers=None, method=None):
    req = urllib.request.Request(base + path, data=data, headers=headers or {}, method=method)
    with http.open(req, timeout=5) as response:
        return json.load(response), response.headers


def wait_for(callback, processes, description):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if any(process.poll() is not None for process in processes):
            raise RuntimeError(f"process exited while waiting for {description}")
        try:
            value = callback()
            if value:
                return value
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {description}")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


with tempfile.TemporaryDirectory(prefix="moonraker-test-") as directory:
    root = Path(directory)
    data, state = root / "moonraker", root / "klipper"
    state.mkdir()
    for suffix in ("", "logs", "gcodes", "comms", "database"):
        (data / suffix).mkdir(exist_ok=True)
    (data / "config").symlink_to(state, target_is_directory=True)
    printer = state / "printer.cfg"
    # Klippy exposes its API even when this intentionally incomplete printer
    # configuration cannot initialize an MCU.
    printer.write_text("[printer]\nkinematics: cartesian\nmax_velocity: 100\nmax_accel: 1000\n")
    original_printer = printer.read_bytes()
    klippy_socket = root / "klippy.sock"
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    config = configparser.ConfigParser(interpolation=None)
    config.read(default_file)
    assert not any(section.startswith("update_manager") for section in config.sections())
    config["server"].update(host="127.0.0.1", port=str(port),
                            klippy_uds_address=str(klippy_socket))
    configuration = root / "moonraker.conf"
    with configuration.open("w") as output:
        config.write(output)
    configuration.chmod(0o444)
    original_configuration = configuration.read_bytes()
    environment = {"HOME": str(data), "LC_ALL": "C", "PATH": "/nonexistent"}
    processes = []
    with (root / "runtime.log").open("w+") as log:
        try:
            subprocess.run([str(moonraker / "bin/moonraker"), "--help"],
                           env=environment, stdout=log, stderr=log, check=True)
            processes.append(subprocess.Popen(
                [str(klipper / "bin/klippy"), str(printer), "-a", str(klippy_socket),
                 "-I", str(root / "printer"), "-l", str(state / "klippy.log")],
                env=environment, stdout=log, stderr=log,
            ))

            def start_moonraker():
                process = subprocess.Popen(
                    [str(moonraker / "bin/moonraker"), "-d", str(data),
                     "-c", str(configuration)], cwd=data, env=environment,
                    stdout=log, stderr=log,
                )
                processes.append(process)
                return process

            server = start_moonraker()

            def connected():
                info = request(base, "/server/info")[0]["result"]
                return info if info["klippy_connected"] and info["klippy_state"] == "error" else None

            info = wait_for(connected, processes, "Moonraker's Klippy connection")
            assert info["failed_components"] == [], info
            assert "update_manager" not in info["components"], info
            assert not info["warnings"], info["warnings"]
            assert request(base, "/printer/info")[0]["result"]["state"] == "error"
            print("PASS: clean-environment Moonraker starts and reaches packaged Klippy")

            for origin in ("http://printer.local", "https://printer.local:8443",
                           "http://localhost", "http://localhost:8080",
                           "http://192.168.1.2:8080"):
                _, headers = request(base, "/server/info", headers={"Origin": origin})
                assert headers.get("Access-Control-Allow-Origin") == origin, origin
            try:
                _, headers = request(base, "/server/info",
                                     headers={"Origin": "https://untrusted.example"})
                assert "Access-Control-Allow-Origin" not in headers
            except urllib.error.HTTPError as error:
                assert error.code == 401
            print("PASS: local-domain, localhost and trusted-network CORS")

            roots = request(base, "/server/files/roots")[0]["result"]
            assert any(item["name"] == "config" and Path(item["path"]) == state
                       and item["permissions"] == "rw" for item in roots), roots
            filename = "part.gcode"
            gcode = (b"; generated by PrusaSlicer 2.7.0 on 2026-01-01 at 12:00:00\n"
                     b"; layer_height = 0.2\nG28\nG1 X1 Y1 Z0.2\n")
            boundary = "spartan-moonraker-test"
            body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                    f"filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
                    ).encode() + gcode + f"\r\n--{boundary}--\r\n".encode()
            uploaded, _ = request(base, "/server/files/upload", data=body,
                                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
            assert uploaded["item"]["path"] == filename, uploaded
            assert (data / "gcodes" / filename).read_bytes() == gcode
            metadata = request(base, "/server/files/metadata?filename=" + filename)[0]["result"]
            assert metadata["size"] == len(gcode), metadata
            assert metadata["slicer"] == "PrusaSlicer", metadata
            print("PASS: upload and metadata subprocess work without host Python paths")

            saved_value = json.dumps({"namespace": "webcams", "key": "smoke-test",
                                      "value": {"persisted": True}}).encode()
            request(base, "/server/database/item", data=saved_value,
                    headers={"Content-Type": "application/json"})
            stop(server)
            processes.remove(server)
            server = start_moonraker()
            wait_for(connected, processes, "Moonraker restart")
            saved = request(base, "/server/database/item?namespace=webcams&key=smoke-test")[0]
            assert saved["result"]["value"] == {"persisted": True}, saved
            assert (data / "gcodes" / filename).read_bytes() == gcode
            assert configuration.read_bytes() == original_configuration
            assert printer.read_bytes() == original_printer
            print("PASS: database/uploads persist and declarative configuration is unchanged")
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            for process in reversed(processes):
                stop(process)
