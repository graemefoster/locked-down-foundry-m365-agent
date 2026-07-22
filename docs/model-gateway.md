# Optional: Model Gateway (APIM + provider Foundry)

> Part of the [network-secured Foundry agent](../README.md) accelerator. Full request-flow / policy walkthrough: [apim-model-gateway.md](../apim-model-gateway.md). Networking: [NETWORKING.md](../NETWORKING.md#optional-model-gateway-spoke-apim--provider-foundry).

> **APIM is now always deployed.** The APIM Standard v2 instance, its gateway
> spoke (`10.3.0.0/16`), inbound private endpoint and `privatelink.azure-api.net`
> DNS zone are **shared infrastructure** — provisioned unconditionally because both
> the model gateway *and* the Teams / M365 publish path route through them.
> `enableModelGateway` now only gates the **provider Foundry** account, the APIM
> inference API/connection, and the second seeded agent.

`enableModelGateway` is **on by default** (`azd` sets `ENABLE_MODEL_GATEWAY=true` in
`infra/main.parameters.json`); set it to `false` to skip it. It deploys an
enterprise-grade model gateway in the shared gateway spoke (`10.3.0.0/16`):

- **APIM Standard v2** with an inbound **private endpoint** and outbound **VNet
  integration** — no public gateway access.
- A minimal **provider AI Foundry** account (public access disabled, private
  endpoint only) exposing a `gpt-5.4-mini` deployment behind APIM.
- An `ApiManagement` connection advertising APIM to the primary Foundry project,
  and a **second seeded agent** using the model `model-gateway/gpt-5.4-mini`.

Models are discovered **dynamically**: instead of a static list, APIM exposes
`GET /deployments` and `GET /deployments/{name}`, which proxy the provider account's
**Azure Resource Manager** deployments API and return the AzureOpenAI-format list the
Foundry connection parses at runtime.

Auth is defense-in-depth: callers must present **both** a valid Entra JWT
(`validate-azure-ad-token`) **and** an APIM subscription **`api-key`** (sent by the
connection). APIM authenticates to the provider Foundry with its own managed
identity — granted **Cognitive Services User** (data-plane inference) and **Reader**
(ARM deployments read for discovery) on the provider account. APIM logs to both Log
Analytics and the shared **Application Insights** component. See [NETWORKING.md](../NETWORKING.md#optional-model-gateway-spoke-apim--provider-foundry).

Key parameters (see [`infra/main.parameters.json`](../infra/main.parameters.json)):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `enableModelGateway` | `false` | Master switch for the whole gateway spoke. |
| `gatewayModelName` | `gpt-5.4-mini` | Model deployed on the provider and exposed via APIM. |
| `gatewayCallerAppId` | `''` | Optional caller app/client ID pinned in the JWT policy. |
| `gatewayApiKey` | `''` (secure) | Optional explicit `api-key`; empty = deterministic derived key. |

> **Note:** APIM Standard v2 provisioning is slow (~15–45 min), so enabling this
> materially increases deployment time.

