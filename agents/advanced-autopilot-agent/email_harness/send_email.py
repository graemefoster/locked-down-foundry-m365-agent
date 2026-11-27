#!/usr/bin/env python3
"""Send the local agent an agentic email notification and capture the HTML reply.

No Outlook, no tenant. Stdlib only. Needs the agent running with MOCK_M365=1 (anonymous auth).

  python email_harness/send_email.py --from Alex --subject "What does my day look like?" \
      --body "Can you give me a rundown?" [--agent http://localhost:8095] [--out DIR]

How the reply is captured: the activity's serviceUrl points at a throwaway HTTP server started
here; the agent's context.send_activity() POSTs the outbound activity (carrying the
`emailResponse` entity) to it. Nothing is sent anywhere else.

--mode notification (default) sends channelId "agents:email" + an `emailNotification` entity,
the shape microsoft-agents-a365-notifications 1.0.0 parses (AgentNotificationActivity.email).
--mode plain sends a normal Teams-style message (negative check: must NOT be treated as email).
"""
from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent


def build_activity(mode: str, sender: str, subject: str, body: str, service_url: str) -> dict:
    conv_id = f"email-harness-{uuid.uuid4().hex[:8]}"
    msg_id = f"AAMk-harness-{uuid.uuid4().hex[:12]}"
    base = {
        "id": uuid.uuid4().hex,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "serviceUrl": service_url,
        "conversation": {"id": conv_id},
        "recipient": {
            "id": "agent-local", "name": "Agent",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "agenticAppId": "00000000-0000-0000-0000-000000000001",
            # No "role": agenticUser here: the SDK would then fetch an agentic token (needs a tenant).
            # Locally the recipient is a plain bot; the notification route only keys off channelId.
        },
        "locale": "en-US",
    }
    if mode == "plain":
        return {**base, "type": "message", "channelId": "msteams",
                "text": f"{subject}\n\n{body}", "from": {"id": sender, "name": sender}}
    sender_addr = sender if "@" in sender else f"{sender.lower().replace(' ', '.')}@contoso.example"
    # The A365 EmailReference has only id, conversationId, htmlBody: no subject field. The subject is
    # put at the top of htmlBody so the model sees it (the real service's exact content is unverified).
    email_html = f"<html><body><p><b>Subject: {html.escape(subject)}</b></p><p>{html.escape(body)}</p></body></html>"
    return {
        **base,
        "type": "message",
        "channelId": "agents:email",
        "from": {"id": sender_addr, "name": sender, "role": "user"},
        "text": body,
        "name": "emailNotification",
        "entities": [{
            "type": "emailNotification",
            "id": msg_id,
            "conversationId": conv_id,
            "htmlBody": email_html,
        }],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from", dest="sender", required=True)
    ap.add_argument("--subject", required=True)
    ap.add_argument("--body", default="")
    ap.add_argument("--agent", default="http://localhost:8095", help="agent base URL")
    ap.add_argument("--mode", choices=["notification", "plain"], default="notification")
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--timeout", type=int, default=240)
    ap.add_argument("--no-shot", action="store_true", help="skip the 600px screenshot")
    args = ap.parse_args()

    captured: list[dict] = []

    class Handler(BaseHTTPRequestHandler):
        def _ok(self):
            raw = self.rfile.read(int(self.headers.get("content-length", 0) or 0))
            try:
                captured.append({"path": self.path, "method": self.command, "activity": json.loads(raw or b"{}")})
            except Exception:
                captured.append({"path": self.path, "method": self.command, "raw": raw.decode(errors="replace")})
            out = json.dumps({"id": uuid.uuid4().hex}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
        do_POST = do_PUT = _ok
        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    service_url = f"http://127.0.0.1:{srv.server_address[1]}/"

    activity = build_activity(args.mode, args.sender, args.subject, args.body, service_url)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "request.json").write_text(json.dumps(activity, indent=2))

    req = urllib.request.Request(args.agent.rstrip("/") + "/api/messages", data=json.dumps(activity).encode(),
                                 headers={"content-type": "application/json"}, method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as r:
            status, resp_body = r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        status, resp_body = e.code, e.read().decode(errors="replace")
    elapsed = time.time() - t0
    time.sleep(0.5)
    srv.shutdown()
    (out / "captured_outbound.json").write_text(json.dumps(captured, indent=2))

    # Outbound message activities: those with an emailResponse entity are the email reply.
    replies = []
    for c in captured:
        act = c.get("activity") or {}
        if act.get("type") != "message":
            continue
        ents = [e for e in (act.get("entities") or []) if str(e.get("type", "")).lower() == "emailresponse"]
        for ent in ents:
            replies.append(("email", ent.get("htmlBody") or ent.get("html_body") or ""))
        if not ents and act.get("text"):
            replies.append(("text", act["text"]))

    email_replies = [h for k, h in replies if k == "email"]
    summary = {
        "mode": args.mode, "from": args.sender, "subject_sent": args.subject,
        "agent_http_status": status, "agent_http_body": resp_body[:300],
        "elapsed_s": round(elapsed, 1),
        "outbound_activities": len(captured),
        "outbound_kinds": [k for k, _ in replies],
        "treated_as_email": bool(email_replies),
    }
    if email_replies:
        reply_html = email_replies[-1]
        page = reply_html if "<html" in reply_html.lower() else (
            "<!doctype html><html><head><meta charset='utf-8'><meta name='viewport' content='width=device-width'>"
            "<style>body{font-family:Segoe UI,Arial,sans-serif;font-size:14px;margin:12px}</style></head><body>"
            + reply_html + "</body></html>")
        (out / "reply.html").write_text(page)
        # The A365 email entity carries no subject; Outlook would show "RE: <original subject>".
        summary["reply_subject"] = f"RE: {args.subject} (entity has no subject field; derived)"
        summary["reply_body_chars"] = len(reply_html)
        if not args.no_shot:
            shot = subprocess.run(["node", str(HERE / "shot.cjs"), str(out / "reply.html"), str(out / "reply_600.png")],
                                  capture_output=True, text=True)
            summary["screenshot"] = str(out / "reply_600.png") if shot.returncode == 0 else f"failed: {shot.stderr[-200:]}"
    elif replies:
        summary["non_email_text_reply"] = replies[-1][1][:300]
    (out / "summary.json").write_text(json.dumps(summary, indent=2))

    print(f"agent HTTP {status} in {elapsed:.1f}s; outbound activities: {len(captured)}; treated_as_email: {bool(email_replies)}")
    if email_replies:
        print(f"reply subject: {summary['reply_subject']}")
        print(f"reply body length: {summary['reply_body_chars']} chars -> {out/'reply.html'}")
    else:
        print("no emailResponse captured;", summary.get("non_email_text_reply", "(no reply text)"))
    return 0 if (email_replies or args.mode == "plain") else 1


if __name__ == "__main__":
    sys.exit(main())
