# APIM Model Gateway — design, decisions & operational notes

Knowledge dump for the **optional, enterprise-grade Model Gateway** added to this
locked-down Foundry M365 agent sample. Read this to resume work after a session reset.

> Secrets are intentionally **not** in this file. The APIM subscription key is a
> deterministic `guid(resourceGroup().id, apimName, 'model-gateway-apikey')` and is
> fetched live via `listSecrets` (see [Operational commands](#operational-commands)).
> `main.bicepparam` holds a real VM password and **must never be committed**.

---

## 1. What it is / goal

When `enableModelGateway=true`, deploy an **Azure API Management (Standard v2)** instance
plus a **"real" model-provider AI Foundry** in a **new spoke VNet**, then advertise APIM
to the **primary** Foundry project as an `ApiManagement` connection so a seeded agent can
use a model referenced as `<connection-name>/<model-name>` (e.g. `model-gateway/gpt-5.4-mini`).

Everything is gated behind `enableModelGateway` (default **false**) so there is zero cost
impact unless explicitly enabled. Goal: hit as many enterprise features as possible
(private APIM, VNet integration, keyless Entra auth to the gateway, dynamic model discovery).

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

`modules-network-secured/model-gateway/`
- `model-gateway-spoke-vnet.bicep` — new spoke VNet, subnets, UDR, NSGs, PE network policies.
- `provider-foundry.bicep` — provider AIServices account + model deployment + MI, public access disabled.
- `apim.bicep` — APIM Standard v2 + VNet integration + system MI. **Create Enabled, then flip
  `publicNetworkAccess=Disabled` in a second update after the PE** (v2 can't be created Disabled).
- `apim-api-policy.bicep` — inference API, `chat-completions` op (v1), discovery ops, inbound
  JWT+xms_mirid policy, backend MI auth. **Uses `@@TOKEN@@` placeholders + `replace()`;
  replace LONGEST tokens first** (`@@PROJID@@` is a substring of `@@PROJID_RGLOWER@@`/`_LOWER@@`).
- `apim-connection.bicep` — primary project → APIM `ApiManagement` connection (see §4/§5).
- `model-gateway-private-endpoints.bicep` — APIM PE (`privatelink.azure-api.net`) + provider PE + DNS links.
- `apim-provider-role-assignment.bicep` — APIM MI → `Cognitive Services OpenAI User` on provider.

Modified core:
- `main.bicep` — `enableModelGateway` flag; conditional modules; firewall rule; hub↔spoke
  peering. Key vars: `providerBackendBaseUrl` (`.../openai`), `modelGatewayConnectionName`
  (`'model-gateway'`), `effectiveGatewayApiKey` (deterministic guid, never empty).
  Consuming conditional-module outputs from always-deployed resources uses safe-access
  (`mod.?outputs.x ?? default`) to avoid BCP318 hard-reference failures.
- `scripts/seed-agents.ps1` — on-VM agent seeding (run via `azd hooks run predeploy` →
  `hooks/predeploy.ps1` → `az vm run-command`); optional 2nd agent uses `model-gateway/<model>`.
- `main.bicepparam` — `enableModelGateway`, gateway params. **DO NOT COMMIT (real password).**

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
| bicepparam | `modelName='gpt-5.4'`, `gatewayModelName='gpt-5.4-mini'`, `enableModelGateway=true` |

## 8. Current state (verified live)

Connection `model-gateway` and the APIM API were **patched to v1 this session** via two
targeted module deploys and verified live:

- Connection: `category=ApiManagement`, `authType=ProjectManagedIdentity`,
  `audience=https://cognitiveservices.azure.com`, `target=.../inference`,
  `deploymentInPath=false`, `inferenceAPIVersion=preview`, `authHeaderName=api-key`,
  `authHeaderFormat={api_key}`, `customHeaders=None`. ✅
- Operation `chat-completions`: `POST /chat/completions`, no template params. ✅
- Live inference backend routes to `.../openai/v1/chat/completions`; chat op inherits `<base/>`. ✅
- Agents seeded earlier: `hello-world-agent (gpt-5.4)`, `gateway-model-agent (model-gateway/gpt-5.4-mini)`.

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
  --template-file modules-network-secured/model-gateway/apim-api-policy.bicep \
  --parameters apimName=apim-32cm-modelgw backendBaseUrl="https://gwprovider32cm.openai.azure.com/openai" \
    providerAccountResourceId="$PROVID" callerProjectResourceId="$PROJID" apiSubscriptionKey="$KEY"

# Targeted deploy: connection module (creates/updates the 'model-gateway' connection)
az deployment group create -g $RG --name gw-connection-v1-patch \
  --template-file modules-network-secured/model-gateway/apim-connection.bicep \
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
     **Fix: retry loop.** The seed now runs from the azd `predeploy` hook, so re-running
     `azd hooks run predeploy` is the redeploy path (no `forceUpdateTag` needed).
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
