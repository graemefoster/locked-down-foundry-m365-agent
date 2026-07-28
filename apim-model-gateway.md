# APIM Model Gateway — design, decisions & operational notes

Knowledge dump for the **optional, enterprise-grade Model Gateway** added to this
locked-down Foundry M365 agent sample. Read this to resume work after a session reset.

> Secrets are intentionally **not** in this file. The APIM subscription key is a
> deterministic `guid(resourceGroup().id, apimName, 'model-gateway-apikey')` and is
> fetched live via `listSecrets` (see [Operational commands](#operational-commands)).
> The VM admin password (`vmAdminPassword`) is prompted for by `azd` at provision
> time and is never stored in the repo.

---

## 1. What it is / goal

Deploy an **Azure API Management (Standard v2)** instance
plus a **"real" model-provider AI Foundry** in a **new spoke VNet**, then advertise APIM
to the **primary** Foundry project as an `ApiManagement` connection so a seeded agent can
use a model referenced as `<connection-name>/<model-name>` (e.g. `model-gateway/gpt-5.4-mini`).

The whole gateway is always deployed. Goal: hit as many enterprise
features as possible (private APIM, VNet integration, keyless Entra auth to the gateway,
dynamic model discovery).

## 2. Topology (when enabled)

| VNet | CIDR | Purpose |
|------|------|---------|
| Hub | `10.0.0.0/16` | Firewall + DNS resolver |
| Foundry spoke | `10.2.0.0/16` | Primary agent + PE + VM |
| App Service spoke | `10.1.0.0/16` | YARP proxy |
| **Model-gateway spoke** | **`10.3.0.0/16`** | APIM VNet-integration subnet + PE subnet |

New-spoke subnets:
- `apim-subnet` `10.3.0.0/24` — delegated to `Microsoft.Web/serverFarms` (APIM v2 **outbound** VNet integration), UDR `0.0.0.0/0 → firewall`.
- `pe-subnet` `10.3.1.0/24` — APIM **inbound** private endpoint + provider Foundry PE; `privateEndpointNetworkPolicies: Enabled` + UDR back to firewall (avoids asymmetric routing).

**Flow:** primary agent → (UDR) → **firewall** → APIM inbound PE (new spoke) →
APIM (validate JWT + subscription key) → (VNet-integration egress) → provider Foundry PE
(intra-spoke) → model. No spoke-to-spoke peering — the firewall stays the single choke point.

## 3. Auth model (two layers, defense in depth)

Inbound to APIM (from Foundry, per operation):
1. **Entra JWT** — `validate-azure-ad-token`, audience `https://cognitiveservices.azure.com`
   (+ trailing-slash variant), pinned to the caller project MI via the `xms_mirid`
   required-claim. Foundry sends this because the connection is `ProjectManagedIdentity`.
2. **APIM subscription key** — `subscriptionRequired=true`, accepted on the `api-key`
   header/query (matches the AOAI convention). Enforced on **every** operation incl. discovery.

APIM → provider Foundry: `authentication-managed-identity` (APIM system MI, granted
`Cognitive Services OpenAI User` on the provider account). Keyless.

### xms_mirid casing (important)
Azure MSI tokens emit `xms_mirid` with the `resourcegroups` keyword **lowercase** while
preserving user-supplied name casing; ARM IDs use `resourceGroups`. The policy lists the
claim value in **3 casings** under `match="any"`: raw ARM ID, ARM ID with only
`/resourceGroups/`→`/resourcegroups/`, and fully `toLower`. (Can later be collapsed to the
one the live token actually emits.)

## 4. Inference routing — **Azure OpenAI v1, model-in-body** (current design)

We use the **v1 API surface** (`/openai/v1/chat/completions`), **not** the older
`/openai/deployments/{name}/chat/completions?api-version=...` path.

- Connection metadata `deploymentInPath: 'false'` → Foundry POSTs `{"model":"<deployment>",...}`
  in the body to `{target}/chat/completions`.
- APIM exposes a single `chat-completions` operation: `POST /chat/completions` (no path param).
- Inference backend base-url and API `serviceUrl` = `${backendBaseUrl}/v1`
  (`backendBaseUrl` = `https://<provider>.openai.azure.com/openai`), so inference forwards to
  `https://<provider>.openai.azure.com/openai/v1/chat/completions`.
- The chat op has **no operation-level policy** → it fully inherits the API-level `<base/>`
  (JWT + xms_mirid + set-backend to `/v1` + backend MI auth).
- `inferenceAPIVersion: 'preview'` (v1 tolerates `?api-version=preview`; APIM strips the
  `api-key` header before forwarding to the backend).

### Dynamic model discovery (unchanged by the v1 pivot)
Foundry discovers models by calling `GET /deployments` and `GET /deployments/{name}` on the
APIM API. Those two operations **bypass** `<base/>` (no caller JWT) and instead route to the
**ARM control plane** for the provider account (`{armAudience}{providerAccountResourceId}/deployments?api-version=2023-05-01`)
with APIM's MI, because ARM returns the AzureOpenAI-format deployment list Foundry expects.
`subscriptionRequired=true` still applies platform-side, so discovery needs the api-key too
(see the connection auth fix below). No static `models` array = dynamic discovery.
> Static models are only settable via the portal; dynamic is API/bicep-only.

## 5. The connection api-key fix (root cause of "gateway not working")

Foundry attaches the APIM subscription key to gateway calls via the **authConfig** mechanism,
which applies to **all** calls incl. discovery:
- `credentials: { key: <apiKey> }`
- `metadata.authHeaderName: 'api-key'`
- `metadata.authHeaderFormat: '{api_key}'`  (the `{api_key}` placeholder is substituted from `credentials.key`)

The **previous broken** shape used `metadata.customHeaders: { value: { 'api-key': key } }`,
which was (a) the wrong shape (customHeaders must be a serialized JSON string) and (b)
applied to **inference calls only**. So discovery calls carried no key → `401` under
`subscriptionRequired=true` → **zero models discovered** → "gateway not working".
Fixed by switching to the authConfig keys above (reverse-engineered from a portal-created
connection — the portal emits the flat `authHeaderName`/`authHeaderFormat` metadata keys).

## 6. Files

Model-gateway Bicep modules are localised under each owning stage's `model-gateway/` subfolder:
- `infra/stages/00-foundation/model-gateway/model-gateway-spoke-vnet.bicep` — new spoke VNet, subnets, UDR, NSGs, PE network policies.
- `infra/stages/10-platform/model-gateway/provider-foundry.bicep` — provider AIServices account + model deployment + MI, public access disabled.
- `infra/stages/10-platform/model-gateway/apim.bicep` — APIM Standard v2 + VNet integration + system MI. **Create Enabled, then flip
  `publicNetworkAccess=Disabled` in a second update after the PE** (v2 can't be created Disabled).
- `infra/stages/30-governance/model-gateway/apim-api-policy.bicep` — inference API, `chat-completions` op (v1), discovery ops, inbound
  JWT+xms_mirid policy, backend MI auth. **Uses `@@TOKEN@@` placeholders + `replace()`;
  replace LONGEST tokens first** (`@@PROJID@@` is a substring of `@@PROJID_RGLOWER@@`/`_LOWER@@`).
- `infra/stages/30-governance/model-gateway/apim-connection.bicep` — primary project → APIM `ApiManagement` connection (see §4/§5).
- `infra/stages/10-platform/model-gateway/model-gateway-private-endpoints.bicep` — APIM PE (`privatelink.azure-api.net`) + provider PE + DNS links.
- `infra/stages/10-platform/model-gateway/apim-provider-role-assignment.bicep` — APIM MI → `Cognitive Services OpenAI User` on provider.
- `infra/stages/30-governance/model-gateway/apim-mcp-compliance.bicep` — MCP per-agent rate-limit policy (see §13).

Modified core:
- `infra/main.bicep` — always-deployed model-gateway modules; firewall rule; hub↔spoke
  peering. Key vars: `providerBackendBaseUrl` (`.../openai`), `modelGatewayConnectionName`
  (`'model-gateway'`), `effectiveGatewayApiKey` (deterministic guid, never empty).
- `scripts/seed-agents.ps1` — on-VM agent seeding (run via the in-VNet runner workflow
  `gh workflow run deploy-vnet.yml`); 2nd agent uses `model-gateway/<model>`.
- `infra/main.parameters.json` — gateway params as azd env
  defaults (`${VAR=default}`); `vmAdminPassword` is omitted so azd prompts for it.

## 7. Live environment (current deployment)

| Thing | Value |
|---|---|
| Subscription | `b045f4eb-724b-4361-80ff-2a0ff999a996` |
| Resource group | `private-ai-foundry-firewall-a365-33` |
| Region | `australiaeast` |
| APIM | `apim-32cm-modelgw` (gateway `https://apim-32cm-modelgw.azure-api.net`, private IP `10.3.1.4`) |
| API path | `inference` (so target = `https://apim-32cm-modelgw.azure-api.net/inference`) |
| APIM subscription | `inference-subscription` (key = deterministic guid; fetch via listSecrets) |
| Provider Foundry | `gwprovider32cm` → backend `https://gwprovider32cm.openai.azure.com/openai` |
| Provider model | `gpt-5.4-mini` |
| Primary Foundry | `aiservices32cm`, project `project32cm`, endpoint `https://aiservices32cm.services.ai.azure.com/api/projects/project32cm` |
| Connection | `model-gateway` → agents use `model-gateway/gpt-5.4-mini` |
| VM | `test-vm-32cm` (system MI principalId `4278ef4f-88a3-4d40-ae1a-70f140cf671c`) |
| App Insights | `32cm-appi` (appId `a9af1477-3c76-4297-82cd-5713adcf3f1b`) |
| bicepparam | `modelName='gpt-5.4'`, `gatewayModelName='gpt-5.4-mini'` |

## 8. Current state (verified live)

Connection `model-gateway` and the APIM API were **patched to v1 this session** via two
targeted module deploys and verified live:

- Connection: `category=ApiManagement`, `authType=ProjectManagedIdentity`,
  `audience=https://cognitiveservices.azure.com`, `target=.../inference`,
  `deploymentInPath=false`, `inferenceAPIVersion=preview`, `authHeaderName=api-key`,
  `authHeaderFormat={api_key}`, `customHeaders=None`. ✅
- Operation `chat-completions`: `POST /chat/completions`, no template params. ✅
- Live inference backend routes to `.../openai/v1/chat/completions`; chat op inherits `<base/>`. ✅
- Agents seeded earlier: `hello-world-agent (gpt-5.4)`, `gateway-model-agent (model-gateway/gpt-5.4-mini)`, `teams-agent (model-gateway/gpt-5.4-mini)` (the one published to Teams).

Committed: `8f84ccb` "Route model gateway to Azure OpenAI v1 (model-in-body) + fix connection
api-key auth" (`apim-connection.bicep` + `apim-api-policy.bicep`). Prior policy-align commit `f2cab3a`.

## 9. Operational commands

```bash
SUB=b045f4eb-724b-4361-80ff-2a0ff999a996
RG=private-ai-foundry-firewall-a365-33

# Fetch the live APIM subscription key (= effectiveGatewayApiKey)
KEY=$(az rest --method post --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.ApiManagement/service/apim-32cm-modelgw/subscriptions/inference-subscription/listSecrets?api-version=2024-05-01" --query primaryKey -o tsv)

# Targeted deploy: v1 policy module (idempotent, no APIM re-provision)
PROVID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/gwprovider32cm"
PROJID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/aiservices32cm/projects/project32cm"
az deployment group create -g $RG --name gw-policy-v1-patch \
  --template-file infra/stages/30-governance/model-gateway/apim-api-policy.bicep \
  --parameters apimName=apim-32cm-modelgw backendBaseUrl="https://gwprovider32cm.openai.azure.com/openai" \
    providerAccountResourceId="$PROVID" callerProjectResourceId="$PROJID" apiSubscriptionKey="$KEY"

# Targeted deploy: connection module (creates/updates the 'model-gateway' connection)
az deployment group create -g $RG --name gw-connection-v1-patch \
  --template-file infra/stages/30-governance/model-gateway/apim-connection.bicep \
  --parameters aiFoundryName=aiservices32cm projectName=project32cm connectionName=model-gateway \
    apimGatewayUrl="https://apim-32cm-modelgw.azure-api.net" apiPath=inference \
    exposedModelName=gpt-5.4-mini apiKey="$KEY"

# Inspect the live connection shape
az rest --method get --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/aiservices32cm/projects/project32cm/connections/model-gateway?api-version=2025-04-01-preview" -o json

# List agents on the project (list response uses .data, NOT .value)
#   token audience MUST be https://ai.azure.com/  (IMDS resource=https%3A%2F%2Fai.azure.com%2F)
#   api-version 2025-11-15-preview ; base .../api/projects/project32cm/agents
```

**VM run-command gotcha:** the *legacy* `az vm run-command invoke` returns **stale cached
output** on `test-vm-32cm`. Use the **managed** run-command instead:
```bash
az vm run-command create -g $RG --vm-name test-vm-32cm --name <n> --script "@file.ps1" --async-execution false
az vm run-command show   -g $RG --vm-name test-vm-32cm --run-command-name <n> --instance-view --query instanceView.output
az vm run-command delete -g $RG --vm-name test-vm-32cm --run-command-name <n> --yes   # don't delete the one you're running from — it hangs
```

## 10. End-to-end test recipe (not yet run)

The definitive functional test is an **agent run**, executed server-side as the project MI,
which exercises the connection with the correct JWT + xms_mirid + api-key. Foundry v1 uses
the OpenAI-compatible **responses** API:

```
POST {projectEndpoint}/openai/v1/responses            # api-version: preview / v1
Authorization: Bearer <token, resource=https://ai.azure.com/>
Body: { "agent_reference": { "name": "gateway-model-agent", "type": "agent_reference" },
        "input": "Say hello in one word." }
```
Run this from `test-vm-32cm` via a managed run-command (the VM can reach the project
endpoint; the run itself executes as the project MI and hits the gateway). Success = a model
response with no auth error → confirms discovery + v1 inference through APIM end-to-end.

## 11. Open follow-ups

1. **Run the §10 end-to-end test** to confirm the v1 patch actually serves inference (not just structurally correct).
2. **`scripts/seed-agents.ps1` — remaining hardening** (idempotency `.data` bug now fixed):
   - No retry/backoff on the first `GET /agents`; a cold deploy hits a capability-host/RBAC
     propagation race (~1 min) returning transient `400` and failing the whole seed.
     **Fix: retry loop.** The seed now runs from the in-VNet runner workflow, so re-running
     `gh workflow run deploy-vnet.yml` is the redeploy path (no `forceUpdateTag` needed).
3. **Collapse the 3 `xms_mirid` casings** to the one the live token actually emits (after a real call confirms it).
4. **App Insights `requests` empty over 2h** — likely just because failed discovery meant no
   Foundry-origin traffic reached APIM; re-check once real traffic flows. Rule out a separate
   ingestion/private-link issue if still empty after a successful call.
5. **Confirm the provider AOAI account exposes `/openai/v1`** and whether v1 needs/forbids an
   `api-version` query param for chat completions (currently passing `preview`).

## 12. Gotchas learned (quick reference)

- APIM Standard v2 **cannot be created** with `publicNetworkAccess=Disabled`
  (`ActivateServiceWithPrivateEndpointAccessNotAllowed`) — create Enabled, add inbound PE,
  then flip Disabled in a second update ordered after the PE.
- `validate-azure-ad-token` does **exact-string** `aud` matching; Entra issues `aud` verbatim
  equal to the requested resource. Keep the connection `audience` and the policy `<audience>`
  identical (or list both slash/no-slash variants). We list both.
- A conditional (`if()`) module's output consumed by an always-deployed resource needs
  safe-access (`mod.?outputs.x ?? default`) or BCP318 hard-references the non-deployed module.
- Bicep does **not** interpolate `${...}` inside triple-quoted (`'''...'''`) strings — hence the
  `@@TOKEN@@` + `replace()` pattern in `apim-api-policy.bicep`.
- **MCP tool in an agent manifest = connection for auth + injected per-env URL.**
  `agents/test-agent-one/agent.yaml` keeps `project_connection_id: testweathermcpserver` (supplies
  `AgenticIdentityToken` auth via the per-env connection) but **omits `server_url`**; the deploy
  workflow injects the concrete per-env URL (from the `MCP_SERVER_URL` repo variable /
  `mcpServerUrl` input / Bicep output `MCP_GATEWAY_URL` = the APIM MCP gateway) so the manifest
  promotes across environments unchanged. **Gotcha:** create/publish *accepts* a `type: mcp` tool
  with no `server_url`, but an actual **run rejects it** — `Missing mutually exclusive parameters:
  'tools[0]'. Ensure you are providing exactly one of: 'server_url', 'connector_id', or
  'tunnel_id'`. So the URL must be present in the *deployed* definition (connection-only is not
  enough); we inject it rather than hardcode it. The old bug was a hardcoded URL that was both
  stale (wrong env) and pointed straight at the App Service instead of the APIM gateway.
- **APIM `type:mcp` passthrough forwards to the backend `url` verbatim — put the MCP path there.**
  The MCP web app (Express) serves the streamable-HTTP MCP endpoint at **`/mcp`**, not root. APIM's
  MCP proxy does **not** append `mcpProperties.endpoints.mcp.uriTemplate` to the backend when
  forwarding, so a bare-host backend `url` makes APIM hit the container root → the server returns
  **404 `Cannot POST /`** (seen client-side as `The remote MCP server ... returned HTTP 404 while
  enumerating tools`). Fix in `apim-mcp-api.bicep`: set the backend `url` to include the path
  (`https://<mcp-app>/mcp`, via `mcpBackendPath`) and keep `uriTemplate: '/'`. Verify from the
  in-VNet VM (APIM is private) with a token minted for the MCP app's audience:
  `az account get-access-token --resource <mcpAppClientId>` then
  `curl -H "Authorization: Bearer $TOK" -X POST https://<apim>.azure-api.net/mcp -d '<initialize>'`
  → expect 200 with the MCP `initialize` response. App Service HTTP logs
  (`AppServiceHTTPLogs | where CsUriStem == "/"`, `ScStatus 404`) confirm the forwarded path.

## 13. MCP servers + per-agent rate limiting (config-as-data)

Config-as-data governance for MCP traffic through the gateway, driven by **two** repo-tracked
JSON files compiled into APIM — no portal magic, fully IaC, reviewable in PRs:

- **`mcp/mcp.json`** — WHICH MCP servers the gateway fronts (one `type: mcp` API + backend each).
- **`mcp/mcp-policy.json`** — WHICH agents may call each server, at what RPM (deny-by-default).

`.gitignore` ignores `*.json`, so both are kept trackable via a `!mcp/*.json` negation (same
trick as `infra/main.parameters.json`). Verify with `git check-ignore`.

### Which servers: `mcp/mcp.json` (convention-driven)
```json
{ "servers": [ { "name": "mcp" } ] }
```
An entry is just a `name`. **Everything routing is derived from it** — the APIM API name +
path are `<name>`, and the backend path defaults to `/<name>`. Nothing is hardcoded: the
previously hardcoded `mcp` default now lives here as a server *name*, retrofitting the existing
sample (whose deployed backend is served at `/mcp`). A server may override the backend path with
an optional `backendPath` field.

Backend **FQDNs and the token audience are NOT in this file** — they are generated at provision
time and flowed in dynamically from `infra/main.bicep` (`mcpServerFqdns`, a `{ <name>: <fqdn> }`
map built from the App Service outputs; and `mcpAudience`). Adding a server therefore means: add
an entry here **and** add its FQDN to the `mcpServerFqdns` map in `main.bicep`. (Audience is
shared across servers for now — multiple app registrations would need a per-server audience flow.)

`apim-mcp-servers.bicep` loops `mcp.json` and instantiates `apim-mcp-api.bicep` per server.

### Which agents: `mcp/mcp-policy.json` (server-keyed)
```json
{
  "renewalPeriodSeconds": 60,
  "servers": [
    { "name": "mcp", "agents": [
      { "name": "gateway-model-agent", "appId": "<agent-app-id-guid>", "requestsPerMinute": 60 }
    ] }
  ]
}
```
**Keyed by server**, so each server has its own independent allowlist. The `appId` is the AppId
carried in the agent's AgenticIdentityToken — the `instance_identity.client_id` from the Foundry
agent definition; discover it with **`scripts/list-agent-appids.ps1`** (read-only; run on the
in-VNet VM for private projects).

### What the policy does (`apim-mcp-compliance.bicep`, one per server)
Attaches a `policy` (rawxml) to **that server's MCP API**. Inbound pipeline:
1. `validate-azure-ad-token` — validates the caller's **AgenticIdentityToken** against the
   MCP app-registration audience (`mcpAudience`, both slash/no-slash) + this tenant. This is
   an **auth-posture change**: today the MCP API is pure pass-through (App Service EasyAuth
   validates). The policy adds edge validation (defense-in-depth) and still forwards the
   token **unchanged** to the backend.
2. `set-variable callerAppId` — reads the AppId from the **already-validated** JWT. Step 1
   sets `output-token-variable-name="mcpJwt"`, so this reads claims off that `Jwt` object
   (`((Jwt)context.Variables["mcpJwt"]).Claims`) rather than re-parsing the raw `Authorization`
   header — preserving the chain of trust and avoiding any malformed-header edge case (the
   request is already 401'd before this runs). Claim: **`appid`** (v1.0 tokens) with fallback
   to **`azp`** (v2.0 tokens; Entra emits the agent identity's app id in one of these).
3. `choose` — one `<when>` per AppId listed **under this server** → `rate-limit-by-key`
   (`calls={requestsPerMinute}`, `renewal-period={renewalPeriodSeconds}`,
   `counter-key="mcp-rl:<server>:<appId>"`; **429** when exceeded, `x-mcp-ratelimit-remaining`
   header surfaces the remaining count).
   **DENY-BY-DEFAULT, PER-SERVER:** any AppId not listed under this server (or a server absent
   from `mcp-policy.json` entirely) hits `<otherwise>` → **403** `agent_not_permitted`. Being
   allowed on one server never implies access to another.

### Applied in two places (one wrapper, one source of truth)
`apim-mcp-compliance-all.bicep` loops `mcp.json` and applies the per-server policy to each. It
needs **no backend FQDNs** (only APIM control-plane inputs), so the SAME wrapper is used by both:
- **`azd up`** — wired in `infra/main.bicep` as `apimMcpComplianceAll` (after `apimMcpServers`,
  before `apimLockdown`), so governance is present from the first deploy.
  **Bootstrap note:** the committed `mcp/mcp-policy.json` ships a **placeholder** entry
  (`appId` all-zeros), so out of the box the policy is effectively **deny-all** for MCP callers.
  This is intentional and safe — the seeded agents do **not** call the MCP API, so nothing
  breaks on a fresh env. Before an agent can call a server, add its real AppId under that server
  in the JSON and re-apply (re-run `azd up` or the workflow below).
- **On demand** — `.github/workflows/deploy-compliancy.yml` (`workflow_dispatch`, self-hosted
  VNet runner, `vnet-deploy` environment, VM MI via `az login --identity`) re-deploys ONLY
  this wrapper after you edit the JSON. Applying an APIM policy is an **ARM control-plane**
  op, so it does not need to reach APIM's private data plane — just Azure RBAC.
  Needs repo variables `AZURE_RESOURCE_GROUP`, `MCP_COMPLIANCE_APIM_NAME`,
  `MCP_COMPLIANCE_AUDIENCE` (Bicep outputs; `azd env refresh` if missing). Which servers get a
  policy is driven by `mcp/mcp.json` — no per-API input.

### Gotchas / notes
- **Foundry cannot reach MCP backends directly** — the Azure Firewall is default-deny and the
  only agent-subnet egress rule is `agent → APIM inbound PE`. There is no `agent → App Service
  PE` rule, so all MCP traffic is forced through APIM. New servers keep this for free: the
  existing `AllowApimToMcpAppServicePE` rule already covers the whole App Service pe-subnet
  (`APIM → PE`), and no `agent → PE` rule is ever added.
- **`rate-limit-by-key` is supported on APIM v2 tiers** (token-bucket algorithm) but **NOT**
  on the Consumption tier. This gateway is Standard v2 → supported.
- Bicep does **not** interpolate `${...}` inside triple-quoted (`'''`) strings, so the policy
  XML is built from **single-quoted** strings (with `\n`) via `join(map(server.agents, …))`.
- APIM **policy expressions are C#**, so string literals are double-quoted. They live inside
  double-quoted XML attributes, so every C# string quote is emitted as the entity **`&quot;`**
  (a plain `"` would close the attribute early).
- **v2 counters are per-gateway** (single APIM instance here, so fine). Verify Foundry
  surfaces a 429 during an agent run gracefully.
