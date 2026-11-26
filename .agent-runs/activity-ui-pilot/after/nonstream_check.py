"""Negative check: same prompt on channel `webchat` (non-streaming) -> expect ONE final message.
Runs a stub connector that records every activity the agent sends, then POSTs the inbound activity to :8090.
Usage: python nonstream_check.py [channelId]   (run from anywhere; stdlib only)
"""
import json, sys, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

channel = sys.argv[1] if len(sys.argv) > 1 else "webchat"
sent = []
t0 = time.time()


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        a = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)) or b"{}")
        sent.append((round(time.time() - t0, 2), a))
        body = json.dumps({"id": f"r{len(sent)}"}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_PUT = do_POST
    def log_message(self, *a): pass


srv = HTTPServer(("127.0.0.1", 9099), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
act = {"type": "message", "id": "in1", "channelId": channel, "text": "summarise my inbox and today's calendar",
       "from": {"id": "user-id-0", "name": "Alex Wilber"}, "recipient": {"id": "bot", "name": "Test Bot"},
       "conversation": {"id": "nonstream-1", "conversationType": "personal"}, "serviceUrl": "http://127.0.0.1:9099",
       "locale": "en-US"}
req = urllib.request.Request("http://127.0.0.1:8090/api/messages", json.dumps(act).encode(),
                             {"content-type": "application/json"})
print("POST ->", urllib.request.urlopen(req, timeout=120).status, f"after {time.time()-t0:.1f}s")
time.sleep(2)
for t, a in sent:
    print(f"+{t}s type={a.get('type')} textFormat={a.get('textFormat')} len={len(a.get('text') or '')} "
          f"attachments={len(a.get('attachments') or [])} text={(a.get('text') or '')[:70]!r}")
for _, a in sent:
    if a.get("type") == "message": print(json.dumps(a)[:600])
print("messages:", sum(1 for _, a in sent if a.get("type") == "message"), "| typing:", sum(1 for _, a in sent if a.get("type") == "typing"))
