"""Exercise packaged Mainsail and Guix-generated nginx configurations, unprivileged.

Invoked by tests/mainsail.scm. A local mock Moonraker/webcam backend verifies
HTTP, upload and WebSocket forwarding without printer hardware.
"""

import base64
import gzip
import hashlib
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


directory, package, nginx, default_config, config = map(Path, sys.argv[1:6])
port, backend_port = map(int, sys.argv[6:])
root = package / "share/mainsail"
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for path in ("logs", "run/logs", "run/client_body_temp", "run/proxy_temp",
             "run/fastcgi_temp", "run/uwsgi_temp", "run/scgi_temp"):
    (directory / path).mkdir(parents=True, exist_ok=True)


def request(path, data=None, headers=None):
    with http.open(urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                         headers=headers or {}), timeout=10) as response:
        return response.read(), response.headers


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.paths = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value and not urllib.parse.urlsplit(value).netloc:
                self.paths.add("/" + value.lstrip("/"))


def read_exact(stream, length):
    data = b""
    while len(data) < length:
        part = stream.read(length - len(data))
        if not part:
            raise EOFError("Incomplete WebSocket frame")
        data += part
    return data


class Backend(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/websocket":
            assert self.headers["Upgrade"].lower() == "websocket"
            assert self.headers["Connection"].lower() == "upgrade"
            accept = base64.b64encode(hashlib.sha1(
                (self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            frame = read_exact(self.rfile, 2)
            assert frame[0] == 0x81 and frame[1] & 0x80
            length = frame[1] & 0x7F
            assert length < 126
            mask = read_exact(self.rfile, 4)
            payload = read_exact(self.rfile, length)
            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            self.wfile.write(bytes([0x81, length]) + payload)
            self.wfile.flush()
            self.close_connection = True
        else:
            self.reply()

    def do_POST(self):
        self.reply(self.rfile.read(int(self.headers["Content-Length"])))

    def reply(self, body=b""):
        payload = json.dumps({"path": self.path, "headers": dict(self.headers),
                              "size": len(body), "sha256": hashlib.sha256(body).hexdigest()}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


with (directory / "nginx.log").open("w+") as log:
    for candidate in (default_config, config):
        subprocess.run([nginx, "-t", "-p", directory / "run", "-c", candidate],
                       stdout=log, stderr=log, check=True)
    print("PASS: default and customized nginx configurations pass nginx -t")
    process = subprocess.Popen(
        [nginx, "-p", directory / "run", "-c", config, "-g", "daemon off;"],
        stdout=log, stderr=log,
    )
    backend = None
    try:
        deadline = time.monotonic() + 15
        while True:
            if process.poll() is not None:
                raise RuntimeError("nginx exited")
            try:
                index, headers = request("/")
                break
            except (OSError, urllib.error.URLError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        assert index == (root / "index.html").read_bytes()
        assert request("/settings/interface")[0] == index
        assert (root / ".version").read_text() == "v2.19.0"
        assert json.loads((root / "release_info.json").read_text())["version"] == "v2.19.0"
        assert (package / "share/doc/mainsail-2.19.0/LICENSE").is_file()
        refs = References()
        refs.feed(index.decode())
        for path in refs.paths:
            content, _ = request(path)
            assert content == (root / path.lstrip("/")).read_bytes(), path
        compressed, headers = request("/index.html", headers={"Accept-Encoding": "gzip"})
        assert headers["Content-Encoding"] == "gzip" and gzip.decompress(compressed) == index
        assert "Accept-Encoding" in headers["Vary"]
        for path in ("/index.html", "/config.json", "/sw.js"):
            assert "no-store" in request(path)[1]["Cache-Control"], path
        assert json.loads(request("/config.json")[0]) == {"defaultLocale": "de"}
        assert json.loads((root / "config.json").read_text())["defaultLocale"] == "en"
        print("PASS: release assets, SPA fallback, gzip, cache policy and immutable config.json override")

        try:
            request("/server/info")
            raise AssertionError("Expected unavailable backend")
        except urllib.error.HTTPError as error:
            assert error.code == 502, error
        backend = ThreadingHTTPServer(("127.0.0.1", backend_port), Backend)
        threading.Thread(target=backend.serve_forever, daemon=True).start()
        for prefix in ("printer", "api", "access", "machine", "server"):
            path = f"/{prefix}/info?path=%2Ffoo%20bar"
            reply = json.loads(request(path)[0])
            assert reply["path"] == path, reply
            assert reply["headers"]["Host"] == f"127.0.0.1:{port}", reply
            assert reply["headers"]["X-Real-IP"] == "127.0.0.1", reply
            assert reply["headers"]["X-Forwarded-For"] == "127.0.0.1", reply
            assert reply["headers"]["X-Scheme"] == "http", reply
        upload = b"G1 X1 Y1\n" * 250000  # Exceeds nginx's default 1 MiB body limit.
        reply = json.loads(request("/server/files/upload", data=upload)[0])
        assert reply["size"] == len(upload) and reply["sha256"] == hashlib.sha256(upload).hexdigest()
        for prefix in ("webcam", "webcam2", "webcam3", "webcam4"):
            reply = json.loads(request(f"/{prefix}/stream?action=snapshot")[0])
            assert reply["path"] == "/stream?action=snapshot", reply
        print("PASS: backend recovery, all API prefixes, encoded queries, large uploads and four webcam routes")

        with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
            connection.sendall(
                f"GET /websocket HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode()
            )
            stream = connection.makefile("rb")
            assert stream.readline().startswith(b"HTTP/1.1 101")
            while True:
                line = stream.readline()
                if line == b"\r\n":
                    break
                if not line:
                    raise EOFError("Incomplete WebSocket handshake")
            payload, mask = b"mainsail-proxy-test", b"mask"
            connection.sendall(bytes([0x81, 0x80 | len(payload)]) + mask
                               + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))
            assert read_exact(stream, 2) == bytes([0x81, len(payload)])
            assert read_exact(stream, len(payload)) == payload
            stream.close()
        print("PASS: WebSocket upgrade and bidirectional frame forwarding")
    except BaseException:
        log.flush()
        log.seek(0)
        print(log.read(), file=sys.stderr)
        for name in ("access.log", "error.log"):
            file = directory / "logs" / name
            if file.exists():
                print(file.read_text(), file=sys.stderr)
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        if backend:
            backend.shutdown()
            backend.server_close()
