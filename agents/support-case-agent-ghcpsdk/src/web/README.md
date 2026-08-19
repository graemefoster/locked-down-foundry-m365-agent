# Web client

This Vite app signs the user in with MSAL, acquires a bearer token, and calls the agent's **Invocations** endpoint directly.

## Local development

```bash
npm install
npm run dev
```

Required `.env.local` values:

```bash
VITE_MSAL_CLIENT_ID=1ca742d5-84bf-4e50-8b16-5dea5938b13c
VITE_MSAL_AUTHORITY=https://login.microsoftonline.com/7cd964e4-a3be-4627-a8df-2b8371609081
VITE_AGENT_BASE_URL=http://localhost:5263

# Optional: direct Foundry REST file upload endpoint base.
# If omitted, the app derives upload URL from VITE_AGENT_BASE_URL.
# Expected format:
# https://<foundry>.services.ai.azure.com/api/projects/<project>/agents/<agent>/endpoint/sessions
VITE_AGENT_FILES_BASE_URL=

# Optional override for upload endpoint api-version.
# Defaults to 2025-11-15-preview when not provided.
VITE_AGENT_FILES_API_VERSION=2025-11-15-preview
```

## Agent protocol

- The client POSTs to `/invocations`
- The latest chat session id is sent as `agent_session_id`
- Streaming responses are parsed from `text/event-stream`
- Assistant text is assembled from `assistant.message_delta`, `assistant.message`, and `done` payloads
- File uploads use `PUT /agents/{name}/endpoint/sessions/{id}/files/content?path=<remotePath>`
- Upload body is raw `application/octet-stream` bytes
- A session must exist before upload (send one chat message first)
