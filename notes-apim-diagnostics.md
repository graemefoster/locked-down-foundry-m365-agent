# APIM diagnostics — temporary bring-up instrumentation (NOT in repo)

> Scratch notes for the live 502 investigation. These changes were applied **directly to Azure**
> (out-of-band, via `az rest`), are **not** in Bicep, and must be **reverted before lockdown**.
> A fresh `azd provision` (e.g. gf-a6) does **not** include any of this.

## Where
- Environment: **gf-a5**
- APIM: `apim-pdgp-modelgw` (rg `rg-gf-a5`, sub `8d9b7ef3-0e45-41d7-8bcb-a1d75af99255`)
- App Insights sink: `pdgp-appi` (logger `appinsights-logger`)

Same instrumentation was previously applied to **gf-a4** (`apim-irz4-modelgw` → `irz4-appi`).

## Why
Teams/autopilot calls return **HTTP 502**. Needed to see the real request/response crossing APIM
to Foundry. The default locked-down APIM logs no bodies, so 502 was opaque.

## What was changed (two edits)

### 1. Service `applicationinsights` diagnostic — body + header logging
`PATCH …/service/apim-pdgp-modelgw/diagnostics/applicationinsights?api-version=2022-08-01`
- frontend + backend, **request & response bodies** (`bytes: 8192`)
- request headers logged: `Content-Type`, `Authorization`, `User-Agent`
- preserved existing query-param `dataMasking` (Hide `*`)
- verbosity `information`, sampling 100%, `alwaysLog: allErrors`

### 2. `teams` API policy — three `teams-diag` `<trace>` blocks
`PUT …/service/apim-pdgp-modelgw/apis/teams/policies/policy?api-version=2022-08-01` (format `rawxml`)
- **inbound**: method, URL, `Authorization`, request body
- **outbound**: response status + body
- **on-error**: status, `context.LastError`, body
- Expressions wrap `context.Request.Body?.As<string>(preserveContent:true)` in **`<![CDATA[ … ]]>`**
  so the generic `<…>` doesn't need XML escaping. (First attempt without CDATA double-escaped to
  `&amp;lt;` — use CDATA.)
- The `validate-jwt` Bot Framework check + single-tenant `serviceurl` assertion were **already
  commented out** (bring-up mode) before these traces were added.

## What we learned (root cause)
The `teams-diag` **OUTBOUND** trace shows:
```
OUTBOUND status=502 | body={ "error": { "code": "upstream_dependency_failed", ... request_id ... } }
```
So the 502 is **Foundry's own downstream failing** while invoking the hosted agent — NOT YARP,
APIM, token, or network. Reproduced on a brand-new subscription + fresh Foundry (gf-a5), so it is a
**systemic Foundry / hosted-agent-runtime** issue, not a corrupted environment.

Ruled out (with evidence): network (firewall UDR routes spoke-to-spoke, DNS resolver serves private
zones), token (valid Entra JWT, `aud` = agent blueprint appId, Foundry returns app-error not 401),
APIM (it forwards; the 502 body is Foundry's).

## Gotchas
- **APIM masks the bearer token** to `******` in both header logging and custom traces — you can see
  auth is present, not its value. Raw-token replay is blocked (and unnecessary).
- **App Insights ingestion lags ~1–3 min.** Do not conclude "no traffic reached APIM" from an
  immediately-empty query/metric — wait and re-query. (Bit me twice.)
- Query traces: `traces | where customDimensions.["Message"] contains "teams-diag"` — or read the
  request/response bodies in `requests`/`dependencies` `customDimensions`.

## Revert (before returning to locked-down posture)
1. **Strip body/header logging** — PATCH the service `applicationinsights` diagnostic setting
   `frontend.request.body`, `frontend.response`, `backend.request.body`, `backend.response`, and the
   `headers` arrays back to `null`.
2. **Remove the `teams-diag` traces** — PUT the `teams` API policy without the three `<trace>` blocks
   (returns it to the current bring-up policy: `set-backend-service` + `rewrite-uri` only).
3. **Re-enable `validate-jwt`** — uncomment the Bot Framework `validate-jwt` + `serviceurl` block in
   the `teams` policy (this is separate from the traces; required for full lockdown). While it stays
   commented, `deploy-agent-network.yml`'s "apply Teams audiences" step is inert.

## Open thread (if resumed)
To name Foundry's failing dependency: enable diagnostic settings on the Foundry account
(`aiservicespdgp`, currently none → send to `pdgp` Log Analytics) and/or pull the **hosted agent
container/remote-build logs** via `runner-vm-pdgp`; or attach a captured `request_id` to a support
case. Example request_id: `3e7004762d3db5622cda0529833af652`.
