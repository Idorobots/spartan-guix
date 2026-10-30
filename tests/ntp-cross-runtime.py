"""Check cross-built NTP's Perl HTTPS stack without binfmt or changing the clock.

Usage: python3 tests/ntp-cross-runtime.py NTP_STORE_PATH QEMU_AARCH64
Requires Python 3, native openssl, and an explicit qemu-aarch64 executable.
"""

import hashlib
import http.server
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile
import threading


ntp, qemu = sys.argv[1:]
script = Path(ntp, "bin/update-leap")
wrapper = script.read_text()
guile = re.search(r"^#!(/gnu/store/[^\s]+/bin/guile) ", wrapper).group(1)
assert Path(guile).is_file(), "missing target Guile in update-leap wrapper"
perl = re.search(r'execl "([^\"]+/bin/perl)"', wrapper).group(1)
paths = re.findall(r"/gnu/store/[^:\s\"]+/lib/perl5/site_perl", wrapper)
env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
env.update(LC_ALL="C", PERL5LIB=":".join(dict.fromkeys(paths)))


def run_perl(*args):
    return subprocess.run(
        [qemu, perl, *args], env=env, check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
    ).stdout


print(run_perl(
    "-MErrno=EINTR,EPIPE", "-MHTTP::Tiny", "-MIO::Socket::SSL", "-MNet::SSLeay",
    "-e", 'die "bad errno" unless EINTR == 4 && EPIPE == 32; '
    'my ($ok, $why) = HTTP::Tiny->new->can_ssl; die $why unless $ok; '
    'print Net::SSLeay::SSLeay_version(0), " TLS ready\\n";',
).strip())
assert "Usage: update-leap" in run_perl(str(script), "-h")
print("PASS: update-leap help loads all runtime modules")
assert "4.2.8" in subprocess.check_output(
    [qemu, str(Path(ntp, "bin/ntpd")), "--version"], env=env, text=True,
    timeout=60,
)

payload = b"NTP cross-build TLS regression\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


with tempfile.TemporaryDirectory(prefix="ntp-cross-") as directory:
    cert, key = (str(Path(directory, name)) for name in ("cert.pem", "key.pem"))
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
         "-keyout", key, "-out", cert],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        timeout=30,
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = run_perl(
            "-MHTTP::Tiny", "-MDigest::SHA=sha256_hex", "-e",
            'my ($url, $ca) = @ARGV; '
            'my $r = HTTP::Tiny->new(verify_SSL => 1, SSL_options => '
            '{SSL_ca_file => $ca})->get($url); '
            'die "$r->{status} $r->{content}" unless $r->{success}; '
            'print sha256_hex($r->{content});',
            f"https://localhost:{server.server_port}/", cert,
        )
        assert result == hashlib.sha256(payload).hexdigest()
        print("PASS: AArch64 Perl HTTPS download with certificate verification")
        result = run_perl(
            "-MHTTP::Tiny", "-e",
            'my $r = HTTP::Tiny->new(verify_SSL => 1)->get($ARGV[0]); '
            'die "untrusted certificate accepted" if $r->{success}; '
            'die $r->{content} unless $r->{content} =~ /certificate verify failed/i; '
            'print "rejected";',
            f"https://localhost:{server.server_port}/",
        )
        assert result == "rejected"
        print("PASS: untrusted TLS certificate rejected")
    finally:
        server.shutdown()
        thread.join()
        server.server_close()
