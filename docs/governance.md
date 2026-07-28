# Governance

> **Cross-cutting** (governs the model, agent/tool, and inbound layers). Part of the
> [locked-down Foundry agent](../README.md) reference implementation.

Locking down the *network* (Level 1) keeps traffic on private paths, but it doesn't decide
**who may do what, to which model or tool, at what rate**. That's governance — and in this
sample it is layered, config-as-data, and enforced at a **single choke point** (the private
[AI gateway](./ai-gateway.md)) wherever possible.

This page is the map. Each layer has its own deep-dive doc; the goal here is to show how they
fit together and where each one lives in the code.

## The governance layers

| Layer | What it controls | Mechanism | Deep dive |
|-------|------------------|-----------|-----------|
| **Model / content safety** | The content filters (Responsible AI) wrapped around every model deployment's prompts + completions. | **Azure Policy** initiative (Audit) with a strict baseline, assigned at the resource group. | [rai-guardrail-policy.md](./rai-guardrail-policy.md) |
| **Agent / tool access** | Which agents may call which **MCP servers**, and at what requests-per-minute. Deny-by-default. | **APIM** `validate-azure-ad-token` + `rate-limit-by-key`, driven by two repo-tracked JSON files. | [ai-gateway.md § MCP](./ai-gateway.md#9-mcp-servers--per-agent-rate-limiting-config-as-data) |
| **Model access (gateway auth)** | Who may call the model gateway. | **APIM** dual check: Entra JWT (`validate-azure-ad-token`, pinned to the caller MI) **+** subscription key. | [ai-gateway.md § Auth](./ai-gateway.md#3-auth-model--two-layers-defense-in-depth) |
| **Inbound identity (M365 / Teams)** | That inbound Teams activities carry a valid Bot Framework token **and** originate from your own tenant. | **APIM** `validate-jwt` + a **single-tenant** `serviceurl` assertion (403 otherwise). | [teams-m365.md](./teams-m365.md) · [NETWORKING.md](../NETWORKING.md#teams--m365-publish-inbound-path) |

Three of the four layers are enforced by the **same private APIM instance** — the AI gateway —
which is why it is the natural home for rate limits, quotas, and usage attribution. The model
content-safety layer is the exception: it is an Azure Policy control over the *resource*
configuration, not a runtime traffic gate.

## Where it lives in the code

Most governance is deployed by the **`30-governance` Bicep stage** — deliberately the **last**
stage, so it hardens the workload only after everything it governs exists. It contains:

- **RAI guardrail** — `governance/rai-guardrail-assignment.bicep` (+ optional
  `governance/noncompliant-model-demo.bicep`).
- **MCP compliance** — `model-gateway/apim-mcp-compliance-all.bicep` (per-server rate-limit /
  allowlist policies).
- **Gateway & Teams auth policies** — `model-gateway/apim-api-policy.bicep` (model gateway JWT),
  `model-gateway/apim-teams-api.bicep` (Bot Framework JWT + single-tenant lockdown).
- **`apim-lockdown.bicep`** runs strictly last, flipping APIM's `publicNetworkAccess` to
  Disabled after every API/policy write.

## Config-as-data & deny-by-default

Governance here is reviewable in PRs, not clicked into a portal:

- **`mcp/mcp.json`** declares which MCP servers exist; **`mcp/mcp-policy.json`** declares which
  agents may call each server and at what RPM. An agent not listed under a server gets **403**;
  a server absent from the policy is fully denied. (Both files are kept trackable past
  `.gitignore`'s `*.json` rule via a `!mcp/*.json` negation.)
- The committed `mcp-policy.json` ships a **placeholder** AppId, so a fresh `azd up` is
  effectively **deny-all** for MCP — safe, because the seeded agents don't call MCP.

> **Apply order matters.** A fresh `azd up` seeds no agents, so the resolved MCP allowlist can't
> know real agent AppIds yet — it stays deny-all. After you seed agents, run
> [`.github/workflows/deploy-compliancy.yml`](../.github/workflows/deploy-compliancy.yml) to
> resolve each agent **name → live AppId** (via `scripts/list-agent-appids.ps1`, which reads the
> private Foundry data plane from the in-VNet runner) and re-apply the policy. Re-run it whenever
> you edit the JSON. See [what-runs-where.md](./what-runs-where.md) and
> [ai-gateway.md § MCP](./ai-gateway.md#9-mcp-servers--per-agent-rate-limiting-config-as-data).

## Roadmap

Governance is an area still under active development — RPM/token quotas per consumer, usage
metrics and cost attribution, and optional content-safety/PII guardrails in the gateway path are
tracked in **[BACKLOG.md § Epic 5](../BACKLOG.md#epic-5--governance-rpm-token-usage--cost-controls-blue-sky)**.
