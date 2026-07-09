import http.server
import itertools
import json
import time

COUNTER = itertools.count(1)


class Handler(http.server.BaseHTTPRequestHandler):
    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        record = {
            "ts": time.strftime("%H:%M:%S"),
            "method": self.command,
            "path": self.path,
            "headers": dict(self.headers),
            "body": body,
        }
        print("ECHO " + json.dumps(record), flush=True)
        status = 200
        if self.path.startswith("/token"):
            token = "POC-TOKEN-N%03d" % next(COUNTER)
            resp = {"access_token": token, "expires_in": 300, "received_body": body}
        elif "/fail" in self.path:
            status = 500
            resp = {"error": "panne simulee pour la sonde d'erreur du seeder", "path": self.path,
                    "received_headers": dict(self.headers)}
        else:
            resp = {"echo": True, "path": self.path, "received_headers": dict(self.headers), "received_body": body}
        data = json.dumps(resp).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = _handle

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("", 8080), Handler).serve_forever()
