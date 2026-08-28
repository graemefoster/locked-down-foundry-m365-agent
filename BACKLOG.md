# Project backlog

This backlog tracks optional improvements to the single, network-isolated Azure AI Foundry
environment. The supported architecture and lifecycle are documented in
[README.md](./README.md) and [`docs/`](./docs/).

The repository intentionally has one environment. Do not add dev/test projects, promotion
lanes, environment-suffixed resources, or GitHub Environments.

## Evaluation

- [ ] Add configurable pass/fail thresholds to agent evaluations.
- [ ] Persist evaluation results for trend reporting.
- [ ] Expand evaluation data with safety, groundedness, and MCP tool-calling cases.
- [ ] Add a supported comparison approach for private BYO-network projects, where Foundry
  cluster analysis is unavailable.
- [ ] Evaluate Foundry continuous or online evaluation support for the private network design.

## Agent templates and validation

- [ ] Add a small prompt-agent template.
- [ ] Add source-zip and container-image agent templates.
- [ ] Validate `agent.yaml`, `network.json`, `teams.json`, `mcp.json`, and `mcp-policy.json`
  against committed schemas in CI.
- [ ] Add a rollback workflow that republishes a selected existing agent version.

## Governance and operations

- [ ] Export per-agent token metrics to an operational dashboard.
- [ ] Add alerts for quota pressure, policy failures, and evaluation regressions.
- [ ] Add automated tests for the APIM policy XML generated from the JSON configuration.
- [ ] Add a clean-environment deployment smoke test that covers `azd up`, all three agent
  deployment modes, governance, Teams publishing, evaluation, and `azd down`.

## Sample application

- [ ] Add an authenticated web client for the governed Foundry Agents API.
- [ ] Support streaming responses and MCP tool-call display.
- [ ] Deploy the client through the existing private App Service and gateway pattern.

## Contributor experience

- [ ] Add `CONTRIBUTING.md`.
- [ ] Add issue templates for backlog items.
- [ ] Add CI checks for Bicep, PowerShell parsing, JSON validation, workflow linting, and the
  agent automation smoke tests.
