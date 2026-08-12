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

  No frameworks, no npm install. Node 18+ (uses global fetch + web streams).

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
};

const CONVERSATIONS_API_VERSION = "2025-11-15-preview";
const RESPONSES_API_VERSION = "v1";

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
