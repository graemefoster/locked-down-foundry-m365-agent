# Project backlog

A living backlog of ideas for evolving this repository into a complete **reference
implementation for a locked-down Azure AI Foundry agent environment**.

It turns the aim and goals below into concrete, actionable epics. Each epic lists a
short rationale, what already exists in the repo today (so we don't re-litigate solved
problems), and the proposed backlog items. Items are labelled with a rough size
(**S / M / L**) and marked `[x]` when the repo already ships that capability.

> How to use this: pick an epic, open a GitHub issue per unchecked item (use the
> **Epic** / **Backlog item** issue templates in [`.github/ISSUE_TEMPLATE`](./.github/ISSUE_TEMPLATE)),
> and link it back here. Keep this file as the single source of truth for direction.

## Aim

A reference implementation for a **locked-down Foundry agent environment** — showing how
teams can build, deploy, evaluate, govern, and promote Azure AI Foundry agents safely
inside a private, network-isolated Azure landing zone.

## Goals (from the originating issue)

1. Automate deployment of **various kinds of Foundry agents** (prompt **and** hosted) using CI/CD and automation.
2. Bring **evaluations into the pipeline** to get confidence before promoting a change.
3. Next: add **continuous evaluations in Foundry** when deploying agents.
4. Add a **second Foundry project** to show pipeline promotion (deploy to one environment, then promote the same agent to another).
5. Blue-sky: **automate governance** such as RPM (requests-per-minute) and token-usage controls on agents.
6. Add a **sample .NET MVC website with a React front end** to expose the agents.

---

## Where the repo is today (baseline)

Understanding the current state keeps the backlog honest. Already shipped:

- **Locked-down infrastructure** via `azd` + Bicep: private VNet, private endpoints on every
  dependency, deny-by-default Azure Firewall, CMK encryption, RBAC, in-VNet VM. See
  [docs/architecture.md](./docs/architecture.md) and [NETWORKING.md](./NETWORKING.md).
- **Prompt-agent CI/CD**: [`.github/workflows/deploy-teams-agent.yml`](./.github/workflows/deploy-teams-agent.yml)
  (a thin caller of the reusable [`deploy-agent.yml`](./.github/workflows/deploy-agent.yml))
  parses `agents/teams-agent/agent.yaml`, then creates/updates + publishes the agent version
  against the **private** Foundry endpoint from an in-VNet self-hosted runner.
- **Offline evals in CI**: the reusable `microsoft/ai-agent-evals` action can run against an
  agent's `eval-data.json` (e.g. `agents/teams-agent/eval-data.json`) on a schedule.
- **Teams / M365 publish path** and an **always-on private APIM AI gateway** (models + MCP +
  M365 auth) ([docs/teams-m365.md](./docs/teams-m365.md), [docs/ai-gateway.md](./docs/ai-gateway.md)).
- **In-VNet self-hosted GitHub Actions runner** so pipelines can reach the private endpoint
  ([docs/github-runner.md](./docs/github-runner.md)).

So the backlog below is mostly about **breadth (hosted agents, multi-env, governance, a UI)**
and **depth (gating on evals, continuous evals, promotion flows)** on top of a solid base.

---

## Epic 1 — Automate deployment of prompt *and* hosted agents

**Rationale:** prompt-agent CI/CD exists; hosted (containerized/code) agents are the missing
half of goal 1. A hosted agent has source, a Dockerfile, listens on port 8088, serves
`GET /readiness`, and ships as an image to ACR + a Capability Host — a different pipeline
shape from the prompt REST flow.

- [x] Prompt-agent create/update/publish pipeline against the private endpoint.
- [ ] **(L)** Add a sample **hosted agent** under `src/<agent>` (Dockerfile, `/readiness`, responses/invocations/a2a) and document the contract.
- [ ] **(L)** Build a **hosted-agent CI/CD workflow**: build image → push to the private ACR → deploy to the Capability Host from the in-VNet runner.
- [ ] **(M)** Generalize the deploy workflow to be **agent-agnostic** (matrix over `agents/*`) so adding an agent folder is all that's needed — no per-agent workflow copy.
- [ ] **(S)** Add an `agents/README.md` describing the folder convention (`agent.yaml`, `eval-data.json`) and how prompt vs. hosted agents differ.
- [ ] **(M)** Provide a **scaffolding script / template** (`agents/_template/`) to stamp out a new prompt or hosted agent.
- [ ] **(S)** Validate `agent.yaml` in CI (schema/lint) on every PR so malformed manifests fail fast on a hosted runner.

## Epic 2 — Evaluations as a pipeline quality gate

**Rationale:** goal 2. Nightly offline evals exist but do not yet **gate** a deploy. Confidence
comes from failing the pipeline when scores regress.

- [x] Nightly offline evaluation posting a scored report to the run summary.
- [ ] **(M)** Run evals as a **pre-publish gate** in the deploy workflow: score the new agent version, block the publish step if thresholds aren't met.
- [ ] **(M)** Define **pass/fail thresholds** per evaluator (config file next to the agent) and surface them in the job summary.
- [ ] **(M)** Persist eval results as workflow **artifacts / trend data** so score history is visible across runs.
- [ ] **(S)** Expand `eval-data.json` coverage: add adversarial / safety / groundedness cases and an MCP-tool-calling case.
- [ ] **(M)** Track and document the **Private BYO cluster-analysis limitation** (version-over-version comparison) — provide a supported comparison approach or a wrapper that scores versions independently and diffs the results.

