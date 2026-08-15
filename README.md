---
description: A reference implementation that shows how to run an Azure AI Foundry agent inside a locked-down, network-isolated Azure landing zone, automate its deployment, and publish it to Microsoft Teams / M365 Copilot.
page_type: sample
products:
- azure
- azure-resource-manager
urlFragment: network-secured-agent
languages:
- bicep
- json
---
# Locked-down Azure AI Foundry agent, published to Microsoft Teams / M365 Copilot

A reference implementation for running an **Azure AI Foundry agent inside a private,
network-isolated Azure landing zone** — and still being able to deploy it through CI/CD
and publish it to **Microsoft Teams / M365 Copilot**.

Everything is infrastructure-as-code, deployed with [`azd`](https://aka.ms/azd) (the only
supported path). Public network access is disabled by default: every service talks over
private endpoints inside a VNet, and all egress is forced through a deny-by-default Azure
Firewall.

## Who this is for — and the three things it teaches

This sample is written for engineers who are **comfortable with Azure** (VNets, private
endpoints, RBAC, `azd`/Bicep) but **newer to Azure AI Foundry**. It answers three questions,
in order, each building on the last:

| Level | Question | Start here |
|:-----:|----------|------------|
| **1** | **How do I lock down the network** around a Foundry agent so nothing leaks in or out? | [Level 1 — Network lockdown](#level-1--lock-down-the-network) |
| **2** | **How do I automate deployment** of agents into that locked-down environment when the endpoint is private? | [Level 2 — Automate agent deployment](#level-2--automate-agent-deployment) |
| **3** | **How do I publish an agent to M365 / Teams** even though Foundry is unreachable from the public internet? | [Level 3 — Publish to Teams / M365](#level-3--publish-to-teams--m365-copilot) |

If you just want to deploy it, jump to the [Quick start](#quick-start). If you're new to
Foundry, read the primer first.

> **A cross-cutting fourth theme — governance — runs through all three levels:** who may call
> which model or tool, at what rate, under which content-safety baseline. It's enforced mostly at
> the shared private **[AI gateway](./docs/ai-gateway.md)** and summarised in
> **[docs/governance.md](./docs/governance.md)**.

## New to Foundry? A 5-minute primer

A few Foundry concepts explain *why* the design looks the way it does. Skip to
[What gets deployed](#what-gets-deployed) if they're familiar.

- **Account & project.** The **account** (`Microsoft.CognitiveServices`, kind `AIServices`) is
  the top-level resource; a **project** is an isolated workspace inside it. Agents live in a
  project and share its file/thread/search storage. The project is the unit of isolation.
- **Agents.** An agent is a model + instructions (+ optional tools), or hosted code managed by
  Foundry. This sample includes the prompt-based `teams-agent` and a source-zip hosted
  `support-case-agent` variant under `agents/`.
- **BYO data plane.** Agents are stateful, and their state lives in **your own** resources:
  **Cosmos DB** (threads), **AI Search** (vectors), **Storage** (files). Locking down the agent
  means locking down all three.
- **Capability host.** Enabling Agents on a project provisions an **Agents capability host** —
  managed compute (an Azure Container Apps environment) injected into a **delegated subnet** in
  your VNet. Hence the agent subnet is delegated to `Microsoft.App/environments`, and teardown
  must delete the capability host *before* the account/project.
- **Why "private" is the hard part.** With public access disabled, the Foundry data plane (the
  Agents REST API) is reachable **only from inside the VNet** — you can't create, publish, or
  govern agents from a laptop or a GitHub-hosted runner. This sample solves that with an
  **in-VNet self-hosted GitHub Actions runner**.

## What gets deployed

`azd up` provisions a complete, self-contained landing zone:

- **Azure AI Foundry** account + project (private endpoint, public access off, CMK encryption).
- **BYO data plane:** Azure Cosmos DB (threads), Azure AI Search (vectors), Azure Storage
  (files) — all private-endpoint only.
- **Networking:** hub + spoke VNets, Azure Firewall (deny-by-default egress), private DNS
  zones, a locked-down in-VNet VM, and VNet flow logs.
- **Always-on private APIM (AI gateway)** (Standard v2) — one shared instance fronting models,
  MCP servers, and the Teams/M365 inbound path.
- **Teams / M365 publish path:** a public YARP proxy (App Service, VNet-integrated,
  Teams-IP restricted), an MCP web app, and an Azure Bot Service registration.
- **Model gateway:** an APIM-fronted "provider" Foundry plus a second agent routed through it
  (one of the AI gateway's roles — see [docs/ai-gateway.md](./docs/ai-gateway.md)).
- **Governance:** an **RAI guardrail** (Azure Policy, Audit) auditing every model deployment's
  content filters, plus **MCP per-agent rate limiting / deny-by-default allowlists** at the
  gateway ([docs/governance.md](./docs/governance.md)).
- Key Vault + Container Registry (private) and all supporting role assignments.

Full resource-by-resource detail: **[docs/architecture.md](./docs/architecture.md)**.

## Quick start

**Prerequisites:** an Azure subscription where you can register resource providers and assign
RBAC (Azure AI Account Owner + Role Based Access Administrator or Owner), the
[`az` CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli),
[`azd`](https://aka.ms/azd), the [GitHub CLI](https://cli.github.com/) (`gh`), and PowerShell
(`pwsh`). Full list + provider registration: **[docs/deployment.md](./docs/deployment.md)**.

```bash
# 1. Provision all infrastructure.
#    azd prompts for the VM admin password, and a preprovision hook asks (once) whether to
#    deploy the optional Windows dev VM and/or the in-VNet self-hosted runner.
azd up
```

`azd` **only provisions infrastructure — it deploys no agents.** Its one post-provision step
is a host-side hook that copies the azd outputs into GitHub Actions repo variables (via
`gh variable set`) so the workflows below "just work". Because the Foundry endpoint is private,
**agent seeding, MCP compliance and Teams publishing all run from the in-VNet self-hosted
runner** — so enable it ([Level 2](#level-2--automate-agent-deployment)), then:

```bash
# 2. Deploy agents from inside the VNet (requires the self-hosted runner).
#    One workflow per agent — run whichever you need:
gh workflow run deploy-teams-agent.yml      # also publishes to Teams (gated)
```

`azd` reads defaults from [`infra/main.parameters.json`](./infra/main.parameters.json);
override any value with `azd env set VAR value`. Provisioning may need one retry on a
transient Key Vault CMK propagation delay — it is idempotent. Full walkthrough, seeding
options, and troubleshooting: **[docs/deployment.md](./docs/deployment.md)**.

---

## Level 1 — Lock down the network

Establish a deny-by-default perimeter around the agent and every BYO dependency: private
endpoints on all services, an agent subnet that is deny-by-default on both the NSG and the
Azure Firewall, service-tag-only egress (no FQDN wildcards, no TLS inspection), CMK
encryption, and VNet flow logs for observability.

| Doc | What's inside |
|-----|---------------|
| **[NETWORKING.md](./docs/NETWORKING.md)** | The definitive, rule-by-rule network reference: topology, every NSG and firewall rule with its purpose, the two known limitations to raise with the product team, observability (firewall logs + VNet flow logs), and a debugging playbook. |
| **[docs/architecture.md](./docs/architecture.md)** | Resource-by-resource deep dive: Foundry account/project, BYO Cosmos/Search/Storage, private DNS zones, RBAC role assignments, and the Bicep `stages/` module structure. |
| **[docs/rai-guardrail-policy.md](./docs/rai-guardrail-policy.md)** | Governing the *model* layer: a strict content-filter (Responsible AI) baseline assigned as an Azure Policy initiative (Audit), why it can't block, and an optional non-compliant demo. (Part of the broader [governance](./docs/governance.md) story.) |

## Level 2 — Automate agent deployment

The Foundry endpoint is private, so agents can't be created from a laptop or a GitHub-hosted
runner. The pattern here: an **in-VNet self-hosted GitHub Actions runner** (the locked-down
Linux VM) reaches the private endpoint directly and authenticates as its **managed identity**;
each agent is a manifest plus a thin caller workflow that reuses one shared deploy workflow.

| Doc | What's inside |
|-----|---------------|
| **[docs/deployment.md](./docs/deployment.md)** | Prerequisites, provider registration, `azd` provisioning, deploying/seeding agents from the runner, maintenance & troubleshooting. |
| **[docs/github-runner.md](./docs/github-runner.md)** | The in-VNet self-hosted runner: why it's needed, its "trusted-only" security model, how it authenticates (managed identity → Key Vault PAT), setup, verification, and teardown. |
| **[docs/what-runs-where.md](./docs/what-runs-where.md)** | Orientation map of every `hooks/` and `scripts/` file: what triggers it, where it runs (azd host vs in-VNet VM), and which identity it uses. |
| **[docs/ai-gateway.md](./docs/ai-gateway.md)** | The always-on private **AI gateway** — one shared APIM (Standard v2, private) fronting **models** (keyless Entra auth, dynamic discovery), **MCP servers** (per-agent rate limiting / deny-by-default allowlists), and the **Teams/M365** inbound auth checks. |

## Level 3 — Publish to Teams / M365 Copilot

Expose a private agent to Microsoft Teams and M365 Copilot even though Foundry has no public
endpoint. Microsoft's public Bot Connector can't reach a private endpoint, so the inbound path
is **Teams → Bot Connector → public YARP proxy (Teams-IP restricted) → private APIM
(`validate-jwt`) → the agent's activityProtocol endpoint**, with Bot Framework JWT validation
and single-tenant lockdown.

| Doc | What's inside |
|-----|---------------|
| **[docs/teams-m365.md](./docs/teams-m365.md)** | The full publish path: why the Azure Bot Service is a registration (not an appliance), the inbound firewall/JWT flow, the DNS/firewall tradeoff, the workflow-driven publish, and the delegated-token requirement. |
| **[NETWORKING.md § Teams / M365 publish inbound path](./docs/NETWORKING.md#teams--m365-publish-inbound-path)** | The network-level detail: the `401` trap (APIM → `login.botframework.com`), the cross-spoke APIM → Foundry path, and the Teams published-IP allow-list. |

---

## Documentation

**Cross-cutting** (all levels): [architecture](./docs/architecture.md) ·
[governance](./docs/governance.md) · [ai-gateway](./docs/ai-gateway.md) ·
[what-runs-where](./docs/what-runs-where.md).
Each level's docs are linked from its section above.

> **Roadmap.** Where this is heading (hosted agents, eval gates, multi-environment promotion,
> governance, a sample UI) lives in **[BACKLOG.md](./BACKLOG.md)** — project direction, not part
> of the learning path.

## References

- [Azure AI Foundry networking (private link)](https://learn.microsoft.com/en-us/azure/ai-foundry/how-to/configure-private-link?tabs=azure-portal&pivots=fdp-project)
- [Azure AI Foundry RBAC](https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/rbac-azure-ai-foundry?pivots=fdp-project)
- [Publish agents to Microsoft 365 and Teams (REST API)](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/publish-copilot-virtual-network)
- [Private Endpoint documentation](https://learn.microsoft.com/en-us/azure/private-link/)
- [Network security best practices](https://learn.microsoft.com/en-us/azure/security/fundamentals/network-best-practices)
