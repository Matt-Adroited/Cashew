#!/usr/bin/env python3
"""Simple HTTP server for serving Flutter web build locally."""

import http.server
import socketserver
import os

PORT = 8080
WEB_DIR = os.path.join(os.path.dirname(__file__), "budget", "build", "web")


class FlutterHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin-allow-popups")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

    def log_message(self, format, *args):
        print(f"{self.address_string()} - {format % args}")


if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), FlutterHandler) as httpd:
        print(f"Serving Flutter web app at http://localhost:{PORT}")
        print(f"Serving from: {WEB_DIR}")
        print("Press Ctrl+C to stop.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nServer stopped.")
