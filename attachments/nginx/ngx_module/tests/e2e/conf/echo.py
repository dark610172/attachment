import hashlib, http.server
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        h = hashlib.sha256(); n = 0
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0: self.rfile.readline(); break
                d = self.rfile.read(size); self.rfile.readline(); h.update(d); n += len(d)
        else:
            left = int(self.headers.get("Content-Length", 0))
            while left:
                d = self.rfile.read(min(left, 1 << 20)); h.update(d); n += len(d); left -= len(d)
        b = ("%d %s\n" % (n, h.hexdigest())).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
