# AI gateway (APIM) — models, MCP & M365 auth

> **Level 2 — Automate agent deployment.** Part of the
> [locked-down Foundry agent](../README.md) reference implementation.
> Networking: [NETWORKING.md § gateway spoke](./NETWORKING.md#optional-model-gateway-spoke-apim--provider-foundry).
> Governance overview: [governance.md](./governance.md).

This sample deploys **one shared, private Azure API Management (Standard v2) instance** that
acts as an **AI gateway** — a single control point in front of everything the agents talk to.
It plays **three roles** on the same instance:

1. **Model gateway** — routes agents to models via a "provider" AI Foundry account, with
   keyless Entra auth and dynamic model discovery (§1–8 below).
2. **MCP gateway** — fronts your **MCP servers** as APIM APIs and enforces **per-agent rate
   limiting + deny-by-default allowlists** (§9; see also [governance.md](./governance.md)).
3. **M365 / Teams auth** — validates the inbound Bot Framework JWT and enforces single-tenant
   lockdown for the [Teams / M365 publish path](./teams-m365.md) before rewriting to the
   agent's private endpoint.

Putting all three behind one APIM means there is a **single enforcement point** for auth, rate
limiting, quotas, and usage attribution across models, tools, and inbound M365 traffic.

> **Naming note.** The Bicep still calls this the *model gateway* (modules under
> `infra/stages/*/model-gateway/`, the `model-gateway` connection, the `10.3.0.0/16`
> "model-gateway spoke"). Those identifiers are unchanged to avoid churning a live deployment;
> "AI gateway" is the broader concept the same infrastructure has grown into. Where you see
> `model-gateway` in code/paths below, read it as "the AI gateway".

> **APIM and the whole gateway are always deployed.** The APIM Standard v2 instance, its
> gateway spoke (`10.3.0.0/16`), inbound private endpoint, `privatelink.azure-api.net` DNS zone,
> the **provider Foundry** account, the APIM inference API/connection, the MCP APIs, and the
> second seeded agent are all provisioned unconditionally — the model path, the MCP path, *and*
> the [Teams / M365 publish path](./teams-m365.md) all route through this shared infrastructure.

---

## 1. The model gateway — what it is and why

Deploy the shared APIM instance plus a "real" model-provider AI Foundry account in a **new spoke
VNet**, then advertise APIM to the **primary** Foundry project as an `ApiManagement` connection.
A seeded agent then references a model as `<connection-name>/<model-name>` (e.g.
`model-gateway/gpt-5.4-mini`).

The goal is to demonstrate as many enterprise features as possible: a **private** APIM (no
public gateway access), outbound **VNet integration**, **keyless Entra auth** to the gateway,
and **dynamic model discovery**. APIM is the natural enforcement point for rate limiting,
quotas, and usage attribution across every agent.

> **Note:** APIM Standard v2 provisioning is slow (~15–45 min), so this materially increases
> deployment time.

## 2. Topology

The gateway lives in its own spoke (`10.3.0.0/16`); there is **no spoke-to-spoke peering** —
the firewall stays the single choke point.

| VNet | CIDR | Purpose |
|------|------|---------|
| Hub | `10.0.0.0/16` | Firewall + DNS resolver |
| Foundry spoke | `10.2.0.0/16` | Primary agent + PE + VM |
| App Service spoke | `10.1.0.0/16` | YARP proxy |
| **Model-gateway spoke** | **`10.3.0.0/16`** | APIM VNet-integration subnet + PE subnet |

New-spoke subnets:

- `apim-subnet` `10.3.0.0/24` — delegated to `Microsoft.Web/serverFarms` (APIM v2 **outbound**
  VNet integration), UDR `0.0.0.0/0 → firewall`.
- `pe-subnet` `10.3.1.0/24` — APIM **inbound** private endpoint + provider Foundry PE;
  `privateEndpointNetworkPolicies: Enabled` + UDR back to the firewall (avoids asymmetric
  routing).

**Request flow:**

```
primary agent (10.2.0.0/24)
  → UDR 0.0.0.0/0 → Azure Firewall                (agent → APIM PE allow)
  → APIM inbound PE (10.3.1.x)
  → APIM: validate-azure-ad-token (Entra JWT) + api-key subscription
  → APIM outbound VNet integration → provider Foundry PE (intra-spoke)
  → model
```

## 3. Auth model — two layers, defense in depth

Every inbound call to APIM (including discovery) is checked twice:

1. **Entra JWT** (`validate-azure-ad-token`) — the primary project managed identity's token,
   validated on tenant + audience `https://cognitiveservices.azure.com` (both the
   trailing-slash and no-slash variants are accepted), and optionally pinned to the caller
   project MI via the `xms_mirid` required claim or a caller app/client ID
   (`gatewayCallerAppId`). Foundry sends this because the connection is
   `ProjectManagedIdentity`.
2. **APIM subscription key** — the `api-key` header (AOAI convention),
   `subscriptionRequired=true`, enforced on **every** operation including discovery. The key
   is derived deterministically by default or overridden with the secure `gatewayApiKey` param.

The network boundary + the JWT remain the primary controls; the subscription key is
defense-in-depth. **APIM → provider Foundry** uses APIM's own system-assigned managed identity
(`authentication-managed-identity`), granted **Cognitive Services (OpenAI) User** (data-plane
inference) and **Reader** (ARM deployments read for discovery) on the provider account —
keyless. The provider account has `publicNetworkAccess: Disabled` and local auth disabled, so
it is reachable only over its private endpoint.

> **`xms_mirid` casing gotcha.** Azure MSI tokens emit `xms_mirid` with the `resourcegroups`
> keyword **lowercase** while preserving user-supplied name casing; ARM IDs use `resourceGroups`.
> The policy lists the claim value in **three casings** under `match="any"` (raw ARM ID; ARM ID
> with only `/resourceGroups/`→`/resourcegroups/`; and fully `toLower`) so validation matches
> whichever the live token emits.

## 4. Inference routing — Azure OpenAI v1 (model-in-body)

The gateway uses the **v1 API surface** (`/openai/v1/chat/completions`), not the older
`/openai/deployments/{name}/chat/completions?api-version=...` path:

- Connection metadata `deploymentInPath: 'false'` → Foundry POSTs `{"model":"<deployment>",...}`
  in the body to `{target}/chat/completions`.
- APIM exposes a single `chat-completions` operation: `POST /chat/completions` (no path param),
  which inherits the API-level `<base/>` policy (JWT + `xms_mirid` + set-backend + backend MI
  auth). The inference backend base-url = `https://<provider>.openai.azure.com/openai/v1`.

## 5. Dynamic model discovery

Instead of a static model list, APIM exposes `GET /deployments` and `GET /deployments/{name}`,
which **override the backend to the provider account's Azure Resource Manager deployments API**
(`management.azure.com/.../accounts/{provider}/deployments?api-version=2023-05-01`) using APIM's
managed identity. ARM returns the AzureOpenAI-format list that the Foundry connection's dynamic
discovery parses at runtime. `subscriptionRequired=true` still applies, so discovery needs the
`api-key` too. No static `models` array = dynamic discovery.

> **The connection `api-key` mechanism (root cause of a classic "gateway not working").**
> Foundry attaches the subscription key to *all* gateway calls (incl. discovery) via the
> **authConfig** mechanism: `credentials.key`, `metadata.authHeaderName: 'api-key'`, and
> `metadata.authHeaderFormat: '{api_key}'`. An earlier broken shape used
> `metadata.customHeaders`, which applied to inference calls **only** — so discovery calls
> carried no key, returned `401` under `subscriptionRequired=true`, and **zero models were
> discovered**. Use the flat `authHeaderName`/`authHeaderFormat` keys (what a portal-created
> connection emits).

## 6. Two-phase APIM lockdown

APIM Standard v2 **cannot be created** with `publicNetworkAccess: Disabled` (the control plane
returns `ActivateServiceWithPrivateEndpointAccessNotAllowed`). So the deployment:

1. Creates APIM with public access **Enabled**,
2. Provisions the inbound private endpoint,
3. Re-applies the service via `apim-lockdown.bicep` (ordered **after** the PE) to flip
   `publicNetworkAccess` to **Disabled**.

This is a property update, not a recreate; disabling public access affects only the gateway
data plane, so ARM still manages the service afterward.

**Observability.** APIM sends resource logs/metrics to the shared Log Analytics workspace and
gateway request/response telemetry to the shared **Application Insights** component (W3C
correlation, 100% sampling).

## 7. Key parameters

See [`infra/main.parameters.json`](../infra/main.parameters.json):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `gatewayModelName` | `gpt-5.4-mini` | Model deployed on the provider and exposed via APIM. |
| `gatewayCallerAppId` | `''` | Optional caller app/client ID pinned in the JWT policy. |
| `gatewayApiKey` | `''` (secure) | Optional explicit `api-key`; empty = deterministic derived key. |

The APIM subscription key is a deterministic `guid(resourceGroup().id, apimName,
'model-gateway-apikey')` and can be fetched live via `listSecrets` on the APIM subscription —
it is intentionally not stored in the repo.

## 8. Bicep modules

Model-gateway modules are localised under each owning stage's `model-gateway/` subfolder:

| Module | Stage | Purpose |
|--------|:-----:|---------|
| `model-gateway-spoke-vnet.bicep` | `00-foundation` | New spoke VNet, subnets, UDR, NSGs, PE network policies. |
| `provider-foundry.bicep` | `10-platform` | Provider AIServices account + model deployment + MI, public access disabled. |
| `apim.bicep` | `10-platform` | APIM Standard v2 + VNet integration + system MI (create Enabled, flip Disabled after the PE). |
| `model-gateway-private-endpoints.bicep` | `10-platform` | APIM PE (`privatelink.azure-api.net`) + provider PE + DNS links. |
| `apim-provider-role-assignment.bicep` | `10-platform` | APIM MI → Cognitive Services (OpenAI) User on the provider. |
| `apim-api-policy.bicep` | `30-governance` | Inference API, `chat-completions` (v1) + discovery ops, inbound JWT + `xms_mirid` policy, backend MI auth. |
| `apim-connection.bicep` | `30-governance` | Primary project → APIM `ApiManagement` connection (§3–5). |
| `apim-mcp-compliance-all.bicep` | `30-governance` | Applies the MCP per-agent rate-limit policy to each MCP server (§9). |
| `apim-lockdown.bicep` | `30-governance` | Flips APIM `publicNetworkAccess` to Disabled — runs **last**. |

---

## 9. MCP servers + per-agent rate limiting (config-as-data)

> This is one of the two pillars of the [governance story](./governance.md) — the *agent/tool*
> layer. The other is the model-layer [RAI guardrail](./rai-guardrail-policy.md).

The same APIM instance governs **MCP** (Model Context Protocol) traffic. This is
config-as-data governance driven by **two** repo-tracked JSON files compiled into APIM — no
portal magic, fully IaC, reviewable in PRs:

- **`mcp/mcp.json`** — WHICH MCP servers the gateway fronts (one `type: mcp` API + backend each).
- **`mcp/mcp-policy.json`** — WHICH agents may call each server, at what RPM (deny-by-default).

> `.gitignore` ignores `*.json`, so both are kept trackable via a `!mcp/*.json` negation (the
> same trick as `infra/main.parameters.json`). Verify with `git check-ignore`.

### Which servers — `mcp/mcp.json` (convention-driven)

```json
{ "servers": [ { "name": "mcp" } ] }
```

An entry is just a `name`; everything routing is derived from it (the APIM API name + path are
`<name>`, the backend path defaults to `/<name>`, overridable with `backendPath`). Backend
FQDNs and the token audience are **not** in this file — they are generated at provision time and
flowed in from `infra/main.bicep` (`mcpServerFqdns` map + `mcpAudience`). Adding a server means:
add an entry here **and** add its FQDN to the `mcpServerFqdns` map in `main.bicep`.
`apim-mcp-servers.bicep` loops `mcp.json` and instantiates one `apim-mcp-api.bicep` per server.

### Which agents — `mcp/mcp-policy.json` (server-keyed)

```json
{
  "renewalPeriodSeconds": 60,
  "servers": [
    { "name": "mcp", "agents": [
      { "name": "teams-agent", "appId": "<agent-app-id-guid>", "requestsPerMinute": 60 }
    ] }
  ]
}
```

**Keyed by server**, so each server has its own independent allowlist. The `appId` is the AppId
carried in the agent's AgenticIdentityToken — the `instance_identity.client_id` from the Foundry
agent definition. Discover it with **`scripts/list-agent-appids.ps1`** (read-only; run on the
in-VNet VM for private projects, since resolution reads the private data plane).

### What the policy does (one per server)

Attaches a policy to that server's MCP API. Inbound pipeline:

1. `validate-azure-ad-token` — validates the caller's **AgenticIdentityToken** against the MCP
   app-registration audience (`mcpAudience`) + this tenant, and forwards the token **unchanged**
   to the backend (edge validation is defense-in-depth on top of App Service EasyAuth).
2. `set-variable callerAppId` — reads the AppId (`appid` v1.0 claim, fallback `azp` v2.0) off
   the **already-validated** JWT object (preserving the chain of trust).
3. `choose` — one `<when>` per AppId listed under this server → `rate-limit-by-key`
   (`calls={requestsPerMinute}`, `renewal-period={renewalPeriodSeconds}`; **429** when exceeded,
   with an `x-mcp-ratelimit-remaining` header). **Deny-by-default, per-server:** any AppId not
   listed under this server (or a server absent from the JSON) hits `<otherwise>` → **403**
   `agent_not_permitted`. Being allowed on one server never implies access to another.

### Applied in two places (one wrapper, one source of truth)

`apim-mcp-compliance-all.bicep` loops `mcp.json` and applies the per-server policy to each. It
needs no backend FQDNs (only APIM control-plane inputs), so the SAME wrapper is used by both:

- **`azd up`** wires it in `infra/main.bicep` (after MCP servers, before `apim-lockdown`).
  **Bootstrap note:** the committed `mcp/mcp-policy.json` ships a **placeholder** (`appId`
  all-zeros), so out of the box MCP is effectively **deny-all** — intentional and safe, since
  the seeded agents don't call the MCP API. Before an agent can call a server, add its real
  AppId under that server and re-apply.
- **On demand** — [`.github/workflows/deploy-agent-network.yml`](../.github/workflows/deploy-agent-network.yml)
  (`workflow_dispatch`, self-hosted VNet runner, `vnet-deploy` environment) re-deploys only this
  wrapper after you edit the JSON. Applying an APIM policy is an **ARM control-plane** op, so it
  does not need the private data plane — just Azure RBAC. Needs repo variables
  `AZURE_RESOURCE_GROUP`, `MCP_COMPLIANCE_APIM_NAME`, `MCP_COMPLIANCE_AUDIENCE` (Bicep outputs;
  `azd env refresh` if missing).

Because a fresh `azd up` seeds no agents, the resolved allowlist stays deny-all until you seed
agents and run that workflow. See the [MCP compliance note](./what-runs-where.md) for how
`scripts/list-agent-appids.ps1` resolves names → AppIds from the data plane.

---

## 10. Gotchas (quick reference)

- **APIM Standard v2 cannot be created `Disabled`** (`ActivateServiceWithPrivateEndpointAccessNotAllowed`)
  — create Enabled, add the inbound PE, then flip Disabled in a second update ordered after the PE.
- **`validate-azure-ad-token` does exact-string `aud` matching.** Keep the connection `audience`
  and the policy `<audience>` identical (or list both slash/no-slash variants — this repo lists both).
- **A conditional (`if()`) module's output consumed by an always-deployed resource** needs
  safe-access (`mod.?outputs.x ?? default`) or BCP318 hard-references the non-deployed module.
- **Bicep does not interpolate `${...}` inside triple-quoted (`'''`) strings** — hence the
  `@@TOKEN@@` + `replace()` pattern in `apim-api-policy.bicep` (replace the **longest** tokens
  first), and the single-quoted `\n`-joined strings used to build the MCP policy XML.
- **APIM policy expressions are C#**, so string literals are double-quoted; inside double-quoted
  XML attributes every C# quote is emitted as the entity `&quot;`.
- **APIM `type:mcp` passthrough forwards to the backend `url` verbatim — put the MCP path there.**
  The MCP web app serves the streamable-HTTP endpoint at **`/mcp`**, not root, and APIM does
  **not** append `uriTemplate` to the backend. A bare-host backend `url` makes APIM hit the
  container root → `404 Cannot POST /`. Set the backend `url` to include the path
  (`https://<mcp-app>/mcp`) and keep `uriTemplate: '/'`.
- **MCP tool in an agent manifest = connection for auth + injected per-env URL.** The manifest
  keeps `project_connection_id` (supplies `AgenticIdentityToken` auth) but **omits `server_url`**;
  the deploy workflow injects the concrete per-env URL (from the `MCP_SERVER_URL` repo variable /
  `mcpServerUrl` input) so the manifest promotes across environments unchanged. Create/publish
  accepts a `type: mcp` tool with no `server_url`, but an actual **run rejects it** — so the URL
  must be present in the *deployed* definition.
- **`rate-limit-by-key` is supported on APIM v2 tiers** (token-bucket) but **not** on Consumption.
  v2 counters are per-gateway (a single APIM instance here, so fine).
- **Foundry cannot reach MCP backends directly** — the firewall is default-deny and the only
  agent-subnet egress is `agent → APIM inbound PE`. All MCP traffic is forced through APIM.
