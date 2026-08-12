/*
  chat-app/server.js  — tiny zero-dependency local proxy for the Foundry agent chat UI.
  --------------------------------------------------------------------------------------
  Runs on your machine (you must be `az login`-ed). It:
    * serves index.html (the React chat UI)
    * mints + caches a data-plane token for https://ai.azure.com via
      `az account get-access-token` (the browser never sees the token)
    * forwards two calls to the Foundry agent OpenAI-protocol endpoints:
        POST /api/conversation  -> .../protocols/openai/conversations   (create a conversation)
        POST /api/message       -> .../protocols/openai/responses        (send a message, SSE)
      * bridges the Voice Live WebRTC signalling handshake (Entra token in the
        Authorization header, which browsers can't set on a WebSocket):
          POST /api/voice/connect -> opens wss://<res>/voice-live/realtime/calls,
                                      sends the browser's SDP offer, returns the SDP answer
          POST /api/voice/hangup  -> closes the held upstream signalling socket
        (audio + the `voice-live-events` data channel stay peer-to-peer; only the
         SDP handshake goes through here.)

    No frameworks, no npm install. Node 22+ (uses global fetch, web streams + WebSocket).

  Config defaults (override with env vars):
    FOUNDRY_BASE   e.g. https://<acct>.services.ai.azure.com/api/projects/<project>
    AGENT_NAME     e.g. support-case-agent
    AGENT_ID       the agent identity GUID (agent_ids in the create payload)
    CHAT_USERNAME  the M365 username sent on conversation create
    PORT           default 5173
  The browser can also override baseUrl/agentName/agentId/username per request (settings panel).
*/
"use strict";
const http = require("http");
const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

const PORT = Number(process.env.PORT) || 5173;
const RESOURCE = "https://ai.azure.com";