## Epic 3 — Continuous evaluations in Foundry

**Rationale:** goal 3 — move from CI-only offline evals to **Foundry-native continuous
evaluation / online monitoring** so production traffic is scored, not just the test set.

- [ ] **(L)** Enable **continuous / online evaluation** on the Foundry project and wire it up at deploy time.
- [ ] **(M)** Emit eval + agent telemetry to **Application Insights / Log Analytics** and build a monitoring dashboard (quality, safety, latency).
- [ ] **(M)** Add **alerts** on eval-score regressions or safety-evaluator failures in production.
- [ ] **(S)** Document the private-network considerations for continuous eval (endpoints, egress rules, identities) in a `docs/evaluation.md`.

## Epic 4 — Second Foundry project + environment promotion

**Rationale:** goal 4 — demonstrate a real **promotion pipeline**: deploy an agent to a lower
environment, evaluate it, then promote the *same* agent definition to a higher environment.

- [ ] **(L)** Parameterize infra to deploy a **second Foundry project** (e.g. `dev` → `prod`, or two projects in one landing zone).
- [ ] **(L)** Add a **promotion workflow**: after evals pass in env A, deploy the identical agent version to env B (`workflow_dispatch` with a manual approval gate).
- [ ] **(M)** Introduce an **environment/config strategy** (per-env parameters, repo/GitHub Environments, required reviewers) documented in `docs/environments.md`.
- [ ] **(M)** Ensure agent definitions are **environment-agnostic** (endpoints/connections injected at deploy time, not baked into `agent.yaml`).
- [ ] **(S)** Show a **rollback** path (re-publish the previous agent version) as a first-class workflow input.

## Epic 5 — Governance: RPM, token usage & cost controls (blue-sky)

**Rationale:** goal 5. The private APIM AI gateway is the natural enforcement point for
rate limiting, quotas, and usage attribution.

- [x] Private APIM AI gateway fronting the models (enforcement point exists).
- [ ] **(M)** Add APIM **rate-limit / quota policies** (RPM and token-based) per agent or per consumer, driven from Bicep parameters.
- [ ] **(M)** Capture **token-usage metrics** per agent and export to Log Analytics for cost attribution / chargeback.
- [ ] **(M)** Build a **usage & cost dashboard** (tokens, RPM, top consumers) and budget **alerts**.
- [ ] **(S)** Document a **governance model**: how limits map to agents/consumers and how to change them via `azd env set`.
- [ ] **(L)** Optional: **content-safety / PII guardrail** policy in the gateway path.

## Epic 6 — Sample .NET MVC + React front end to expose the agents

**Rationale:** goal 6 — a runnable UI that talks to the (private) agents, deployable into the
existing VNet-integrated App Service pattern used by the Teams/YARP path.

- [ ] **(L)** Scaffold an **ASP.NET Core MVC** app with a **React** front end (`src/web/`) that calls the agent(s).
- [ ] **(L)** Deploy it as a **VNet-integrated App Service** reaching the private endpoint (reuse the existing app-service / spoke-vnet modules), fronted by APIM.
- [ ] **(M)** Add **Entra ID (Easy Auth)** in front of the web app (reuse `builtin-auth.bicep` / `app-registration.bicep`).
- [ ] **(M)** Implement **streaming chat UI** (SSE/websocket) against the agent's responses API, including MCP tool-call display.
- [ ] **(S)** Add a **CI build** (dotnet build/test + React build) on GitHub-hosted runners and a deploy workflow.
- [ ] **(S)** Document setup + local dev in `docs/sample-app.md`.

## Epic 7 — Cross-cutting: developer experience, tests & docs

**Rationale:** supports every goal; keeps the reference implementation approachable and trustworthy.

- [ ] **(S)** Add **GitHub issue templates** (epic / backlog item) and a `CONTRIBUTING.md` that points here.
- [ ] **(M)** Add **PowerShell script tests** (Pester) for `scripts/*.ps1` (agent create/publish, Teams publish) runnable on hosted runners.
- [ ] **(S)** Keep the **Bicep build green** in CI (already enforced) and add `bicep lint`/`az bicep build` for every module.
- [ ] **(S)** Add an **end-to-end runbook** ("from empty subscription to a deployed, evaluated, Teams-published agent") to the docs index.
- [ ] **(S)** Add a **glossary / architecture diagram** covering prompt vs. hosted agents, the eval loop, and the promotion flow.

---

## Suggested sequencing

A pragmatic order that builds confidence before breadth:

1. **Epic 2** (eval gate) — makes every later change safer.
2. **Epic 1** (hosted agents) — completes goal 1's "various kinds of agents".
3. **Epic 4** (second project + promotion) — real multi-env story.
4. **Epic 3** (continuous evals) — production confidence.
5. **Epic 5** (governance) — enforce RPM/token limits at the gateway.
6. **Epic 6** (sample app) — a tangible UI to demo the whole thing.
7. **Epic 7** runs continuously alongside the others.
