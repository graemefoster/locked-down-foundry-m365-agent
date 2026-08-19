# Agent Chat — local chat UI for the Foundry agent

A very simple, local React chat app that talks to the hosted Foundry agent
(`support-case-agent`) through a tiny zero-dependency Node proxy. Supports
**pasting screenshots** straight into the conversation.

## Prerequisites

- Node 18+ (uses global `fetch` + web streams). Chat itself is dependency-free;
  **voice** needs a one-time `npm install` (Azure Speech SDK — see below).
- Azure CLI, and you must be signed in: `az login`. Your account needs data-plane
  access to the Foundry project (Foundry User).
- Network line-of-sight to the Foundry endpoint. It is private (VNet-locked), so
  run this from a host that can reach it (e.g. the in-VNet VM, or via your VPN/
  private DNS). The token itself is for `https://ai.azure.com`.

## Run

```bash
cd chat-app
npm install               # once — pulls the Speech SDK used by voice
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

## Voice (hosted agent + Azure AI Speech TTS) — receive-only

Click **🔊 Voice** to give the chat a spoken voice, then **⏹ End voice** to stop. It's
**receive-only**: your microphone is never opened. You keep typing/pasting **text +
screenshots** as normal — the **hosted agent** (Responses API) always answers as the brain,
its reply streams into the thread as text, and while voice is on that reply is **also spoken
aloud** as **neural audio** by **Azure AI Speech** text-to-speech.

Why Azure AI Speech (and not a realtime model)? A realtime/`gpt-realtime` voice is an **LLM**,
so even when told to "read this verbatim" it sometimes ignores the script and starts answering
or generating. Azure AI Speech is a **deterministic TTS engine** — text in, audio out, no model
in the loop — so it reads the agent's words exactly and **can never go off-script**.

> Run `npm install` in `chat-app/` once — voice uses the
> `microsoft-cognitiveservices-speech-sdk` + `@azure/identity` packages
> (see `package.json`). The rest of the proxy is still dependency-free.

How it works:

- The hosted agent replies over `POST /api/message` (OpenAI Responses SSE) exactly as in
  text mode. When voice is live, the streamed reply is buffered and split into **sentences**;
  each sentence is sent to `POST /api/tts`.
- The proxy synthesises the text with the Speech SDK (`en-AU-NatashaNeural` by default) and
  returns `audio/mpeg`. The browser plays the clips through a hidden `<audio>` element.
- A **serialized pump** plays one clip at a time — the next sentence is fetched only after the
  current clip's `ended` event fires, so audio plays in order without overlapping.
- **Auth is passwordless.** The SDK calls `SpeechConfig.fromEndpoint(endpoint, credential)`
  with a `DefaultAzureCredential`, which uses your `az login` (`AzureCliCredential`) locally and
  managed identity when hosted — no keys, no manual token header. The endpoint is the resource's
  **custom-domain** host `https://<name>.cognitiveservices.azure.com` (derived from the base URL,
  or override with `SPEECH_ENDPOINT`).

Config (Settings panel or env): `VOICE_NAME` (the Azure Speech neural voice, default
`en-AU-NatashaNeural`), optional `SPEECH_ENDPOINT`.

> **Prerequisites / caveats.** The custom-domain endpoint is **private-link friendly** (it's the
> same `cognitiveservices.azure.com` host used by the resource's private endpoint). Requires a
> role granting Speech data-plane access (e.g. `Cognitive Services Speech User`) on the AI
> Services resource for whichever identity `DefaultAzureCredential` resolves.