const DEFAULTS = {
  baseUrl:
    process.env.FOUNDRY_BASE ||
    "https://aiservicesebym.services.ai.azure.com/api/projects/projectebym",
  agentName: process.env.AGENT_NAME || "support-case-agent",
  agentId: process.env.AGENT_ID || "b40ce693-2df5-4cd6-bc2b-7bc0d03d87d1",
  username: process.env.CHAT_USERNAME || "admin@M365CPI15529713.onmicrosoft.com",
  appUrl: process.env.APP_URL || "http://localhost:8080",
  // --- Voice Live (WebRTC) ---
  // projectId defaults to the last path segment of baseUrl (…/projects/<projectId>).
  projectId:
    process.env.VOICE_PROJECT_ID ||
    ((process.env.FOUNDRY_BASE || "https://aiservicesebym.services.ai.azure.com/api/projects/projectebym")
      .match(/\/projects\/([^/?#]+)/) || [, "projectebym"])[1],
  voiceUseAgent: (process.env.VOICE_USE_AGENT || "true").toLowerCase() !== "false",
  voiceModel: process.env.VOICE_MODEL || "gpt-realtime",
};

const CONVERSATIONS_API_VERSION = "2025-11-15-preview";
const RESPONSES_API_VERSION = "v1";
const VOICE_API_VERSION = process.env.VOICE_API_VERSION || "2026-01-01-preview";

// --- token cache ---------------------------------------------------------
let tokenCache = { value: null, exp: 0 };
function getToken() {
  return new Promise((resolve, reject) => {
    if (tokenCache.value && Date.now() < tokenCache.exp - 60_000) {
      return resolve(tokenCache.value);
    }
    execFile(
      "az",
      ["account", "get-access-token", "--resource", RESOURCE, "-o", "json"],
      { maxBuffer: 4 * 1024 * 1024 },
      (err, stdout, stderr) => {
        if (err) {
          return reject(
            new Error(
              "`az account get-access-token` failed. Are you `az login`-ed? " +
                (stderr || err.message)
            )
          );
        }
        try {
          const j = JSON.parse(stdout);
          let exp = 0;
          if (j.expires_on) exp = Number(j.expires_on) * 1000;
          else if (j.expiresOn) exp = Date.parse(j.expiresOn);
          if (!exp || Number.isNaN(exp)) exp = Date.now() + 5 * 60_000;
          tokenCache = { value: j.accessToken, exp };
          resolve(j.accessToken);
        } catch (e) {
          reject(e);
        }
      }
    );
  });
}

// --- helpers -------------------------------------------------------------
function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => {
      body += c;
      if (body.length > 40 * 1024 * 1024) {
        reject(new Error("request too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function sendJson(res, status, obj) {
  const s = JSON.stringify(obj);
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(s);
}

function cfgFrom(body) {
  return {
    baseUrl: (body.baseUrl || DEFAULTS.baseUrl).replace(/\/+$/, ""),
    agentName: body.agentName || DEFAULTS.agentName,
    agentId: body.agentId || DEFAULTS.agentId,
    username: body.username || DEFAULTS.username,
  };
}

// --- Voice Live (WebRTC) signalling bridge -------------------------------
// The browser does the RTCPeerConnection (mic + remote audio + data channel).
// It can't set the Authorization header on a WebSocket, so it hands us its SDP
// offer over HTTP; we open the authenticated upstream signalling socket, do the
// SDP exchange, return the answer, and hold the socket open for the call.
const voiceCalls = new Map(); // callId -> { ws, queue: [], sink: res|null }

function voiceUrlFrom(body) {
  const base = (body.baseUrl || DEFAULTS.baseUrl).replace(/\/+$/, "");
  const host = new URL(base).host; // <resource>.services.ai.azure.com
  const useAgent = body.useAgent != null ? !!body.useAgent : DEFAULTS.voiceUseAgent;
  const params = new URLSearchParams({ "api-version": VOICE_API_VERSION });
  if (useAgent) {
    // Azure AI Foundry agent binding — the exact query shape the azure-ai-voicelive
    // SDK dials (aio/_patch.py): agent-name + agent-project-name (+ optional
    // agent-version). Crucially, in agent mode there is NO `model` param and NO
    // `trafficType` — passing `model=<agentName>` makes Voice Live treat the agent
    // name as a model deployment and return an empty response (output=0). The bound
    // agent must also declare `metadata.voiceLiveCompatible: "true"` in its manifest.
    params.set("agent-name", body.agentName || DEFAULTS.agentName);
    params.set("agent-project-name", body.projectId || DEFAULTS.projectId);
    if (body.agentVersion) params.set("agent-version", body.agentVersion);
  } else {
    params.set("model", body.model || DEFAULTS.voiceModel);
  }
  return { url: `wss://${host}/voice-live/realtime/calls?${params}`, useAgent };
}

function voiceConnect(body) {
  return new Promise(async (resolve, reject) => {
    let token;
    try {
      token = await getToken();
    } catch (e) {
      return reject(e);
    }
    const { url, useAgent } = voiceUrlFrom(body);
    const session = body.session || {};
    // `instructions` isn't allowed when bound to a custom agent.
    if (useAgent) delete session.instructions;

    let ws;
    try {
      ws = new WebSocket(url, { headers: { Authorization: "Bearer " + token } });
    } catch (e) {
      return reject(e);
    }
    const callId = `call_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { ws.close(); } catch {}
      reject(new Error("timed out waiting for rtc.call.sdp.created"));
    }, 20_000);

    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({ type: "rtc.call.sdp.create", sdp_offer: body.sdp, session }));
    });
    ws.addEventListener("message", (ev) => {
      const rawStr = typeof ev.data === "string" ? ev.data : ev.data.toString();
      let msg;
      try { msg = JSON.parse(rawStr); }
      catch { return; }
      if (msg.type === "rtc.call.sdp.created") {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        voiceCalls.set(callId, { ws, queue: [], sink: null });
        resolve({ callId, sdp_answer: msg.sdp_answer, useAgent });
        return;
      }
      if (!settled && (msg.type === "rtc.call.error" || msg.type === "error")) {
        settled = true;
        clearTimeout(timer);
        try { ws.close(); } catch {}
        reject(new Error(msg.error?.message || "voice signalling error"));
        return;
      }
      // Post-handshake control events (session.updated, response.*, transcripts,
      // errors, tool calls) flow over THIS WebSocket. Relay them to the browser's
      // SSE stream, buffering until the stream connects.
      const entry = voiceCalls.get(callId);
      if (!entry) return;
      if (entry.sink) {
        try { entry.sink.write(`data: ${rawStr}\n\n`); } catch {}
      } else {
        entry.queue.push(rawStr);
        if (entry.queue.length > 500) entry.queue.shift();
      }
    });
    ws.addEventListener("error", (ev) => {
      const emsg = (ev && (ev.message || (ev.error && ev.error.message))) || "unknown";
      console.error(`[voice] upstream WS error: ${emsg}`);
      if (settled) {
        // Relay to the browser so we can see it in the event log.
        for (const [, entry] of voiceCalls) {
          if (entry.ws === ws && entry.sink) {
            try { entry.sink.write(`data: ${JSON.stringify({ type: "bridge.ws.error", message: emsg })}\n\n`); } catch {}
          }
        }
        return;
      }
      settled = true;
      clearTimeout(timer);
      reject(new Error("upstream voice socket error: " + emsg));
    });
    ws.addEventListener("close", (ev) => {
      const code = ev && ev.code;
      const reason = ev && ev.reason;
      console.error(`[voice] upstream WS closed  code=${code} reason=${reason || "(none)"}`);
      for (const [id, entry] of voiceCalls) {
        if (entry.ws === ws) {
          if (entry.sink) {
            try { entry.sink.write(`data: ${JSON.stringify({ type: "bridge.ws.closed", code, reason })}\n\n`); } catch {}
            try { entry.sink.end(); } catch {}
          }
          voiceCalls.delete(id);
        }
      }
    });
  });
}

// --- request routing -----------------------------------------------------
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://localhost:${PORT}`);

    if (req.method === "GET" && (url.pathname === "/" || url.pathname === "/index.html")) {
      const html = fs.readFileSync(path.join(__dirname, "index.html"));
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      return res.end(html);
    }

    if (req.method === "GET" && url.pathname === "/api/config") {
      return sendJson(res, 200, DEFAULTS);
    }

    if (req.method === "POST" && url.pathname === "/api/conversation") {
      const body = await readJson(req);
      const cfg = cfgFrom(body);
      const token = await getToken();
      const target = `${cfg.baseUrl}/agents/${encodeURIComponent(
        cfg.agentName
      )}/endpoint/protocols/openai/conversations?api-version=${CONVERSATIONS_API_VERSION}`;
      const payload = {
        topic: body.topic || "New chat",
        agent_ids: cfg.agentId,
        username: cfg.username,
      };
      const upstream = await fetch(target, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const text = await upstream.text();
      res.writeHead(upstream.status, { "Content-Type": "application/json" });
      return res.end(text);
    }

    if (req.method === "POST" && url.pathname === "/api/message") {
      const body = await readJson(req);
      const cfg = cfgFrom(body);
      if (!body.conversation) return sendJson(res, 400, { error: "missing 'conversation'" });
      if (!Array.isArray(body.input)) return sendJson(res, 400, { error: "missing 'input'" });
      const token = await getToken();
      const target = `${cfg.baseUrl}/agents/${encodeURIComponent(
        cfg.agentName
      )}/endpoint/protocols/openai/responses?api-version=${RESPONSES_API_VERSION}`;
      const payload = { conversation: body.conversation, stream: true, input: body.input };

      const upstream = await fetch(target, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          Accept: "text/event-stream",
        },
        body: JSON.stringify(payload),
      });

      if (!upstream.ok || !upstream.body) {
        const errText = await upstream.text();
        res.writeHead(upstream.status || 502, { "Content-Type": "application/json" });
        return res.end(errText || JSON.stringify({ error: "upstream error" }));
      }

      res.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      const reader = upstream.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(Buffer.from(value));
      }
      return res.end();
    }

    if (req.method === "POST" && url.pathname === "/api/voice/connect") {
      const body = await readJson(req);
      if (!body.sdp) return sendJson(res, 400, { error: "missing 'sdp' offer" });
      const result = await voiceConnect(body);
      return sendJson(res, 200, result);
    }

    if (req.method === "GET" && url.pathname === "/api/voice/events") {
      const callId = url.searchParams.get("callId");
      const entry = callId && voiceCalls.get(callId);
      if (!entry) return sendJson(res, 404, { error: "unknown callId" });
      res.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
      });
      res.write(": voice-events open\n\n");
      entry.sink = res;
      // Flush anything the upstream WS already sent before the stream connected.
      for (const line of entry.queue.splice(0)) res.write(`data: ${line}\n\n`);
      req.on("close", () => { if (entry.sink === res) entry.sink = null; });
      return;
    }

    if (req.method === "POST" && url.pathname === "/api/voice/send") {
      const body = await readJson(req);
      const entry = body.callId && voiceCalls.get(body.callId);
      if (!entry) return sendJson(res, 404, { error: "unknown callId" });
      if (!body.event) return sendJson(res, 400, { error: "missing 'event'" });
      try { entry.ws.send(JSON.stringify(body.event)); }
      catch (e) { return sendJson(res, 502, { error: String(e && e.message ? e.message : e) }); }
      return sendJson(res, 200, { ok: true });
    }

    if (req.method === "POST" && url.pathname === "/api/voice/hangup") {
      const body = await readJson(req);
      const entry = body.callId && voiceCalls.get(body.callId);
      if (entry) {
        try { entry.ws.close(); } catch {}
        voiceCalls.delete(body.callId);
      }
      return sendJson(res, 200, { ok: true });
    }

    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not found");
  } catch (e) {
    if (!res.headersSent) sendJson(res, 500, { error: String(e && e.message ? e.message : e) });
    else res.end();
  }
});

server.listen(PORT, () => {
  console.log(`\n  Agent chat proxy running:  http://localhost:${PORT}`);
  console.log(`  Endpoint: ${DEFAULTS.baseUrl}`);
  console.log(`  Agent   : ${DEFAULTS.agentName}`);
  console.log(`  Token   : az account get-access-token --resource ${RESOURCE}\n`);
});
