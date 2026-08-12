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
| `APP_URL` | `http://localhost:8080` (the app the "Open app" button opens / you screenshot) |
| `PORT` | `5173` |

You can also edit all five in the UI (**⚙ Settings**); those overrides are stored
in `localStorage` and sent with each request.

## Screenshot capture (for the walkthrough)

A browser tab can't silently screenshot another tab, so this uses the Screen
Capture API:

1. **🗔 Open app** — opens `APP_URL` (e.g. the GraeIdentity mock) in a new tab.
2. **🖥 Share for capture** — the browser prompts you once; pick that app's tab
   or window. The share stays live (a green "sharing" badge shows).
3. **📸 Capture screenshot** — grabs the current frame and attaches it to your
   next message. Capture as many as you like without re-prompting; **Stop** ends
   the share.

Captured frames flow through the same `input_image` pipeline as pasted/attached
images.

## How it works

Two calls, matching the agent's OpenAI-protocol surface:

1. **Create conversation** — `POST .../protocols/openai/conversations?api-version=2025-11-15-preview`
   with `{ topic, agent_ids, username }` → returns `conv_…`.
2. **Send message** — `POST .../protocols/openai/responses?api-version=v1`
   with `{ conversation, stream: true, input: [{ type:"message", role:"user", content:[…] }] }`.
   The SSE stream is proxied straight through and rendered token-by-token.

Text goes in as `{ type:"input_text", text }`; pasted/attached images go in as
`{ type:"input_image", image_url:"data:image/…;base64,…" }`.

## Voice (hosted agent + Voice Live TTS) — receive-only

Click **🔊 Voice** to give the chat a spoken voice, then **⏹ End voice** to stop. It's
**receive-only**: your microphone is never opened. You keep typing/pasting **text +
screenshots** as normal — the **hosted agent** (Responses API) always answers as the brain,
its reply streams into the thread as text, and while voice is on that reply is **also spoken
aloud** as **neural audio** by a separate **Azure Voice Live** session acting as a pure
text-to-speech narrator.

Why the split? A Voice Live session *bound* to a Foundry hosted agent returned empty
responses / threw inside the agent's own model call in this environment. So we keep the two
concerns separate: the hosted agent reasons (proven, reliable), and a **raw realtime voice**
(`VOICE_MODEL`, e.g. `gpt-realtime`) just reads the agent's words. The Voice Live session is
told via `session.instructions` to speak the user item **verbatim**, so it narrates rather
than answering.

How it works:

- The hosted agent replies over `POST /api/message` (OpenAI Responses SSE) exactly as in
  text mode. When voice is live, the streamed reply is buffered and split into **sentences**;
  each sentence is enqueued to the Voice Live session as an `input_text` item + `response.create`.
- A **serialized pump** speaks one sentence at a time — the next chunk is sent only after the
  previous `response.done`, so audio plays in order without overlapping responses.
- The browser owns the `RTCPeerConnection`. There's **no mic track** — instead a **synthetic
  silent audio track** (WebAudio oscillator at zero gain) is added so RTP keeps flowing and
  Voice Live doesn't idle-stop the session. The voice plays via `<audio autoplay>`.
- The [Voice Live WebRTC][vl-webrtc] signalling endpoint needs the Entra token in the
  `Authorization` header, which browsers can't set on a WebSocket. So the browser hands its
  SDP offer to the proxy (`POST /api/voice/connect`), which opens the authenticated upstream
  socket, does the `rtc.call.sdp.create → rtc.call.sdp.created` exchange, returns the answer,
  and **holds the socket**. Audio is peer-to-peer; the control channel is bridged (below).
- **Control channel = WS bridge.** Azure Voice Live consumes client events on the upstream
  **WebSocket**, not the WebRTC data channel. The proxy bridges it: the browser **POSTs**
  client events (`/api/voice/send`) and receives server events over **SSE**
  (`GET /api/voice/events`). On going live the browser sends `session.update` (English voice
  `en-US-Ava:DragonHDLatestNeural`, `turn_detection: null` since there's no mic, plus the
  verbatim TTS instructions).

Config (Settings panel or env): `VOICE_PROJECT_ID`, `VOICE_MODEL` (the realtime TTS voice
model), `VOICE_API_VERSION`. The Entra token uses the same `https://ai.azure.com/.default`
scope as chat.

> **Prerequisites / caveats.** Voice Live is a **public preview** feature on **global-standard**
> deployments — a public/global endpoint, *not* inside a private VNet, so run this from a host
> with normal public egress. Requires the `Cognitive Services User` + `Foundry User` roles on
> the resource.

[vl-webrtc]: https://learn.microsoft.com/azure/ai-services/speech-service/voice-live-webrtc
[vl-image]: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/ai/data-plane/VoiceLive/items.tsp#L65
