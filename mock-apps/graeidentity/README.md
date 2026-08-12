# GraeIdentity — mock access portal (PoC demo)

A tiny single-page React app that mocks **GraeIdentity**, the fictitious identity
portal referenced by the support-case-agent prompt
(`agents/support-case-agent/support-case-agent.Agent/Prompt.md`).

Use it to click through the access-triage runbook and take screenshots to feed
back into the chat agent.

## Run it

It's a self-contained `index.html` (React + Babel via CDN — needs internet).

```bash
cd mock-apps/graeidentity
python3 -m http.server 8080
```

Then open <http://localhost:8080>.

The agent tells users the URL **https://graeidentity.localtest.me**. `*.localtest.me`
already resolves to `127.0.0.1`, so to match that hostname in screenshots run the
server on port 80 and browse to `http://graeidentity.localtest.me`:

```bash
sudo python3 -m http.server 80    # then open http://graeidentity.localtest.me
```

(You can also just double-click `index.html` — the browser `file://` URL works too.)

## What it covers

Every checkpoint the runbook asks for a screenshot of:

- **Sign in** screen (any account email works; defaults to `alex.wong@contoso.com`).
- Header + **account menu** (upper-right) showing the signed-in account.
- **My Access → Application Access** list with per-app status.
- **GraemeCRM** application page with **Assigned Roles** and **Available Roles**.
- **Request access** form with **Business justification** + **Submit request**.
- **Request status**: Pending approval / Approved / Denied.
- **Open GraemeCRM** launcher: shows error `GRAE-403` until the role is active,
  then "Started successfully".

## Advancing the workflow (demo controls)

The user can't approve their own request. The **⚙ Demo controls** panel
(bottom-right) acts as the approver so you can capture the Approved/Active and
Denied screenshots. It is clearly labelled demo-only and is not part of the
"real" UI. **Reset demo** clears state.

State is stored in `localStorage`, so it survives page refreshes.
