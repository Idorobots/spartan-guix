"""Exercise the installed driver/server/client chain without UPS hardware.

Usage: python3 tests/nut-runtime.py $(guix build -L modules nut --no-grafts)
"""

import os
from pathlib import Path
import pwd
import socket
import subprocess
import sys
import tempfile
import time


package = Path(sys.argv[1])
user = pwd.getpwuid(os.getuid()).pw_name
with tempfile.TemporaryDirectory(prefix="nut-test-") as directory:
    root = Path(directory)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    (root / "device.dev").write_text("ups.status: OL\nbattery.charge: 100\n")
    (root / "ups.conf").write_text(
        f"statepath = {root}\n[simulated]\ndriver = dummy-ups\n"
        f"port = {root}/device.dev\nmode = dummy-once\n"
    )
    (root / "upsd.conf").write_text(
        f"STATEPATH {root}\nLISTEN 127.0.0.1 {port}\n"
    )
    (root / "upsd.users").write_text("")
    environment = dict(os.environ, NUT_CONFPATH=str(root),
                       NUT_STATEPATH=str(root), NUT_ALTPIDPATH=str(root))
    processes = []
    with (root / "runtime.log").open("w+") as log:
        try:
            for executable, args in [
                ("libexec/nut/dummy-ups", ["-a", "simulated"]),
                ("sbin/upsd", []),
            ]:
                processes.append(subprocess.Popen(
                    [str(package / executable), "-F", "-u", user, *args],
                    env=environment, stdout=log, stderr=log,
                ))
            for _ in range(50):
                result = subprocess.run(
                    [str(package / "bin/upsc"),
                     f"simulated@127.0.0.1:{port}", "ups.status"],
                    capture_output=True, text=True, env=environment,
                )
                if result.returncode == 0 and result.stdout.strip() == "OL":
                    print("PASS: dummy-ups → upsd → upsc reports OL")
                    break
                time.sleep(0.1)
            else:
                log.seek(0)
                raise RuntimeError(log.read() + result.stderr)
        finally:
            for process in reversed(processes):
                process.terminate()
            for process in processes:
                process.wait(timeout=10)
