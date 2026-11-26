"""Logging reverse proxy: Playground -> :8091 -> agent :8090.

Records each INBOUND activity (channelId, recipient/from role, agentic markers)
with a timestamp to inbound.jsonl. Stdlib only. Usage: python inbound_proxy.py
"""
import json, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = "http://127.0.0.1:8090"
LOG = "inbound.jsonl"


class H(BaseHTTPRequestHandler):
    def _do(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n)
        t0 = time.time()
        try:
            a = json.loads(body or b"{}")
        except Exception:
            a = {}
        rec = {
            "ts": time.strftime("%H:%M:%S", time.localtime(t0)) + f".{int((t0%1)*1000):03d}",
            "method": self.command, "path": self.path,
            "type": a.get("type"), "channelId": a.get("channelId"),
            "text": a.get("text"),
            "from": a.get("from"), "recipient": a.get("recipient"),
            "serviceUrl": a.get("serviceUrl"),
            "channelData_keys": list((a.get("channelData") or {}).keys()),
            "has_auth_header": "authorization" in {k.lower() for k in self.headers},
        }
        req = urllib.request.Request(UP + self.path, data=body or None, method=self.command,
                                     headers={k: v for k, v in self.headers.items() if k.lower() != "host"})
        try:
            r = urllib.request.urlopen(req, timeout=300)
            code, data = r.status, r.read()
        except urllib.error.HTTPError as e:
            code, data = e.code, e.read()
        rec["status"] = code
        rec["handler_seconds"] = round(time.time() - t0, 2)
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
        self.send_response(code)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = do_GET = _do

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("127.0.0.1", 8091), H).serve_forever()
