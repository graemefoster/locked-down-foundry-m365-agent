# re-org.md — Chop `infra/main.bicep` into explicit deployment stages

> **Run this from a clean session.** It is a self-contained refactor plan. Do
> **not** start it until `azd provision` has been confirmed green on the real
> env (`rg-grf4`) with the current `main` (commits `b6c70eb` + `3a04abd`),
> because the whole point of the refactor is to preserve that exact behaviour
> while making the structure legible.

## 1. Goal

Today `infra/main.bicep` is **1248 lines / ~55 module+resource declarations /
33 params / 38 vars / 27 outputs** in one flat file. Leaf modules are grouped by
*category* folder (`network/`, `foundry/`, `gateway/`, `model-gateway/`,
`encryption/`, `rbac/`, `resources/`, `governance/`) but the orchestration is a
single wall of modules, so a newcomer cannot see the **layered thought process**
that underpins the platform.

**Target:** `main.bicep` becomes a **thin orchestrator (~150 lines)** — params +
five stage calls + outputs — that wires stage-orchestrator modules in sequence,
each consuming the previous stage's outputs. Leaf modules stay where they are;
only the *orchestration* moves.

```
infra/
  main.bicep                    # params (33) + 5 stage calls + outputs (27) — nothing else
  stages/
    00-foundation.bicep         # the "physics": no dependencies
    10-platform.bicep           # the managed services + their internal trust
    20-workload-mcp.bicep       # the thing being served + its exposure
    30-governance.bicep         # control plane over the workload; hardens LAST
    40-runner.bicep             # in-VNet worker VM = the bridge to imperative L4
  modules/…                     # leaf modules UNCHANGED (optionally regrouped later)
hooks/ + scripts/               # L4 — imperative, already outside Bicep
```

## 2. The two rules that de-mess it

These are the design decisions — everything else follows from them.

- **Rule 1 — Co-locate cross-cutting concerns.** RBAC role assignments, CMK
  encryption, private endpoints, and diagnostic settings live **with the resource
  they protect, inside that resource's stage**. There is **no standalone "RBAC
  layer" or "security layer"** — that is exactly what creates the ball-of-
  references mess (it has to reach back into every other stage). A reader sees a
  resource *and* its encryption/RBAC/PE together, so there is never a "where is
  the grant for this?" hunt.
- **Rule 2 — IaC and imperative are different universes.** Agent *creation* is
  **not** a Bicep stage. It is seeded post-provision by the in-VNet runner workflow
  (`deploy-vnet.yml` → `scripts/seed-agents.ps1`, and torn down by `predown`). The stages are IaC only;
  the layering should **celebrate** that boundary (stage 40 is the in-VNet bridge
  to it), not hide agents inside a Bicep "agents layer".

Corollaries:
- **Dependencies only ever point downward:** `00 ← 10 ← 20 ← 30 ← 40`. Sequential
  stage modules make that a compile-time guarantee.
- **Growth is localized:** new MCP server → stage 20 only; new policy → stage 30
  only; new agent → `seed-agents.ps1` only.
- **The two hard sequencing rules survive as intra-stage ordering:**
  capability-host-after-data-plane-RBAC (stage 10) and lockdown-LAST (stage 30).

## 3. Stage definitions & rationale

### Stage 00 — Foundation (the substrate; zero dependencies)
The "physics": reachability + where everything logs. Renamed from "network"
because it is network **+ observability**.
- Networking: hub vnet, foundry/app-service/model-gateway spoke vnets, all
  peerings, firewall, DNS resolver, flow-logs storage + agent flow logs.
- Observability sink: Log Analytics workspace + Application Insights.
- **Exposes:** vnet + subnet ids/names (all spokes + hub), firewall private IP,
  private-DNS zone ids, flow-logs storage id, Log Analytics id, App Insights
  id/connection string.

### Stage 10 — Platform (managed services + internal trust)
Stand up the managed services and make them mutually trusted, encrypted, and
private. Existence + internal trust only — no end-user-facing policy.
- Services: Foundry account + **project (creation only)**, Key Vault,
  storage/search/cosmos, ACR, App Service plan, APIM, provider Foundry.
- **Co-located (Rule 1):** CMK encryption for AI account + storage; data-plane
  RBAC that makes these services trust *each other* (Foundry→storage/cosmos/
  search, Key Vault crypto grants, APIM→provider); private endpoints + DNS for
  these services; diagnostics.
