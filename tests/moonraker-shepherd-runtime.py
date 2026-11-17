"""Check installed packages and service-generated files with a private Shepherd.

Invoked by tests/moonraker.scm. The sudo adapter grants no privileges; policy
power actions are empty and every Shepherd command uses the private socket.
"""

import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request


root, moonraker, provider, shepherd, configuration, policy, sleep = map(Path, sys.argv[1:])
helper = provider / "bin/moonraker-shepherd"
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
data = root / "data"
for directory in ("config", "logs", "gcodes", "comms", "database"):
    (data / directory).mkdir(parents=True)
# Store policy is root-owned, whereas this test's helper is deliberately
# unprivileged. Copy only for matching test ownership, retaining generated data.
test_policy = root / "policy.scm"
test_policy.write_bytes(policy.read_bytes())
test_policy.chmod(0o444)
sudo = root / "sudo"
sudo.write_text(
    f"#!{sys.executable}\nimport os,sys\n"
    "assert sys.argv[1:3] == ['-n', '--']\nos.execv(sys.argv[3], sys.argv[3:])\n"
)
sudo.chmod(0o755)
test_configuration = root / "moonraker.conf"
test_configuration.write_text(configuration.read_text().replace(str(policy), str(test_policy))
                              .replace("/run/privileged/bin/sudo", str(sudo)))
(root / "application.conf").write_text(
    f"[server]\nhost: 127.0.0.1\nport: {port}\n"
    f"klippy_uds_address: {root / 'missing-klippy.sock'}\n"
    "[machine]\nprovider: none\nvalidate_service: True\n"
    "[include authorization.conf]\n"
)
(root / "authorization.conf").write_text("[authorization]\ntrusted_clients: 127.0.0.1/32\n")
environment = {"HOME": str(data), "LC_ALL": "C", "PATH": "/nonexistent"}
quote = lambda value: json.dumps(str(value))
command = [moonraker / "bin/moonraker", "-d", data, "-c", test_configuration]
fixture = root / "shepherd.scm"
fixture.write_text(
    "(use-modules (shepherd service))\n(register-services (list\n"
    " (service '(klipper) #:respawn? #f\n"
    f"  #:start (make-forkexec-constructor (list {quote(sleep)} \"300\"))\n"
    "  #:stop (make-kill-destructor))\n"
    " (service '(moonraker) #:respawn? #f\n"
    f"  #:start (make-forkexec-constructor (list {' '.join(map(quote, command))})\n"
    f"   #:environment-variables (list {' '.join(quote(k + '=' + v) for k, v in environment.items())}))\n"
    "  #:stop (make-kill-destructor))))\n"
    "(start-service (lookup-service 'moonraker))\n"
)


def api(endpoint, data=None):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{endpoint}",
        data=None if data is None else json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
    )
    with http.open(request, timeout=5) as response:
        return json.load(response)["result"]


def status():
    response = subprocess.run([helper, test_policy, "status"], env=environment,
                              capture_output=True, text=True, check=True, timeout=15)
    return json.loads(response.stdout)["result"]["services"]


def wait_for(callback):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if daemon.poll() is not None:
            raise RuntimeError("Private Shepherd exited")
        try:
            value = callback()
            if value:
                return value
        except (OSError, urllib.error.URLError, subprocess.CalledProcessError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Timed out waiting for private test service")


with (root / "runtime.log").open("w+") as log:
    daemon = subprocess.Popen(
        [shepherd / "bin/shepherd", "--socket", root / "socket", "--config", fixture,
         "--logfile", root / "shepherd.log"], env=environment, stdout=log, stderr=log,
    )
    try:
        info = wait_for(lambda: api("/machine/system_info"))["system_info"]
        assert info["provider"] == "shepherd", info
        assert set(info["available_services"]) == {"klipper", "moonraker"}, info
        assert status()["klipper"]["active_state"] == "inactive"
        assert api("/machine/sudo/info?check_access=true")["sudo_access"]
        assert not api("/server/info")["warnings"]
        print("PASS: generated settings override application provider; relative includes and installed sudo diagnostic work")
        old = status()["moonraker"]["pid"]
        for action in ("start", "restart", "stop"):
            assert api(f"/machine/services/{action}", {"service": "klipper"}) == "ok"
            expected = "inactive" if action == "stop" else "active"
            assert status()["klipper"]["active_state"] == expected
            assert status()["moonraker"]["pid"] == old
        assert api("/machine/services/start", {"service": "klipper"}) == "ok"
        print("PASS: installed helper starts/restarts/stops Klipper while Moonraker remains available")
        try:
            api("/machine/services/stop", {"service": "moonraker"})
            raise AssertionError("Moonraker stop must be denied")
        except urllib.error.HTTPError as error:
            assert error.code == 400 and "not available for moonraker" in error.reason, error
        denied = subprocess.run([helper, test_policy, "poweroff"], env=environment,
                                capture_output=True, text=True, timeout=15)
        assert denied.returncode and json.loads(denied.stdout)["error"]["code"] == "denied"
        assert api("/machine/services/restart", {"service": "moonraker"}) == "ok"
        wait_for(lambda: status()["moonraker"]["pid"] not in (None, old))
        wait_for(lambda: api("/machine/system_info"))
        assert api("/machine/sudo/info?check_access=true")["sudo_access"]
        print("PASS: self-restart survives process-group shutdown; policy denies Moonraker stop and poweroff")
    except BaseException:
        log.flush()
        log.seek(0)
        print(log.read(), file=sys.stderr)
        if (root / "shepherd.log").exists():
            print((root / "shepherd.log").read_text(), file=sys.stderr)
        raise
    finally:
        try:
            subprocess.run([shepherd / "bin/herd", "--socket", root / "socket", "stop", "root"],
                           env=environment, stdout=log, stderr=log, timeout=10)
            daemon.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            daemon.kill()
            daemon.wait()
