export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface StreamResult {
  text: string;
  sessionId: string | null;
}

export interface AgentActivity {
  kind: "tool" | "reasoning" | "intent";
  label: string;
}

export interface SessionFileUploadResult {
  remotePath: string;
  fileName: string;
}

interface ToolRequest {
  name: string;
  arguments?: Record<string, unknown>;
  intentionSummary?: string;
  toolCallId?: string;
  type?: string;
}

interface SessionEventEnvelope {
  type?: string;
  sessionId?: string;
  invocationId?: string;
  fullText?: string;
  message?: string;
  ephemeral?: boolean;
  data?: {
    content?: string;
    deltaContent?: string;
    messageId?: string;
    turnId?: string;
    toolRequests?: ToolRequest[];
    reasoningOpaque?: string;
    model?: string;
  };
}

export async function streamMessage(
  accessToken: string,
  messages: ChatMessage[],
  sessionId: string | null,
  onDelta: (delta: string) => void,
  onActivity?: (activity: AgentActivity) => void
): Promise<StreamResult> {
  const lastUser = messages.findLast((message) => message.role === "user");
  if (!lastUser) {
    throw new Error("No user message");
  }

  const requestUrl = new URL(import.meta.env.VITE_AGENT_BASE_URL);
  if (sessionId) {
    requestUrl.searchParams.set("agent_session_id", sessionId);
  }

  const response = await fetch(requestUrl, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "Foundry-Features": "HostedAgents=V1Preview",
    },
    body: JSON.stringify({ input: lastUser.content }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `Request failed with status ${response.status}`);
  }

  if (!response.body) {
    throw new Error("Streaming response body was unavailable");
  }

  const responseSessionId = response.headers.get("x-agent-session-id");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  let deltaText = "";
  let finalText = "";
  let activeSessionId = responseSessionId ?? sessionId;

  while (true) {
    const { done, value } = await reader.read();
    buffer += decoder.decode(value ?? new Uint8Array(), { stream: !done });

    let boundaryIndex = buffer.indexOf("\n\n");
    while (boundaryIndex >= 0) {
      const rawEvent = buffer.slice(0, boundaryIndex);
      buffer = buffer.slice(boundaryIndex + 2);

      const payload = parseSsePayload(rawEvent);
      if (payload) {
        activeSessionId = payload.sessionId ?? activeSessionId;

        if (payload.type === "done") {
          return {
            text: payload.fullText ?? (finalText || deltaText),
            sessionId: activeSessionId,
          };
        }

        if (payload.type === "error") {
          throw new Error(payload.message ?? "The agent returned an error");
        }

        // Invocations protocol: delta events have data.deltaContent (no type field)
        const delta = payload.data?.deltaContent ?? "";
        if (delta) {
          deltaText += delta;
          onDelta(delta);
        }

        // Tool requests signal the agent is "working"
        if (payload.data?.toolRequests?.length) {
          for (const tool of payload.data.toolRequests) {
            if (tool.name === "report_intent") {
              const intent = tool.arguments?.intent as string | undefined;
              if (intent) {
                onActivity?.({ kind: "intent", label: intent });
              }
            } else {
              const label = tool.intentionSummary ?? tool.name;
              onActivity?.({ kind: "tool", label });
            }
          }
        }

        // Reasoning indicator
        if (payload.data?.reasoningOpaque) {
          onActivity?.({ kind: "reasoning", label: "Thinking…" });
        }

        // Final turn message has data.content + data.turnId (no type field)
        if (payload.data?.content && payload.data?.turnId) {
          finalText = payload.data.content;
        }
      }

      boundaryIndex = buffer.indexOf("\n\n");
    }

    if (done) {
      break;
    }
  }

  return {
    text: finalText || deltaText,
    sessionId: activeSessionId,
  };
}

function parseSsePayload(rawEvent: string): SessionEventEnvelope | null {
  const dataLines = rawEvent
    .split("\n")
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trimStart());

  if (dataLines.length === 0) {
    return null;
  }

  try {
    return JSON.parse(dataLines.join("\n")) as SessionEventEnvelope;
  } catch {
    return null;
  }
}

export async function uploadSessionFile(
  accessToken: string,
  sessionId: string,
  remotePath: string,
  file: File
): Promise<SessionFileUploadResult> {
  if (!remotePath.trim()) {
    throw new Error("A destination path is required.");
  }

  const endpoint = buildSessionFileContentEndpoint(sessionId, remotePath.trim());

  const response = await fetch(endpoint, {
    method: "PUT",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Foundry-Features": "HostedAgents=V1Preview",
      "Content-Type": "application/octet-stream",
    },
    body: file,
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `File upload failed with status ${response.status}`);
  }

  return {
    remotePath: remotePath.trim(),
    fileName: file.name,
  };
}

function buildSessionFileContentEndpoint(sessionId: string, remotePath: string): string {
  const configuredEndpoint = import.meta.env.VITE_AGENT_FILES_BASE_URL as string | undefined;
  if (configuredEndpoint) {
    const directUrl = new URL(configuredEndpoint);
    directUrl.pathname = `${directUrl.pathname.replace(/\/$/, "")}/${encodeURIComponent(sessionId)}/files/content`;
    directUrl.searchParams.set("path", remotePath);
    ensureApiVersion(directUrl);
    return directUrl.toString();
  }

  const invocationsUrl = new URL(import.meta.env.VITE_AGENT_BASE_URL);
  invocationsUrl.pathname = invocationsUrl.pathname.replace(
    /\/endpoint\/protocols\/invocations\/?$/,
    `/endpoint/sessions/${encodeURIComponent(sessionId)}/files/content`
  );
  invocationsUrl.searchParams.set("path", remotePath);
  ensureApiVersion(invocationsUrl);
  return invocationsUrl.toString();
}

function ensureApiVersion(url: URL): void {
  const configuredApiVersion = import.meta.env.VITE_AGENT_FILES_API_VERSION as string | undefined;
  if (configuredApiVersion) {
    url.searchParams.set("api-version", configuredApiVersion);
    return;
  }

  if (!url.searchParams.has("api-version")) {
    url.searchParams.set("api-version", "2025-11-15-preview");
  }
}
