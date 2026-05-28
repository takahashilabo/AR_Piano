#!/usr/bin/env python3
"""
HTTPS server for Godot WebXR development.
Requires cert.pem and key.pem in this directory.

Setup (one-time):
  brew install mkcert
  cd server
  mkcert -install
  mkcert 192.168.x.x localhost 127.0.0.1  # replace with your local IP
  mv 192.168.x.x+2.pem cert.pem
  mv 192.168.x.x+2-key.pem key.pem

Run:
  cd piano02
  python3 server/serve.py

Access: https://192.168.x.x:8443/export/web/index.html
"""
import http.server
import ssl
import os
import sys

# プロジェクトルートを配信 → web/midi_bridge.js を /web/midi_bridge.js で参照できる
SERVE_DIR = os.path.join(os.path.dirname(__file__), "..")
PORT = 8443


class XRHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.abspath(SERVE_DIR), **kwargs)

    def do_GET(self):
        if self.path == "/":
            self.send_response(302)
            self.send_header("Location", "/export/web/index.html")
            self.end_headers()
            return
        super().do_GET()

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, format, *args):
        print(f"[{self.address_string()}] {format % args}")


cert = os.path.join(os.path.dirname(__file__), "cert.pem")
key = os.path.join(os.path.dirname(__file__), "key.pem")

if not os.path.exists(cert) or not os.path.exists(key):
    print("ERROR: cert.pem / key.pem not found in server/")
    print("Run the mkcert setup steps described in this file's header.")
    sys.exit(1)

httpd = http.server.HTTPServer(("0.0.0.0", PORT), XRHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

import socket
local_ip = socket.gethostbyname(socket.gethostname())
print(f"Serving at https://{local_ip}:{PORT}/export/web/index.html")
httpd.serve_forever()
