#!/usr/bin/env python3
"""LAB/DEMO ONLY: answer 200 with the port and path on every GET."""
import http.server
import socketserver
import sys

PORT = int(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"demo backend on port {PORT}: {self.path}\n".encode())

    def log_message(self, *args):
        pass


socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", PORT), Handler).serve_forever()
