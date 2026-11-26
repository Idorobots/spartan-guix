#!/usr/bin/env python3
"""Smoke-test a built target exporter, with native or transparent QEMU execution.

Usage: python3 tests/runtime/node-exporter.py STORE/bin/node_exporter linux/arm
"""

import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    binary, platform = sys.argv[1:]
    version = subprocess.check_output(
        [binary, "--version"], stderr=subprocess.STDOUT, text=True, timeout=30
    )
    assert "version 1.10.2" in version, version
    assert f"platform:         {platform}" in version, version

    with tempfile.TemporaryDirectory(prefix="spartan-node-exporter-") as directory:
        pathlib.Path(directory, "probe.prom").write_text(
            "# HELP spartan_cross_build_probe Cross-build smoke test.\n"
            "# TYPE spartan_cross_build_probe gauge\n"
            "spartan_cross_build_probe 42\n"
        )
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]

        process = subprocess.Popen(
            [
                binary,
                f"--web.listen-address=127.0.0.1:{port}",
                "--web.disable-exporter-metrics",
                "--collector.disable-defaults",
                "--collector.textfile",
                f"--collector.textfile.directory={directory}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise AssertionError(process.stdout.read())
                try:
                    with urllib.request.urlopen(
                        f"http://127.0.0.1:{port}/metrics", timeout=2
                    ) as response:
                        metrics = response.read().decode()
                    break
                except (urllib.error.URLError, TimeoutError):
                    time.sleep(0.1)
            else:
                raise AssertionError("exporter did not become ready")

            assert "spartan_cross_build_probe 42\n" in metrics, metrics
            assert "node_textfile_scrape_error 0\n" in metrics, metrics
            print(f"PASS: exporter 1.10.2 runs on {platform} and serves collected metrics")
        finally:
            process.terminate()
            try:
                process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    main()
