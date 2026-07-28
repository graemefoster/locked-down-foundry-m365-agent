# RAI Guardrail Policy (Azure Policy · Audit)

> Part of the [network-secured Foundry agent](../README.md) accelerator. Governs the
> **content-filter / Responsible AI (RAI)** configuration of model deployments.

This capability assigns a **built-in Azure Policy initiative** that audits every
Cognitive Services / Azure AI Foundry **model deployment** in the resource group
against a strict content-filtering baseline, and (optionally) deploys a deliberately
**non-compliant** model so you can watch the guardrail flag it.

---

## TL;DR

- **On by default.** `azd provision` assigns the guardrail at the Foundry resource group.
- **Audit-only — it does NOT block.** The built-in reports Compliant / Non-compliant; it
  never rejects a deployment. See [Why it can't block](#why-it-cant-block).
- The primary `gpt-5.4` deployment uses Azure's default RAI policy and is **Compliant**.
- Flip `NONCOMPLIANT_MODEL_DEMO_ENABLED=true` to add a weak deployment and see it flagged.

---

## What gets assigned

The built-in **policy set (initiative)**:

| | |
|---|---|
| Display name | `[Preview]: Guardrail for Cognitive Services Deployments` |
| ID | `/providers/Microsoft.Authorization/policySetDefinitions/5207647b-3e83-4e28-b836-c382cb5e2a2e` |
| Category | Cognitive Services |
| Effect | **Audit** (the only real option — see below) |
| Scope | the Foundry **resource group** |

Three layers are involved:

```
Policy definitions (per-filter rules, e.g. "Hate")
   └─ Policy set / initiative (5207647b…)      ← the reusable bundle
        └─ Policy assignment (this repo)        ← binds it to the RG + supplies STRICT values
             └─ evaluates each model deployment's RAI (content filter) policy
                  → Compliant / Non-compliant
```

### The strict baseline this repo applies

`infra/stages/30-governance/governance/rai-guardrail-assignment.bicep` narrows every knob to its
strictest value (a single allowed value = *mandatory*; two values would mean *either is fine*):

| Filter | Prompt | Completion | Requirement |
|---|:---:|:---:|---|
| Sexual, Hate, Violence, Self-harm | ✅ | ✅ | enabled **and** blocking, severity `Medium`/`High` |
| Jailbreak (direct attack) | ✅ | — | enabled **and** blocking |
| Indirect Attack (XPIA) + Spotlighting | ✅ | — | enabled **and** blocking |
| Profanity | ✅ | ✅ | enabled **and** blocking |
| Protected Material (Code + Text) | — | ✅ | enabled **and** blocking |
| RAI streaming mode (`raiPolicyMode`) | — | — | **`Default`** (synchronous, block-capable) — not `Asynchronous_filter` |

A deployment whose RAI policy relaxes **any** of these reports **Non-compliant**.

---

## Why it can't block

The built-in initiative — and every one of its member policy definitions — allows only
**`Audit`** or **`Disabled`** as its effect, and runs in **`mode: Microsoft.CognitiveServices.Data`**
(a data-plane / resource-provider mode). There is **no built-in Deny variant**. Consequently:

- Assigning it (Audit) only **reports** compliance in the Azure Policy blade.
- Creating a non-compliant deployment still **succeeds** — nothing is rejected.

To actually *block* a non-compliant deployment you would have to author a **custom**
control-plane (`mode: All`) Deny policy that inspects the deployment's `raiPolicyName` /
the `raiPolicies` resource — that is intentionally **out of scope** here.

### Model vs agent scope

This is a **model / inference-layer** control. It governs the content filters wrapped
around a *model deployment's* prompts and completions. It does **not** cover
**agent-level** concerns (tool-call governance, PII stripping on tool I/O, agent egress) —
those are configured in the Foundry project / your network modules, not this initiative.

---

## Toggling

Both flags live in `infra/main.parameters.json` (azd env vars):

| azd env var | Bicep param | Default | Effect |
|---|---|:---:|---|
| `RAI_GUARDRAIL_ENABLED` | `enableRaiGuardrailPolicy` | `true` | Assign the strict Audit guardrail at the RG. |
| `NONCOMPLIANT_MODEL_DEMO_ENABLED` | `enableNonCompliantModelDemo` | `false` | Also deploy the weak demo model that fails the guardrail. |

```bash
azd env set RAI_GUARDRAIL_ENABLED true            # (default)
azd env set NONCOMPLIANT_MODEL_DEMO_ENABLED true  # opt in to the demo
azd provision
```

---

## The non-compliant demo

When enabled, `infra/stages/30-governance/governance/noncompliant-model-demo.bicep` creates:

1. A **weak custom RAI policy** (`weak-demo-policy`) that violates the baseline several ways:
   - `mode: Asynchronous_filter` → breaks `raiPolicyMode = Default`
   - **Hate** filter `enabled: false` (prompt + completion)
   - **Violence** filter `blocking: false`
   - **Jailbreak** detection `enabled: false`
2. A model deployment (`noncompliant-demo`, reusing the primary model at capacity `1`) that
   references that weak policy.

The deployment is **created successfully** (Audit doesn't block) and then reports
**Non-compliant** against the Hate, Violence, Jailbreak, and guardrail-mode controls.

> **Quota note:** the demo reuses the `gpt-5.4` GlobalStandard model. If quota is tight,
> lower/point it at a smaller model via the module's `modelCapacity` / `modelName` params.

---

## Checking compliance

Compliance evaluation is **not instant** (it can lag up to ~30 minutes). Trigger an
on-demand scan to speed it up:

```bash
RG=$(azd env get-value AZURE_RESOURCE_GROUP)

# 1. Force an evaluation
az policy state trigger-scan -g "$RG"

# 2. List everything the guardrail flagged as Non-compliant
az policy state list -g "$RG" \
  --filter "policyAssignmentName eq 'rai-guardrail-strict' and complianceState eq 'NonCompliant'" \
  --query "[].{resource:resourceId, control:policyDefinitionReferenceId}" -o table

# 3. Roll-up summary for the assignment
az policy state summarize -g "$RG" -o table
```

The `noncompliant-demo` deployment should appear under controls such as *Hate*,
*Violence*, *Jailbreak*, and *guardrail mode*. Set `NONCOMPLIANT_MODEL_DEMO_ENABLED=false`
and re-provision to remove it.

---

## Files

| File | Purpose |
|---|---|
| `infra/stages/30-governance/governance/rai-guardrail-assignment.bicep` | Policy assignment (built-in initiative, strict Audit params). |
| `infra/stages/30-governance/governance/noncompliant-model-demo.bicep` | Optional weak RAI policy + model deployment for the demo. |
| `infra/main.bicep` | Feature flags, module wiring, `RAI_GUARDRAIL_ASSIGNMENT_NAME` / `NONCOMPLIANT_DEMO_DEPLOYMENT_NAME` outputs. |
| `infra/main.parameters.json` | `RAI_GUARDRAIL_ENABLED`, `NONCOMPLIANT_MODEL_DEMO_ENABLED` defaults. |
