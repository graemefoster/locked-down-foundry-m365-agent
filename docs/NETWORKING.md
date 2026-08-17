# Foundry Standard Agent — Network Lockdown Reference

> **Level 1 — Lock down the network.** Part of the
> [locked-down Foundry agent](../README.md) reference implementation.
> Resource deep dive: [docs/architecture.md](./architecture.md).

> The definitive, rule-by-rule reference for the network posture in this sample
> (`99-private-network-standard-agent-firewall`). Every NSG rule and every
> firewall rule is documented here with its purpose and its source-of-truth
> Microsoft Learn citation.

## TL;DR

- The **agent subnet** is **deny-by-default** on both the NSG (subnet) and the
  Azure Firewall (egress). The NSG allows only explicit service tags/subnets;
  Azure Firewall further narrows Front Door-backed dependencies with SNI-pinned
  application rules. There is **no TLS inspection**.
- The **dev VM subnet** and the **App Service spoke** remain **unrestricted** at
  the firewall — only the agent subnet is locked down.
- Observability: firewall diagnostics land in **resource-specific tables**
  (`AZFW*`), and **VNet flow logs + Traffic Analytics** on the agent subnet let
  you see exactly what is being allowed or dropped.
- ⚠️ **Known limitations:** (1) Agent 365 telemetry egress requires the broad
  `AzureFrontDoor.Frontend` service tag on the NSG — see
  [Known limitation: Agent 365 telemetry egress](#known-limitation-agent-365-telemetry-egress);
  and (2) version-over-version eval comparison (cluster analysis) is unsupported
  in Private BYO workspaces — see
  [Known limitation: version-over-version eval comparison](#️-known-limitation-version-over-version-eval-comparison-cluster-analysis).
  **Both need to be raised with the product team.**

---

## Basic vs standard agent tier (`deployStandardAgent`)

A second, orthogonal tier controls the **agent state stores**.
`deployStandardAgent` has **no default** — `azd up` **always
prompts** (or set `azd env set DEPLOY_STANDARD_AGENT true|false`).

Foundry's Agents service always needs an **account-scope capability host**. The
platform **auto-provisions** it (`<account>@aml_aiagentservice`) as a side-effect
of the Foundry account being VNet-injected for agents (stage 13) — it is **not**
declared in Bicep (ARM won't let you declare a resource whose name contains the
`@` the platform requires, and the account only ever allows one, so an explicit
declaration is both impossible to name canonically and non-idempotent). It is
therefore present in **both** tiers for free.

- **`true` — STANDARD (bring-your-own stores).** The full data plane: **CosmosDB**
  (threads), **Storage** (files) and **AI Search** (vectors), each with its own
  private endpoint, CMK encryption and data-plane RBAC, wired to the project via a
  **project-scope** capability host. This is the enterprise posture (full data
  sovereignty over agent state).
- **`false` — BASIC (Microsoft-managed stores).** **No Cosmos, Storage or AI
  Search at all** — the auto-provisioned account capability host runs the Agents
  service on Microsoft-managed stores. The whole BYO data plane and its three
  private endpoints, storage CMK re-PUT, KV-crypto RBAC and the project capability
  host are skipped.

Everything else is identical across tiers: the Foundry account, its VNet
injection + private endpoint + CMK, the project + its identity, Key Vault, ACR,
the model gateway (APIM), the YARP edge and the MCP workload are all still
deployed and still locked down.

**Why:** BASIC is a much **faster** demo — it removes the two slowest chunks of
the provision (the ~9½‑min Cosmos/Search/Storage build and a big slice of the
~8‑min private-endpoint block, plus the project capability-host wait) while
staying network-locked-down. Set `deployStandardAgent=false` for the quickest
demo, or keep `deployStandardAgent=true` for the full data-sovereign reference.

---

## Topology

| VNet | CIDR | Purpose | Lockdown |
|------|------|---------|----------|
| Hub | `10.0.0.0/16` | Azure Firewall + DNS Private Resolver | n/a (shared services) |
| Foundry spoke | `10.2.0.0/16` | Agent subnet, PEs, deployment scripts, VMs and Bastion | **agent, VM and Bastion subnets** |
| App Service spoke | `10.1.0.0/16` | YARP reverse proxy (App Service) | unrestricted |
| **Model-gateway spoke** | `10.3.0.0/16` | APIM Standard v2 + provider Foundry (always deployed) | **both subnets routed via firewall** |

Foundry spoke subnets:

| Subnet | CIDR | Notes |
|--------|------|-------|
| `agent-subnet` | `10.2.0.0/24` | Delegated to `Microsoft.App/environments` (ACA workload profile). **Locked down.** |
| `pe-subnet` | `10.2.1.0/24` | Private endpoints (AI account, Search, Storage, Cosmos, Key Vault, ACR). |
| `VirtualMachines` | `10.2.2.0/24` | Linux worker VM (Actions runner) and the optional Windows dev/jumpbox VM. Unrestricted egress. |
| `DeploymentScripts` | `10.2.3.0/24` | Delegated to `Microsoft.ContainerInstance/containerGroups` for deployment script containers. |
| `AzureBastionSubnet` | `10.2.4.0/24` | Azure Bastion host for interactive RDP/SSH access. Exists only when `deployBastion=true`. |

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
Defined in [`infra/stages/00-foundation/network/foundry-spoke-vnet.bicep`](../infra/stages/00-foundation/network/foundry-spoke-vnet.bicep).

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
| 115 | `Allow-ModelGatewayApim-Outbound` | model-gateway PE subnet (`10.3.1.0/24`) | 443 / TCP | Reach the **APIM model-gateway inbound private endpoint** (dynamic model discovery + inference). **Without this, `Deny-All-Outbound` blocks the agent → APIM PE and Foundry finds zero models.** |
| 120 | `Allow-DnsResolver-Udp-Outbound` | DNS resolver `/32` | 53 / UDP | DNS to the hub DNS Private Resolver over peering. |
| 121 | `Allow-DnsResolver-Tcp-Outbound` | DNS resolver `/32` | 53 / TCP | DNS (TCP) to the hub resolver. |
| 130 | `Allow-Firewall-Outbound` | firewall private IP `/32` | 443 / TCP | UDR next hop for internet-bound egress. HTTPS only, single host. |
| 140 | `Allow-AzureActiveDirectory-Outbound` | `AzureActiveDirectory` | 443 / TCP | Managed-identity tokens + Entra ID login. |
| 150 | `Allow-MicrosoftContainerRegistry-Outbound` | `MicrosoftContainerRegistry` | 443 / TCP | Platform/system image pulls (Microsoft Artifact Registry). |
| 160 | `Allow-AzureFrontDoorFirstParty-Outbound` | `AzureFrontDoor.FirstParty` | 443 / TCP | Hard dependency of MCR (`mcr.microsoft.com`, `*.data.mcr.microsoft.com`) because those endpoints are Front Door-backed. The hub firewall SNI-pins this to the MCR FQDNs below. |
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

## VM subnet NSG (`<vnet>-vm-nsg`)

Attached to `VirtualMachines`. Deny-by-default inbound; outbound is left open because egress is
forced through the Azure Firewall by UDR.

### Inbound

| Prio | Name | Src | Dst | Port/Proto | Why |
|------|------|-----|-----|------------|-----|
| 100 | `Allow-Rdp-From-Bastion` | `AzureBastionSubnet` (`10.2.4.0/24`) | `VirtualMachines` (`10.2.2.0/24`) | 3389 / TCP | Windows dev VM RDP access from Bastion only. |
| 110 | `Allow-Ssh-From-Bastion` | `AzureBastionSubnet` (`10.2.4.0/24`) | `VirtualMachines` (`10.2.2.0/24`) | 22 / TCP | Optional Linux worker VM SSH access from Bastion only. |
| 4000 | `Deny-All-Inbound` | `*` | `*` | `*` | Deny all other inbound traffic to the VM subnet. |

---

## Bastion subnet NSG (`<vnet>-bastion-nsg`)

Attached to `AzureBastionSubnet`. Deny-by-default except for the Azure Bastion platform-required
flows and RDP/SSH to the VM subnet.

### Inbound

| Prio | Name | Src | Dst | Port/Proto | Why |
|------|------|-----|-----|------------|-----|
| 100 | `Allow-Https-Internet-Inbound` | `Internet` | `*` | 443 / TCP | Azure Bastion browser/client ingress. |
| 110 | `Allow-GatewayManager-Inbound` | `GatewayManager` | `*` | 443 / TCP | Azure Bastion control-plane management. |
| 120 | `Allow-LoadBalancer-Inbound` | `AzureLoadBalancer` | `*` | 443 / TCP | Azure Bastion health probes. |
| 130 | `Allow-BastionHost-Inbound` | `AzureBastionSubnet` (`10.2.4.0/24`) | `AzureBastionSubnet` (`10.2.4.0/24`) | 8080, 5701 / `*` | Bastion host-to-host communication. |
| 4000 | `Deny-All-Inbound` | `*` | `*` | `*` | Deny all other inbound traffic to the Bastion subnet. |

### Outbound

| Prio | Name | Src | Dst | Port/Proto | Why |
|------|------|-----|-----|------------|-----|
| 100 | `Allow-SshRdp-VmSubnet-Outbound` | `AzureBastionSubnet` (`10.2.4.0/24`) | `VirtualMachines` (`10.2.2.0/24`) | 22, 3389 / TCP | Bastion sessions to VMs; scoped to the VM subnet, not the whole VNet. |
| 110 | `Allow-AzureCloud-Outbound` | `AzureBastionSubnet` (`10.2.4.0/24`) | `AzureCloud` | 443 / TCP | Azure Bastion platform dependencies. |
| 120 | `Allow-Internet-Outbound` | `AzureBastionSubnet` (`10.2.4.0/24`) | `Internet` | 443 / TCP | Certificate revocation checks. |
| 130 | `Allow-BastionHost-Outbound` | `AzureBastionSubnet` (`10.2.4.0/24`) | `AzureBastionSubnet` (`10.2.4.0/24`) | 8080, 5701 / `*` | Bastion host-to-host communication. |
| 4000 | `Deny-All-Outbound` | `*` | `*` | `*` | Deny all other outbound traffic from the Bastion subnet. |

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

## ⚠️ Known limitation: version-over-version eval comparison (cluster analysis)

> **Not a networking-rule gap — a Foundry *workspace* limitation that only bites
> in the Private BYO-network posture this sample deploys. Tracked as a platform
> missing-feature to raise with the product team.**

The agent evaluation workflow (using `microsoft/ai-agent-evals`) scores the agent
against a dataset. The action can also produce a **version-over-version comparison**
(e.g. latest deployed agent vs. the previous version) so you can catch regressions.

**What we found:**

- Per-version scoring works perfectly on the in-VNet runner (all evaluators score
  every conversation).
- The comparison step, however, calls `project_client.beta.insights.generate(...)`
  (`action.py` → `generate_comparison_insight`), which performs **cluster analysis**.
- In a **Private BYO-network (bring-your-own-VNet) Foundry workspace** — exactly the
  locked-down posture in this repo — that API returns:

  > `(UserError) Insights generation request is invalid. Cluster analysis is not
  > supported in Private BYO enabled workspaces.`

- The exception is **uncaught** and propagates, so the whole action **fails the run
  even though every per-version score succeeded**. It fires only when two agent
  versions are evaluated together (`len(agent_ids) > 1`).

**Why this happens:**

- The comparison feature depends on a **server-side cluster-analysis service** that is
  simply not offered to Private BYO workspaces (a data-plane feature gap, not an RBAC
  or firewall/NSG issue — no network rule can enable it).

**How we mitigate it (implemented):**

- The nightly workflow **defaults to a single-agent evaluation of the latest version**,
  so the run is green and a full scored report still posts every night.
- A comparison run remains **opt-in**: pass the `agentIds` (two `name:version` ids) and
  `baselineAgentId` dispatch inputs. That path will fail in *this* workspace but works
  against a non-private workspace (and will "just work" here if/when the platform adds
  support).

**Action item to raise with the product team:**

1. Support **comparison insights / cluster analysis for Private BYO-network
   workspaces**, or provide a documented alternative for regression comparison that
   does not depend on the cluster-analysis service.

---

## Azure Firewall — deny-by-default for the agent subnet

Basic tier, defined in [`infra/stages/00-foundation/network/firewall.bicep`](../infra/stages/00-foundation/network/firewall.bicep).
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
| 310 | `Net-AgentAllow` / `AllowAgentServiceTagsHttps` | agent subnet `10.2.0.0/24` | `AzureActiveDirectory`, `MicrosoftContainerRegistry`, `AzureMonitor`, `AzureMachineLearning` | 443 / TCP | Approved Azure control-plane service tags on 443. MCR's Front Door-backed hostnames are handled by application rule below instead of a broad `AzureFrontDoor.FirstParty` firewall network allow. |

### Application rules

| Prio | Collection / Rule | Src | Target FQDNs | Why |
|------|-------------------|-----|--------------|-----|
| 400 | `App-UnrestrictedNonAgent` / `AllowNonAgentWebOut` | dev VM + App Service spoke | `*` (80/443) | Keep the dev VM + App Service spoke's general web egress. |
| 410 | `App-AgentAllow` / `AllowMcrFrontDoor` | agent subnet `10.2.0.0/24` | `mcr.microsoft.com`, `*.data.mcr.microsoft.com` (443) | **Microsoft Container Registry, SNI-pinned.** Microsoft documents these MCR endpoints as Front Door-backed; the NSG needs `AzureFrontDoor.FirstParty`, but the firewall constrains it to MCR hostnames. |
| 410 | `App-AgentAllow` / `AllowAgent365Telemetry` | agent subnet `10.2.0.0/24` | `agent365.svc.cloud.microsoft` (443) | **A365 telemetry, SNI-pinned.** The real enforcement point for the broad NSG `AzureFrontDoor.Frontend` allow — filters by TLS SNI (no TLS inspection), so agent egress to Front Door is constrained to this single hostname. |

The agent subnet's application rules are only the MCR Front Door hostnames and
the A365 telemetry FQDN above; all other agent L7/FQDN egress falls through to
the implicit deny. Combined with the service-tag network rule, the agent can
reach only the approved Azure control-plane surfaces plus those pinned FQDNs.

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

> **Naming:** the Bicep/spoke is called *model-gateway*, but conceptually this APIM is the
> shared **AI gateway** (models + MCP + M365 auth). See [docs/ai-gateway.md](./ai-gateway.md).
> The rule and resource names below keep the `model-gateway` prefix.

Always deployed. It adds a
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

## Teams / M365 publish inbound path

Always deployed. Publishes the primary
agent to Microsoft Teams / M365 Copilot per the Learn article
[Publish agents to Microsoft 365 and Teams by using the REST API](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-copilot-virtual-network).
Reuses the (now always-on) shared APIM gateway spoke.

### Inbound flow

The **Azure Bot Service is a registration only** — not a hop in the data path. It holds
the bot identity + messaging endpoint and connects the **Teams channel** to that
endpoint (YARP here). Microsoft's public **Bot Connector** reads it, then POSTs
activities directly to YARP:

```
Teams / M365 Copilot
  → Bot Connector / Channel Adapter (Microsoft, public)
        (delivers to the messaging endpoint the Azure Bot Service registration
         declares for the Teams channel = https://<yarp-public-fqdn>/teams/<agentName>)
  → YARP App Service   (PUBLIC; managed TLS; ipSecurityRestrictions = Microsoft Teams
                        published IP ranges [52.112.0.0/14, 52.122.0.0/15 + IPv6],
                        default Deny; VNet-integrated outbound)
  → firewall (App Service spoke is unrestricted; 443 egress via the wildcard
              APPLICATION rule — no new firewall rule needed for YARP → APIM)
  → APIM inbound PE (10.3.1.x) → APIM Teams API (path-routed: /teams/{agentName})
        validate-jwt (openid-config login.botframework.com,
                      issuer https://api.botframework.com, [audience ∈ published bot App IDs])
          ↳ APIM → login.botframework.com (HTTPS:443, via firewall APP rule) to fetch
            the Bot Framework IdP OIDC metadata + signing keys — REQUIRED or 401
        rewrite-uri → /api/projects/<proj>/agents/{agentName}/endpoint/protocols/activityProtocol
  → APIM outbound VNet integration → firewall (Net-ApimToFoundryPe allow)
  → primary Foundry account private endpoint (10.2.1.x) → agent activityProtocol
```

> **The `401` trap.** APIM outbound is force-tunnelled through the firewall. `validate-jwt`
> must fetch the Bot Framework IdP's OpenID Connect metadata + signing keys from
> `login.botframework.com`; if the firewall lacks an application rule for that FQDN, the
> fetch is **denied** and *every* inbound Teams activity fails with `401` at APIM — even
> though the token itself is valid. Confirm via
> `AZFWApplicationRule | where SourceIp startswith '10.3.0.' | where Action=='Deny'`.
> `gateway-firewall-rules.bicep` ships the `AllowApimBotFrameworkOidc` rule for this.

The original Bot Framework JWT is **forwarded unchanged** to Foundry (Foundry
re-validates it and authorizes the end user); the APIM `validate-jwt` is
defense-in-depth. The bot App ID = the agent identity `principal_id`, which only
exists after seeding, so the audience allowlist is not pinned at provision (it
defaults to issuer-only). The `deploy-agent-network.yml` network workflow pins it
live once the agents are seeded — it resolves every `exposeToM365` agent's
`principal_id` from the Foundry data plane and re-deploys `apim-teams-api.bicep`
with `botAppIds` set. Until that workflow runs, issuer validation + serviceurl
tenant assertion + IP restriction carry the check.

> **Single-tenant lockdown via `serviceurl`.** The Bot Framework token has **no `tid`
> claim**, but its signed `serviceurl` embeds the caller's tenant GUID
> (`smba.trafficmanager.net/<region>/<tenantId>/`). The Teams API policy asserts that
> GUID equals the deployment tenant (`expectedTenantId`, wired from `tenant().tenantId`)
> and returns `403` otherwise — so only activities from your own tenant are accepted,
> on top of the `aud` (bot App ID) + `iss` + signature checks. Region-agnostic (matches
> the GUID, not the full URL). Set `expectedTenantId=''` to disable.

### New network paths (vs. the model-gateway-only topology)

- **YARP loses its private endpoint** and flips `publicNetworkAccess` to Enabled.
  It stays VNet-integrated for outbound so it can still reach the APIM inbound PE.
  MCP keeps its private endpoint. Inbound is restricted to the **Microsoft Teams
  published IP ranges** (`52.112.0.0/14`, `52.122.0.0/15` + IPv6, from the M365
  endpoints service, service area `Skype`) with a default-Deny rule.
  > ⚠️ The `AzureBotService` service tag is the wrong allow-list here — it covers
  > DirectLine + the Bot Service token cache, **not** the Teams channel adapter's
  > source IPs, so using it silently blocks all Teams traffic.
  > ⚠️ **Legacy orphan-PE trap:** environments provisioned before Teams publish became
  > always-on (i.e. with the removed `enableTeamsPublish=false` opt-out) may have a pre-flag
  > YARP private endpoint left behind, unmanaged by azd. It keeps YARP effectively private
  > (PNA Disabled) and blocks inbound. Delete the PE and set `publicNetworkAccess=Enabled`
  > manually (the Bicep is correct for fresh deploys).
- **APIM → Bot Framework IdP** (`login.botframework.com`, HTTPS:443) — a new firewall
  **application rule** (`AllowApimBotFrameworkOidc`, source apim-subnet) so `validate-jwt`
  can fetch the OIDC signing keys. Without it, inbound activities 401 (see the trap above).
- **APIM → primary Foundry PE** is a new **cross-spoke** path (gateway `apim-subnet`
  `10.3.0.0/24` → foundry `pe-subnet` `10.2.1.0/24` via the firewall). It requires:
  - a firewall **network rule** `Net-ApimToFoundryPe` (apim-subnet → foundry-pe:443), and
  - **symmetric return routing**: the foundry `pe-subnet` gets
    `privateEndpointNetworkPolicies: Enabled` + a UDR for `10.3.0.0/24 → firewall`
    (Azure Firewall does **not** SNAT private ranges, so the PE's replies must be
    routed back through it). Scoped to `/24` so intra-VNet `10.2.x` traffic (agent ↔
    PE) stays on system routes.
- **Reply path**: the agent's reply is returned to the caller over the **Microsoft
  backbone**, not egressed from the agent subnet through your firewall — so **no
  additional agent-subnet outbound rules are needed** for the Teams path.

### APIM backends

Both the Teams API and the model-gateway inference API express their Foundry targets
as first-class APIM **`backend`** entities (not hardwired `base-url`s), so topology
tooling can render the APIM → Foundry edges:

| Backend ID | API | Target |
|---|---|---|
| `foundry-<account>` | Teams | Primary Foundry account (activityProtocol via rewrite-uri). |
| `model-gateway-openai` | Model gateway | Provider Foundry OpenAI v1 data plane. |
| `model-gateway-arm` | Model gateway | ARM control plane (dynamic model discovery). |

The policies route via `<set-backend-service backend-id="…" />`.

### The DNS / firewall tradeoff

The article's happy path keeps the bot endpoint on the private
`*.services.ai.azure.com` hostname and uses **custom DNS + firewall DNAT + a TLS
cert** for that name. This template instead sets the bot endpoint to the **YARP App
Service public FQDN** with an App Service **managed certificate** — no DNS/cert to
manage. The cost is a publicly exposed App Service (hardened by the Teams published-IP
allow-list + APIM token validation). For a production perimeter, front the
private path with **Azure Application Gateway** (public IP + managed cert + WAF)
instead.

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
[`infra/stages/00-foundation/network/agent-flow-logs.bicep`](../infra/stages/00-foundation/network/agent-flow-logs.bicep):

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
   [`foundry-spoke-vnet.bicep`](../infra/stages/00-foundation/network/foundry-spoke-vnet.bicep).
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
az bicep build --file infra/main.bicep         # regenerate main.json after edits
az deployment group create \
  --resource-group <rg> \
  --template-file infra/main.bicep \
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
