# Agent Chat — local chat UI for the Foundry agent

A very simple, local React chat app that talks to the hosted Foundry agent
(`support-case-agent`) through a tiny zero-dependency Node proxy. Supports
**pasting screenshots** straight into the conversation.

## Prerequisites

- Node 18+ (uses global `fetch` + web streams — no `npm install` needed).
- Azure CLI, and you must be signed in: `az login`. Your account needs data-plane
  access to the Foundry project (Foundry User).
- Network line-of-sight to the Foundry endpoint. It is private (VNet-locked), so
  run this from a host that can reach it (e.g. the in-VNet VM, or via your VPN/
  private DNS). The token itself is for `https://ai.azure.com`.

## Run

```bash
cd chat-app
node server.js            # http://localhost:5173
```

Then open <http://localhost:5173>.

The proxy mints the token on demand with:

```bash
az account get-access-token --resource https://ai.azure.com
```

and caches it until ~1 min before expiry. The browser never sees the token.

## Configuration

Defaults are baked in (the `support-case-agent` values). Override with env vars:

| Env var | Default |
|---|---|
| `FOUNDRY_BASE` | `https://aiservicesebym.services.ai.azure.com/api/projects/projectebym` |
| `AGENT_NAME` | `support-case-agent` |
| `AGENT_ID` | `b40ce693-2df5-4cd6-bc2b-7bc0d03d87d1` (the `agent_ids` GUID) |
| `CHAT_USERNAME` | `admin@M365CPI15529713.onmicrosoft.com` |
| `PORT` | `5173` |

You can also edit all four in the UI (**⚙ Settings**); those overrides are stored
in `localStorage` and sent with each request.

## How it works

Two calls, matching the agent's OpenAI-protocol surface:

1. **Create conversation** — `POST .../protocols/openai/conversations?api-version=2025-11-15-preview`
   with `{ topic, agent_ids, username }` → returns `conv_…`.
2. **Send message** — `POST .../protocols/openai/responses?api-version=v1`
   with `{ conversation, stream: true, input: [{ type:"message", role:"user", content:[…] }] }`.
   The SSE stream is proxied straight through and rendered token-by-token.

Text goes in as `{ type:"input_text", text }`; pasted/attached images go in as
`{ type:"input_image", image_url:"data:image/…;base64,…" }`.

## Roadmap note (voice)

The proxy is compatible with a future WebRTC voice path: the backend mints the
ephemeral realtime session token, and the browser opens the WebRTC peer
connection directly to the realtime endpoint (media never flows through the
proxy).