- Capability host — **after** the stage-10 data-plane RBAC (hard ordering).
- **Exposes:** aiAccount name/id, aiProject name/endpoint/principalId/workspaceId,
  Key Vault name/uri, storage/search/cosmos names+ids+principalIds, ACR name, App
  Service plan id, APIM name/id/principalId, provider Foundry name/endpoint.

### Stage 20 — Workload / MCP (the thing being served + its exposure)
The app and its routing. Adding a second MCP server touches **only this stage**.
- **MCP server web app(s)** — *pulled out of* `standard-dependent-resources`
  (§5, edit #1). Its managed identity + builtin auth (`gateway/builtin-auth`).
- APIM `type:mcp` APIs + backends, `mcp/mcp.json`-driven
  (`model-gateway/apim-mcp-servers`).
- **Exposes:** `servers` array `[{ name, connectionName, url }]`, MCP web app
  FQDN + identity (client/principal), builtin-auth facts.

### Stage 30 — Governance & exposure policies (control plane; hardens last)
"Who may do what, at what rate — now seal it."
- App registration / audience (`gateway/app-registration`).
- Foundry project → MCP **connections** — declared here against the **`existing`**
  project from stage 10 (§5, edit #2), so project *creation* stays in stage 10 and
  project *trust policy* lives here.
- MCP compliance rate-limit policies (`apim-mcp-compliance-all`), RAI guardrail +
  non-compliant-model demo (governance/*), Teams API (`if enableTeamsPublish`),
  model-API policy (`apim-api-policy`), agent model connection (`apim-connection`).
- **`apimLockdown` STRICTLY LAST** — hardening an L1 resource (APIM) from stage 30
  is deliberate ("harden last"), not a misplacement. Everything that writes APIM
  APIs/policy (stage 10 APIM create + stage 20 MCP routing + stage 30 policies)
  must complete first. Preserve its existing `dependsOn`.
- **Exposes:** audience, compliance server count, teams/RAI output names.

### Stage 40 — Runner (deploy enablement; the bridge to L4)
This VM exists **only** to let the imperative stage reach private Foundry.
- In-VNet Linux worker VM (`vm-linux`) — the seed-agents host; optional Windows VM
  / Bastion (`if deployWindowsVm` / `if deployBastion`).
- **Co-located (Rule 1):** runner RBAC (→Foundry/OpenAI/Key Vault secrets/VM
  contributor), runner PAT secret, and the **runner extension LAST** (bootstraps
  the GitHub runner). All `if (installGithubRunner)`.
- **Exposes:** vm name (→ `GITHUB_ACTIONS_RUNNER_VM_NAME`), runner facts.

### L4 — Imperative (NOT Bicep)
Agent seeding (in-VNet runner workflow → `seed-agents.ps1`) and capability-host teardown
(`predown`). Already outside Bicep — no change; stage 40 is its in-VNet bridge.

## 4. Current module → target stage map

Ordered as they appear in today's `main.bicep`.

| Line | Symbol | Module | Stage |
|-----:|--------|--------|:-----:|
| 189 | `lanalytics` | (inline) Log Analytics | **00** |
| 199 | `appInsights` | (inline) App Insights | **00** |
| 214 | `hubNetwork` | network/network-agent-vnet | **00** |
| 268 | `firewall` | network/firewall | **00** |
| 287 | `foundrySpokeVnet` | network/foundry-spoke-vnet | **00** |
| 304 | `appServiceSpokeVnet` | network/appservice-spoke-vnet | **00** |
| 316 | `flowLogsStorage` | (inline) storage | **00** |
| 336 | `agentFlowLogs` | network/agent-flow-logs | **00** |
| 352 | `hubToFoundryPeering` | network/vnet-peering | **00** |
| 363 | `hubToAppServicePeering` | network/vnet-peering | **00** |
| 851 | `modelGatewaySpokeVnet` | model-gateway/model-gateway-spoke-vnet | **00** (moves up; §6.f) |
| 863 | `hubToModelGatewayPeering` | network/vnet-peering | **00** |
| 385 | `aiAccount` | foundry/ai-account-identity | **10** |
| 408 | `keyVault` | resources/keyvault | **10** |
| 418 | `aiDependencies` | resources/standard-dependent-resources | **10** (MCP web app carved to 20; §5 #1) |
| 440 | `storage`/`aiSearch`/`cosmosDB` | `existing` refs | **10** |
| 452 | `acr` | resources/acr | **10** |
| 464 | `keyVaultRoleAssignments` | rbac/keyvault-role-assignments | **10** (co-located) |
| 476 | `aiAccountEncryption` | encryption/ai-account-encryption | **10** (co-located) |
| 497 | `storageEncryption` | encryption/storage-encryption | **10** (co-located) |
| 513 | `privateEndpointAndDNS` | network/private-endpoint-and-dns | **10** (co-located; takes 00 subnets) |
| 586 | `aiProject` (creation) | foundry/ai-project-identity | **10** (connections → 30; §5 #2) |
| 626 | `formatProjectWorkspaceId` | foundry/format-project-workspace-id | **10** |
| 636 | `storageAccountRoleAssignment` | rbac/azure-storage-account… | **10** (co-located) |
| 652 | `appInsightsRoleAssignment` | rbac/app-insights-role… | **10** (co-located) |
| 664 | `acrRoleAssignment` | rbac/acr-role-assignment | **10** (co-located) |
| 675 | `foundryProjectRoleAssignment` | rbac/foundry-project-role… | **10** (co-located) |
| 685 | `cosmosAccountRoleAssignments` | rbac/cosmosdb-account-role… | **10** (co-located) |
| 698 | `aiSearchRoleAssignments` | rbac/ai-search-role… | **10** (co-located) |
| 754 | `storageContainersRoleAssignment` | rbac/blob-storage-container… | **10** (co-located) |
| 767 | `cosmosContainerRoleAssignments` | rbac/cosmos-container-role… | **10** (co-located) |
| 711 | `addProjectCapabilityHost` | foundry/add-project-capability-host | **10 (after 10 RBAC)** |
| 874 | `providerFoundry` | model-gateway/provider-foundry | **10** |
| 889 | `apim` | model-gateway/apim | **10** |
| 904 | `apimPrivateEndpoint` | model-gateway/apim-private-endpoint | **10** (co-located) |
| 917 | `modelGatewayPrivateEndpoints` | model-gateway/model-gateway-private-endpoints | **10** (co-located) |
| 931 | `apimProviderRoleAssignment` | model-gateway/apim-provider-role… | **10** (co-located) |
| (in `aiDependencies`) | MCP web app (`gateway/app-service`) | **20** (carved out; §5 #1) |
| 571 | `mcpBuiltinAuth` | gateway/builtin-auth | **20** |
| 947 | `apimMcpServers` | model-gateway/apim-mcp-servers | **20** |
| 557 | `mcpAppRegistration` | gateway/app-registration | **30** |
| (new) | project MCP connections | foundry/ai-project-identity connections → own module | **30** (against `existing` project; §5 #2) |
| 976 | `apimMcpComplianceAll` | model-gateway/apim-mcp-compliance-all | **30** |
| 987 | `apimApiPolicy` | model-gateway/apim-api-policy | **30** |
| 1002 | `apimConnection` | model-gateway/apim-connection | **30** |
| 1019 | `apimTeamsApi` | model-gateway/apim-teams-api (`if enableTeamsPublish`) | **30** |
| 736 | `raiGuardrail` | governance/rai-guardrail-assignment (`if …`) | **30** |
| 742 | `nonCompliantModelDemo` | governance/noncompliant-model-demo (`if …`) | **30** |
| 1033 | `apimLockdown` | model-gateway/apim-lockdown | **30 (LAST)** |
| 1056 | `gatewayFirewallRules` | model-gateway/gateway-firewall-rules | **30** (end; reflects final topology) |
| 793 | `linuxVmModule` | resources/vm-linux | **40** |
| 808 | `vmModule` | resources/vm (`if deployWindowsVm`) | **40** |
| 823 | `bastionModule` | resources/bastion (`if deployBastion`) | **40** |
| 1080 | `vmFoundryRole` | rbac/vm-foundry-role | **40** (co-located) |
| 1101 | `vmKeyVaultSecretsRole` | rbac/vm-keyvault-secrets-role (`if …`) | **40** (co-located) |
| 1113 | `vmContributorRole` | rbac/vm-contributor-role (`if …`) | **40** (co-located) |
| 1125 | `vmOpenAiUserRole` | rbac/vm-openai-user-role (`if …`) | **40** (co-located) |
| 1136 | `runnerPatSecret` | resources/runner-pat-secret (`if …`) | **40** |
| 1145 | `vmRunnerExtension` | resources/vm-runner-extension (`if …`) | **40 (LAST)** |

## 5. The two edits that make it real (the actual engineering work)

Everything else is mechanical cut-move-thread-outputs; these two are surgery on
leaf modules.

1. **Split the MCP web app out of `standard-dependent-resources.bicep`.** Today
   that module creates storage+search+cosmos (stage 10) **and**, via
   `../gateway/app-service.bicep`, the YARP + **MCP web apps (stage 20)**. Carve
   the MCP web-app creation into a stage-20 module; have stage 10 keep
   storage/search/cosmos (+ YARP if it stays a platform concern). Rewire the
   `mcpWebAppFqdn`/identity outputs to come from the stage-20 module.
   *Medium effort — edits a load-bearing leaf module and its RBAC.* This is the
   edit that removes the biggest entanglement; do it deliberately, not "later".
2. **Split Foundry project *connections* from project *creation*.** Stage 10
   creates the project (`ai-project-identity`). Move the per-server MCP
   `connections` loop (from commit `b6c70eb`) into a **stage-30 module** that
   declares the connection child resources against the **`existing`** project
   (`resource proj 'Microsoft.CognitiveServices/accounts/projects@…' existing` +
   child `connections`, or `parent:`). Stage 30 builds `mcpConnections` from stage
   20's `servers` output + the app-reg audience and passes it in.
   *Low effort — kills the L1/L3 straddle cleanly.*

## 6. Constraints & known seams (do not break these)

- **(a) `main.bicep` stays the azd entry point.** All **33 params** stay declared
  on `main.bicep` (azd binds them from `infra/main.parameters.json`); stage modules
  receive them as params. Do **not** re-declare env-bound params in stage modules.
- **(b) All 27 outputs stay on `main.bicep`** verbatim (names/types identical —
  they are surfaced to azd → hooks as env vars). Re-home only the *expressions* to
  read from stage outputs. Hook-consumed: `AZURE_RESOURCE_GROUP`,
  `GITHUB_ACTIONS_RUNNER_VM_NAME`, `AZURE_AI_PROJECT_ENDPOINT`, `AZURE_AI_MODEL_DEPLOYMENT_NAME`,
  `SEED_ENABLE_SECOND_AGENT`, `SEED_SECOND_AGENT_MODEL`, `AZURE_AI_ACCOUNT_NAME`,
  `AZURE_AI_PROJECT_NAME`, `MCP_COMPLIANCE_*`, `TEAMS_*`, `MCP_GATEWAY_URL`,
  `RAI_GUARDRAIL_ASSIGNMENT_NAME`, `NONCOMPLIANT_DEMO_DEPLOYMENT_NAME`,
  `GITHUB_RUNNER_*`, `KEY_VAULT_NAME`.
- **(c) `existing` refs** (storage/aiSearch/cosmosDB @440, and any inside leaf
  modules) resolve by name within the deployment RG. When they move into a stage
  module keep the name passed in and the RG scope identical (all stages are
  `scope: resourceGroup()` sub-deployments).
- **(d) Conditional modules keep their conditions** (`enableTeamsPublish`,
  `deployWindowsVm`, `deployBastion`, `installGithubRunner`,
  `enableRaiGuardrailPolicy`, `enableNonCompliantModelDemo`). A stage wrapping a
  conditional must surface a **safe output** for the disabled case (mirror today's
  `raiGuardrail!.outputs…` / `?? ''`).
- **(e) Capability host after stage-10 data-plane RBAC** — keep this ordering
  inside stage 10; do not let it drift.
- **(f) `modelGatewaySpokeVnet` is declared late (line 851) but is pure stage 00.**
  Moving it up is correct and safe; its consumers (APIM PE, model-gateway PEs) are
  stage 10 and just take its subnet outputs.
- **(g) `apimLockdown` LAST** (stage 30) — after every APIM API/policy write.
- **(h) `gatewayFirewallRules`** reads stage 00 (firewall) + stage 10 (APIM/app-
  service) facts; place at end of stage 30 to reflect final topology. Confirm it is
  not required before lockdown.
- **(i) No `.bicepparam`** (azd reads `main.parameters.json`). **`.gitignore`
  ignores `*.json`**; don't emit tracked `.json` artifacts — new `stages/*.bicep`
  are fine.
- **(j) Build check = `az` exit code**, not grep. ~5 pre-existing warnings
  (BCP318/036/037) expected; **0 errors** is the bar.

## 7. Migration strategy — incremental, build-green at every step

Bottom-up, **one stage per commit**, keeping `az bicep build` green and the
compiled ARM behaviourally identical throughout.

0. **Baseline (before touching anything):**
   `az bicep build --file infra/main.bicep --stdout > /tmp/main.baseline.json`.
   This is the golden reference for every later parity diff.
1. **Stage 00.** Create `infra/stages/`. Move the stage-00 modules + their vars
   into `00-foundation.bicep`; add outputs for everything stage 10+ referenced;
   replace them in `main.bicep` with one `module stage00 …` call; rewire downstream
   refs to `stage00.outputs.*`. `az bicep build` → 0 errors.
2. **Stage 10** (params in = stage00 outputs). Apply Rule 1 co-location. Watch §6.e.
3. **Perform edit #1 (§5)** — carve the MCP web app out — as its own commit *before*
   stage 20, so stage 20 has a clean module to import.
4. **Stage 20** (params in = stage10 outputs).
5. **Perform edit #2 (§5)** — split project connections into a stage-30 module.
6. **Stage 30** (params in = stage10 + stage20 outputs; lockdown LAST).
7. **Stage 40** (params in = stage10 outputs; runner extension LAST).
8. **Shrink `main.bicep`** to params + `stage00…stage40` calls + the 27 outputs.
9. **Behaviour-parity diff (critical):** the ARM shape changes (flat → nested
   deployments), so assert the invariants that must NOT change:
   - **identical output names + types**,
   - **same set of leaf resource `type`+`name` pairs**,
   - **same conditions**.
   ```
   az bicep build --file infra/main.bicep --stdout > /tmp/main.reorg.json
   python3 -c "import json; a=json.load(open('/tmp/main.baseline.json')); b=json.load(open('/tmp/main.reorg.json')); \
   print('outputs identical:', sorted(a.get('outputs',{}).items())==sorted(b.get('outputs',{}).items()))"
   ```
   (Flatten nested `Microsoft.Resources/deployments` to compare the leaf
   type+name set; eyeball the condition list.)
10. **`azd provision` on the real/scratch env** as final proof — a green build does
    not prove deploy-time ordering. Because deployment is idempotent, provisioning
    over the existing env should **converge with no resource churn**.

**Per-commit discipline:** message `refactor(infra): extract stage NN into
stages/NN-*.bicep (no behaviour change)`, each with the parity note in the body —
reviewable and bisectable.

## 8. Effort & risk

- **Effort:** Medium-Large but mostly mechanical (~half-to-full focused day),
  **plus** two real leaf-module surgeries (§5). No new Azure resources, no new
  behaviour.
- **Risk:** **Medium.** Wide blast radius, so the danger is a **mis-threaded
  param/output silently changing a value** (e.g. wrong subnet id) or a **lost
  `dependsOn`** re-ordering a data-plane op (capability host, lockdown, runner
  extension). All caught by §7.9 parity + §7.10 provision-with-no-churn.

## 9. Out of scope / NOT changing

- Leaf module *contents* except the two surgeries in §5.
- Any Azure resource, name, SKU, policy, or RBAC assignment (behaviour is frozen).
- Hooks (`hooks/*.ps1`), `scripts/*`, `azure.yaml`, `mcp/*.json`.
- Agent seeding stays imperative (L4) — stage 40 is only its in-VNet bridge.

## 10. Definition of done

- `infra/main.bicep` ≈ params + 5 stage calls + 27 outputs; each stage module
  builds standalone and via main with **0 errors**.
- §7.9 parity: identical output names+types, identical leaf resource type+name
  set, identical conditions vs the pre-refactor baseline.
- The two §5 surgeries done: MCP web app in stage 20, project connections in
  stage 30 (project creation still in stage 10).
- `azd provision` converges with **no resource churn** on an already-provisioned
  env.
- One commit per stage (plus one per §5 surgery), each with a parity note.
