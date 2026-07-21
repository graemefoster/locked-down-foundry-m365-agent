# Foundry Standard Agent — Network Lockdown Reference

> The definitive, rule-by-rule reference for the network posture in this sample
> (`99-private-network-standard-agent-firewall`). Every NSG rule and every
> firewall rule is documented here with its purpose and its source-of-truth
> Microsoft Learn citation.

## TL;DR

- The **agent subnet** is **deny-by-default** on both the NSG (subnet) and the
  Azure Firewall (egress). It may only talk to an explicit, **service-tag-only**
  allow-list — **no FQDN rules, no `*.` wildcards, no TLS inspection**.
- The **dev VM subnet** and the **App Service spoke** remain **unrestricted** at
  the firewall — only the agent subnet is locked down.
- Observability: firewall diagnostics land in **resource-specific tables**
  (`AZFW*`), and **VNet flow logs + Traffic Analytics** on the agent subnet let
  you see exactly what is being allowed or dropped.
- ⚠️ **One known exception:** Agent 365 telemetry egress requires the broad
  `AzureFrontDoor.Frontend` service tag on the NSG — see
  [Known limitation: Agent 365 telemetry egress](#known-limitation-agent-365-telemetry-egress).
  **This needs to be raised with the product team.**

---

## Topology

| VNet | CIDR | Purpose | Lockdown |
|------|------|---------|----------|
| Hub | `10.0.0.0/16` | Azure Firewall + DNS Private Resolver | n/a (shared services) |
| Foundry spoke | `10.2.0.0/16` | Agent subnet + PE subnet + dev VM | **agent subnet only** |
| App Service spoke | `10.1.0.0/16` | YARP reverse proxy (App Service) | unrestricted |
| **Model-gateway spoke** (optional) | `10.3.0.0/16` | APIM Standard v2 + provider Foundry (only when `enableModelGateway=true`) | **both subnets routed via firewall** |

Foundry spoke subnets:

| Subnet | CIDR | Notes |
|--------|------|-------|
| `agent-subnet` | `10.2.0.0/24` | Delegated to `Microsoft.App/environments` (ACA workload profile). **Locked down.** |
| `pe-subnet` | `10.2.1.0/24` | Private endpoints (AI account, Search, Storage, Cosmos, Key Vault, ACR). |
| `VirtualMachines` | `10.2.2.0/24` | Dev/jumpbox VM. Unrestricted egress. |

Routing: a UDR sends `0.0.0.0/0` from the agent and VM subnets to the firewall
private IP. DNS for both spokes points at the hub DNS Private Resolver inbound
endpoint.

---

## Why service tags and not FQDNs?

The agent subnet is an **Azure Container Apps (ACA) workload-profile
environment**. Azure documents that such subnets should follow the ACA firewall
guidance, and that **TLS inspection is not supported** for Foundry hosted
agents. That rules out L7/FQDN application rules for the agent's own HTTPS
egress, so we govern it purely with **network rules keyed on Azure service
tags** — the tightest option that still works without breaking the platform.

- ACA VNet/NSG + firewall requirements: <https://learn.microsoft.com/azure/container-apps/firewall-integration>
- Foundry hosted-agent virtual networks (no TLS inspection): <https://learn.microsoft.com/azure/foundry/agents/how-to/virtual-networks>
- Foundry managed VNet required outbound rules: <https://learn.microsoft.com/azure/foundry/how-to/managed-virtual-network#required-outbound-rules>

---

## Agent subnet NSG (`<vnet>-agent-nsg`)

Attached to `agent-subnet` only. Deny-by-default in **both** directions.
Defined in [`modules-network-secured/foundry-spoke-vnet.bicep`](./modules-network-secured/foundry-spoke-vnet.bicep).

### Inbound

| Prio | Name | Src | Dst | Port/Proto | Why |
|------|------|-----|-----|------------|-----|
| 100 | `Allow-LoadBalancer-Probes-Inbound` | `AzureLoadBalancer` | agent subnet | 30000-32767 / TCP | ACA workload-profile health probes. |
| 110 | `Allow-IntraSubnet-Inbound` | agent subnet | agent subnet | `*` | ACA data-plane node/pod comms. |
| 120 | `Allow-Callers-Inbound` | `agentInboundAllowedCidrs` (App Service delegated subnet `10.1.0.0/24`) | agent subnet | 443 / TCP | The `/invoke` path from the YARP proxy. Scoped to explicit caller CIDRs, **not** the whole VNet. |
| 4000 | `Deny-All-Inbound` | `*` | `*` | `*` | Deny-by-default (blocks internet **and** unexpected VNet sources). |

### Outbound

| Prio | Name | Dst | Port/Proto | Why |
|------|------|-----|------------|-----|
| 100 | `Allow-IntraSubnet-Outbound` | agent subnet | `*` | ACA data-plane node/pod comms. |
| 110 | `Allow-PrivateEndpoints-Outbound` | `pe-subnet` (`10.2.1.0/24`) | 443 / TCP | Reach private endpoints (AI account, Search, Storage, Cosmos, Key Vault, ACR). HTTPS only, PE subnet only. |
| 115 | `Allow-ModelGatewayApim-Outbound` *(model gateway only)* | model-gateway PE subnet (`10.3.1.0/24`) | 443 / TCP | Reach the **APIM model-gateway inbound private endpoint** (dynamic model discovery + inference). Only added when `enableModelGateway=true`. **Without this, `Deny-All-Outbound` blocks the agent → APIM PE and Foundry finds zero models.** |
| 120 | `Allow-DnsResolver-Udp-Outbound` | DNS resolver `/32` | 53 / UDP | DNS to the hub DNS Private Resolver over peering. |
| 121 | `Allow-DnsResolver-Tcp-Outbound` | DNS resolver `/32` | 53 / TCP | DNS (TCP) to the hub resolver. |
| 130 | `Allow-Firewall-Outbound` | firewall private IP `/32` | 443 / TCP | UDR next hop for internet-bound egress. HTTPS only, single host. |
| 140 | `Allow-AzureActiveDirectory-Outbound` | `AzureActiveDirectory` | 443 / TCP | Managed-identity tokens + Entra ID login. |
| 150 | `Allow-MicrosoftContainerRegistry-Outbound` | `MicrosoftContainerRegistry` | 443 / TCP | Platform/system image pulls (Microsoft Artifact Registry). |
| 160 | `Allow-AzureFrontDoorFirstParty-Outbound` | `AzureFrontDoor.FirstParty` | 443 / TCP | Hard dependency of MCR (image/AKS binary delivery over Front Door). |
| 170 | `Allow-AzureMonitor-Outbound` | `AzureMonitor` | 443 / TCP | App Insights / Azure Monitor tracing + metrics. |
| 180 | `Allow-AzureMachineLearning-Outbound` | `AzureMachineLearning` | 443 / TCP | Foundry **evaluations** (Evaluators Catalogue). |
| 185 | `Allow-Agent365Telemetry-Outbound` | `AzureFrontDoor.Frontend` ⚠️ | 443 / TCP | **Agent 365 (A365) observability telemetry** to `agent365.svc.cloud.microsoft`. **Over-broad — see [Known limitation](#known-limitation-agent-365-telemetry-egress) below.** |
| 190 | `Allow-AzureDNS-Udp-Outbound` | `168.63.129.16` | 53 / UDP | Azure DNS wire server. **Never deny.** |
| 191 | `Allow-AzureDNS-Tcp-Outbound` | `168.63.129.16` | 53 / TCP | Azure DNS wire server (TCP). |
| 4000 | `Deny-All-Outbound` | `*` | `*` | Deny-by-default. |

**Least-privilege notes**

- Private egress is **not** a blanket `VirtualNetwork` allow. It is split into
  explicit destinations (agent subnet, PE subnet on 443, DNS resolver `/32` on
  53, firewall `/32` on 443). Nothing else in the VNet or peers is reachable —
  in particular the dev VM subnet is **not** reachable from the agent.
- DNS uses explicit UDP+TCP 53 rules rather than `protocol: '*'`.
- `168.63.129.16` (the Azure DNS/wire-server virtual IP) is a hard ACA
  requirement and must never be blocked.

---

## ⚠️ Known limitation: Agent 365 telemetry egress

> **This is the one rule in the whole design that is not truly least-privilege.
> It needs to be raised with the product team.**

**Agent 365 (A365) observability** exports OpenTelemetry traces/metrics/logs so
that IT admins can see agent activity in the Microsoft 365 admin center and
security teams can use Defender and Purview. When the exporter is enabled
(`ENABLE_A365_OBSERVABILITY_EXPORTER` / `EnableAgent365Exporter`), the agent
subnet must reach the A365 observability service.

**What we found (traced from the SDK + live DNS):**

- Default exporter host (`Agent365ExporterOptions.DefaultEndpointHost`):
  `agent365.svc.cloud.microsoft`
  (path `/observability/tenants/{tenantId}/otlp/agents/{agentId}/traces`, HTTPS).
- DNS chain:
  `agent365.svc.cloud.microsoft` → `api.powerplatform.com`
  → `afdfo-prod-ppapigw.trafficmanager.net`
  → `*.b01.azurefd.net` (**Azure Front Door**) → e.g. `150.171.109.20`.
- `150.171.109.0/24` is owned by the **`AzureFrontDoor.Frontend`** service tag —
  **not** `AzureFrontDoor.FirstParty`, and no `cloud.microsoft` / `PowerPlatform*`
  tag covers the frontend the client actually connects to.
- The auth token for the exporter is acquired via Entra ID
  (`AzureActiveDirectory`, already allowed).

**Why this is a problem:**

- NSGs are **L3/L4 only** — they cannot filter by FQDN or TLS SNI. Behind shared
  Front Door anycast, the *only* covering service tag is `AzureFrontDoor.Frontend`.
- `AzureFrontDoor.Frontend` spans **every Azure Front Door endpoint on the
  internet**, so allowing it on the agent NSG is effectively a broad egress path
  and a potential **data-exfiltration channel**. It is the antithesis of the
  service-tag-scoping we applied everywhere else.

**Why we accept it (for now) and how it is mitigated:**

- All agent egress is **force-tunnelled** via the UDR (`0.0.0.0/0` → Azure
  Firewall). The NSG allow only lets the packet *reach the firewall*; it is the
  firewall that should be the real gate.
- The tight enforcement therefore lives at the **firewall as an SNI-based
  application rule** pinned to the exact FQDN `agent365.svc.cloud.microsoft`
  (HTTPS, **no TLS inspection** — SNI only, which Foundry permits). This rule
  **is implemented** (`App-AgentAllow` / `AllowAgent365Telemetry`, prio 410), so
  the effective boundary for A365 egress is the single hostname — the broad NSG
  service tag only lets the packet reach the firewall.

**Options, tightest → loosest:**

| Option | Tightness | Trade-off |
|--------|-----------|-----------|
| Firewall SNI app rule for `agent365.svc.cloud.microsoft` + NSG `AzureFrontDoor.Frontend` | ✅ Best available (**implemented**) | Firewall is the real gate; NSG stays coarse. |
| Pin NSG to `150.171.109.0/24` | ⚠️ Tighter L4 | **Brittle** — AFD anycast IPs rotate; will break without warning. |
| Disable A365 observability export | ✅ Most locked-down | Lose admin-center / Defender / Purview agent visibility. |

**Action items to raise with the product team:**

1. Publish a **dedicated service tag** (e.g. `Agent365` or a `cloud.microsoft`
   first-party tag) for the A365 observability endpoint so NSGs can scope to it.
2. Or offer a **Private Link / private endpoint** for A365 observability ingest.
3. Document the official **firewall/NSG requirements** for A365 telemetry from a
   locked-down agent subnet (currently undocumented — values above were derived
   from the SDK source and live DNS resolution).

> Until one of the above lands, the recommended posture is: keep the
> `AzureFrontDoor.Frontend` NSG allow **and** add the firewall SNI application
> rule so the exact FQDN is the effective boundary.

---

## Azure Firewall — deny-by-default for the agent subnet

Basic tier, defined in [`modules-network-secured/firewall.bicep`](./modules-network-secured/firewall.bicep).
Azure Firewall has an **implicit final DENY**: anything not matched by an Allow
rule is dropped. We exploit that to lock the agent subnet while leaving the dev
VM and App Service spoke on their existing general egress.

### DNAT (unchanged)

| Name | Src | Dst | Translated | Why |
|------|-----|-----|------------|-----|
| `DNAT-ManagementHttps` | `*` | firewall public IP:443 | YARP proxy FQDN:443 | Inbound management HTTPS to the reverse proxy. |

### Network rules

| Prio | Collection / Rule | Src | Dst | Port/Proto | Why |
|------|-------------------|-----|-----|------------|-----|
| 300 | `Net-UnrestrictedNonAgent` / `AllowNonAgentNonHttpOut` | dev VM `10.2.2.0/24` + App Service spoke `10.1.0.0/16` | `*` | 1-79, 81-442, 444-65535 / Any | Keep the dev VM + App Service spoke's general non-web egress (legacy behaviour). |
| 310 | `Net-AgentAllow` / `AllowAgentServiceTagsHttps` | agent subnet `10.2.0.0/24` | `AzureActiveDirectory`, `MicrosoftContainerRegistry`, `AzureFrontDoor.FirstParty`, `AzureMonitor`, `AzureMachineLearning` | 443 / TCP | The **only** internet egress the agent is allowed. Service tags only. |

### Application rules

| Prio | Collection / Rule | Src | Target FQDNs | Why |
|------|-------------------|-----|--------------|-----|
| 400 | `App-UnrestrictedNonAgent` / `AllowNonAgentWebOut` | dev VM + App Service spoke | `*` (80/443) | Keep the dev VM + App Service spoke's general web egress. |
| 410 | `App-AgentAllow` / `AllowAgent365Telemetry` | agent subnet `10.2.0.0/24` | `agent365.svc.cloud.microsoft` (443) | **A365 telemetry, SNI-pinned.** The real enforcement point for the broad NSG `AzureFrontDoor.Frontend` allow — filters by TLS SNI (no TLS inspection), so agent egress to Front Door is constrained to this single hostname. |

The agent subnet's only application rule is the A365 telemetry FQDN above; all
other agent L7/FQDN egress falls through to the implicit deny. Combined with the
service-tag network rule, the agent can reach only the approved Azure
control-plane surfaces plus the single A365 hostname.

---

## What is deliberately NOT allowed

| Item | Why excluded |
|------|--------------|
| `AzureContainerRegistry` service tag | ACR is reached via a **private endpoint** in the PE subnet, not over the internet. |
| Any `*.` FQDN / wildcard rule | Not least-privilege; and TLS inspection is unsupported for Foundry agents. |
| Source-deploy FQDNs (`deb.debian.org`, `packages.microsoft.com`) | Source-deploy is not used in this sample. |
| Fine-tuning / sample-dataset FQDNs (`raw.githubusercontent.com`) | Not needed; kept out to stay maximally locked down. |
| Broad `VirtualNetwork` egress | Replaced by explicit subnet/host-scoped rules (see NSG notes). |
| Broad `AzureFrontDoor.Frontend` egress | Avoided everywhere **except** the one A365 telemetry exception documented above — [Known limitation](#known-limitation-agent-365-telemetry-egress). |

---

## Optional: Model Gateway spoke (APIM + provider Foundry)

Enabled with `enableModelGateway=true` (default **false**, for cost). It adds a
third spoke that fronts a "real" model provider Foundry behind Azure API
Management, and advertises APIM to the primary Foundry project as a keyless
`ApiManagement` connection. A second agent is seeded using the model
`model-gateway/<exposedModelName>`.

New spoke (`10.3.0.0/16`) subnets:

| Subnet | CIDR | Notes |
|--------|------|-------|
| `apim-subnet` | `10.3.0.0/24` | Delegated to `Microsoft.Web/serverFarms` for APIM **Standard v2 outbound VNet integration**. UDR `0.0.0.0/0 → firewall`. |
| `pe-subnet` | `10.3.1.0/24` | APIM **inbound** private endpoint + provider Foundry PE. `privateEndpointNetworkPolicies: Enabled` + UDR back to the firewall (avoids asymmetric routing). |

There is **no spoke-to-spoke peering**. Request flow:

```
primary agent (10.2.0.0/24)
  → UDR 0.0.0.0/0 → Azure Firewall            (Net-AgentToApimGateway allow)
  → APIM inbound PE (10.3.1.x)
  → APIM: validate-azure-ad-token (Entra JWT) + api-key subscription
  → APIM outbound VNet integration → provider Foundry PE (intra-spoke)
  → model
```

The API exposes three operations, all inheriting the inbound JWT + api-key checks:
`POST /deployments/{name}/chat/completions` (inference), plus **dynamic model
discovery** — `GET /deployments` (list) and `GET /deployments/{name}` (get). The
discovery operations override the backend to the provider account's **Azure Resource
Manager** deployments API (`management.azure.com/.../accounts/{provider}/deployments?api-version=2023-05-01`),
which returns the AzureOpenAI-format list the Foundry connection's dynamic discovery
parses (no static `models` array is advertised).

APIM platform egress (MI token to Entra, ARM discovery calls, telemetry to Azure
Monitor / App Insights) force-tunnels through the firewall via `Net-ApimPlatformEgress`
(service tags `AzureActiveDirectory`, `AzureResourceManager`, `AzureMonitor`, `Storage`, `KeyVault`).

**Auth — defense in depth.** The APIM inbound API enforces **both**:
1. **Entra JWT** (`validate-azure-ad-token`) — the primary project MI's token,
   validated on tenant + audience `https://cognitiveservices.azure.com` (both the
   trailing-slash and no-slash variants are accepted, since the connection sends the
   no-slash form), and optionally pinned to a caller app/client ID (`gatewayCallerAppId`).
2. **APIM subscription key** — the `api-key` header (AOAI-style). The Foundry
   connection sends it via `metadata.customHeaders`; the key is derived
   deterministically by default or overridden with the secure `gatewayApiKey`
   param. The network boundary + JWT remain the primary controls.

APIM → provider Foundry uses APIM's own system-assigned MI
(`authentication-managed-identity`), granted **Cognitive Services User** on the
provider account. The provider account has `publicNetworkAccess: Disabled` and
local auth disabled — reachable only over its private endpoint.

**Two-phase APIM lockdown.** APIM Standard v2 **cannot be created** with
`publicNetworkAccess: Disabled` (the control plane returns
`ActivateServiceWithPrivateEndpointAccessNotAllowed`). So the deployment creates
APIM with public access **Enabled**, provisions the inbound private endpoint, then
re-applies the service via `apim-lockdown.bicep` (ordered after the PE) to flip
`publicNetworkAccess` to **Disabled**. This is a property update, not a recreate;
disabling public access affects only the gateway data plane, so ARM still manages
the service afterward.

**Observability.** APIM sends resource logs/metrics to the shared Log Analytics
workspace (diagnostic settings) **and** gateway request/response telemetry to the
existing **Application Insights** component (an `applicationInsights` APIM logger +
service-scoped `applicationinsights` diagnostic, W3C correlation, 100% sampling).

---

## Observability

### Firewall diagnostics → resource-specific tables

The firewall diagnostic setting sets `logAnalyticsDestinationType: 'Dedicated'`,
so logs land in **resource-specific** tables instead of the legacy
`AzureDiagnostics` table:

- `AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWNatRule`, `AZFWDnsQuery`, …

Find what the agent tried to send and whether it was allowed/denied:

```kusto
AZFWNetworkRule
| where SourceIp startswith "10.2.0."      // agent subnet
| summarize count() by Action, DestinationIp, DestinationPort, Protocol
| order by count_ desc
```

### VNet flow logs + Traffic Analytics (agent subnet)

NSG flow logs are **retired** (no new logs after **2025-06-30**, full retirement
**2027-09-30**), so this sample uses the successor **VNet flow logs** on the
agent subnet, defined in
[`modules-network-secured/agent-flow-logs.bicep`](./modules-network-secured/agent-flow-logs.bicep):

- Target: the agent subnet.
- Storage: a dedicated locked-down account (no anonymous blob access, HTTPS
  only, TLS 1.2).
- Traffic Analytics: enabled into the deployment's Log Analytics workspace.

The flow log is a child of the **regional Network Watcher**
(`NetworkWatcher_<region>`) in the auto-created `NetworkWatcherRG`, so the module
is deployed at that resource group's scope.

- VNet flow logs: <https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview>
- NSG flow logs retirement: <https://learn.microsoft.com/azure/network-watcher/nsg-flow-logs-overview>

> **⚠️ Gotcha — flow logs capture NOTHING if the storage account has
> `publicNetworkAccess: Disabled`.** The Network Watcher writer is a Microsoft
> service outside your VNet; with the public endpoint fully sealed, even the
> `AzureServices` trusted-services *bypass is ignored* (documented behaviour), and
> there is no private-endpoint fallback for the writer. Result: flow log
> `provisioningState: Succeeded` but the `NTANetAnalytics` table stays empty.
> This subscription's Azure Policy force-disables storage public access, which is
> exactly how we ended up with empty flow logs. Fix:
> `az storage account update -n <sa> -g <rg> --public-network-access Enabled --default-action Deny --bypass AzureServices`
> (add a policy exemption or it will re-flip). If you can't, rely on **firewall
> logs** instead — they were sufficient to diagnose the model-gateway issue.

### App Insights / APIM gateway logs

- **APIM gateway requests** land in `AzureDiagnostics` (`ResourceType == "SERVICE"`,
  `Category == "GatewayLogs"`). Useful fields: `method_s`, `url_s`, `responseCode_d`,
  `backendResponseCode_d`, `lastError_reason_s`. This shows every request that
  *reaches* the APIM gateway (private or public) and its result.

  ```kusto
  AzureDiagnostics
  | where ResourceType == "SERVICE" and Category == "GatewayLogs"
  | where url_s contains "deployments"
  | project TimeGenerated, method_s, url_s, responseCode_d, backendResponseCode_d, lastError_reason_s
  | order by TimeGenerated desc
  ```

- **App Insights** request/dependency telemetry is in `AppRequests` / `AppDependencies`.
- Mind the **ingestion lag** (~5–15 min) before judging "nothing in the logs".

---

## 🔧 Debugging playbook: model-gateway agent can't reach its model

Hard-won lessons from a multi-hour "agent finds zero models" hunt. Check in this
order — the earlier items are the ones that actually bit us.

1. **Is it a NETWORK-PATH problem, not a config problem?** The deny-by-default
   agent NSG blocks outbound to the APIM private endpoint unless explicitly
   allowed. The fix that finally worked was the `Allow-ModelGatewayApim-Outbound`
   rule (agent subnet → APIM PE CIDR :443) in
   [`foundry-spoke-vnet.bicep`](./modules-network-secured/foundry-spoke-vnet.bicep).
   **Verify the runtime path in the firewall** — you should see the agent subnet
   reach the APIM PE IP:

   ```kusto
   AZFWNetworkRule
   | where SourceIp startswith "10.2.0." and DestinationIp == "<apim-pe-ip>"   // e.g. 10.3.1.4
   | project TimeGenerated, SourceIp, DestinationIp, DestinationPort, Action
   | order by TimeGenerated desc
   ```

   A row like `10.2.0.x -> 10.3.1.4 443 Allow` = the runtime path is open. **No
   row at all** = the agent never tried / was blocked before the firewall (check
   the NSG). This single query is the fastest way to confirm the fix.

2. **Don't trust the Foundry PORTAL's model list.** The portal's model-discovery
   UI runs from a **control-plane origin that cannot reach a private-only APIM**,
   so it shows **"no models" even when the agent runtime works perfectly**. We
   confirmed the agent responds with `model-gateway/gpt-5.4-mini` while the portal
   still listed zero models. Test the **agent**, not the portal, to judge success.

3. **APIM reachable at all?** From the dev VM (which uses the hub resolver), the
   APIM hostname resolves to the private PE IP and `GET
   https://<apim>.azure-api.net/inference/deployments` returns `200` with the
   model list. If the VM works but the agent doesn't, it's the agent-subnet NSG
   (step 1), not APIM.

4. **Auth (only if you get 401 in GatewayLogs).** Keyless `ProjectManagedIdentity`
   requires the APIM inference API to be `subscriptionRequired=false` — a Foundry
   connection can't send both an MI token and a subscription key. `401
   SubscriptionKeyNotFound` in GatewayLogs = the API still requires a subscription
   key.

5. **APIM `publicNetworkAccess`.** APIM Standard v2 **cannot be created** with
   `Disabled`; create Enabled, add the inbound PE, then flip to Disabled. Toggling
   it takes several minutes (`provisioningState: Updating`). Enabling it does NOT
   fix the agent (the runtime uses the private path); it only matters for
   control-plane callers — useful as a one-off *diagnostic* to prove where a
   caller originates, then revert.


---

## Deploy & validate

```bash
# From this folder
az bicep build --file main.bicep         # regenerate main.json after edits
az deployment group create \
  --resource-group <rg> \
  --template-file main.bicep \
  --parameters <your params>
```

### Post-deploy checklist

1. **Agent still works**: create/run an agent; confirm image pulls, token
   acquisition, tracing, and an evaluation all succeed.
2. **Firewall is denying**: `AZFWNetworkRule` shows `Action == "Deny"` for any
   agent egress outside the five service tags.
3. **DNS intact**: agent name resolution works (resolver + `168.63.129.16` rules).
4. **Private endpoints reachable**: agent can reach Search/Storage/Cosmos/etc.
   over the PE subnet on 443.
5. **Dev VM unaffected**: the jumpbox VM still has general internet egress.
6. **Over-blocking triage**: if something breaks, check VNet flow logs /
   Traffic Analytics and `AZFWNetworkRule` for the dropped flow, then add a
   narrowly-scoped service-tag rule.

> **Note:** on subscriptions with an Azure Policy that force-disables storage
> public network access, the flow-logs storage account may need a private
> endpoint or a policy exemption for Traffic Analytics ingestion to keep working.
