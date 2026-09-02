# Troubleshooting

## CMK or Key Vault RBAC propagation

### Symptoms

- `KeyVaultAuthenticationFailure`
- `AccessPolicyNotConfiguredForKeyVault`
- a CMK update fails shortly after the role assignment is created

### Resolution

Key Vault data-plane role assignments can take several minutes to propagate. Wait, then rerun:

```bash
azd provision
```

The deployment is idempotent. Do not work around the delay by enabling public access, adding
stored keys, or weakening the CMK/RBAC design.

The same delay can affect the runner's first Key Vault read of its registration PAT. If the
runner bootstrap failed before registering, rerun `azd provision`.

## Private endpoint or APIM recovery

### Symptoms

- private DNS resolves incorrectly;
- the runner cannot reach Foundry or APIM;
- APIM remains publicly enabled after an interrupted deployment;
- Teams requests fail before reaching Foundry.

### Checks

1. Run the test from the in-VNet runner or optional Windows dev VM, not from a public host.
2. Confirm the service hostname resolves to its private endpoint address.
3. Confirm the relevant subnet route sends cross-spoke traffic through Azure Firewall.
4. Check firewall and APIM gateway logs for deny, `401`, `403`, and backend errors.
5. Confirm APIM has its inbound private endpoint before public access is disabled.

APIM Standard v2 is created with public access enabled, receives its private endpoint, and is
then relocked by a later deployment step. If that sequence was interrupted, rerun:

```bash
azd provision
```

Do not leave APIM public as a permanent recovery measure.

For Teams `401` responses, verify APIM can reach `login.botframework.com` through the firewall
to retrieve Bot Framework OpenID metadata and signing keys. Also verify that the governance
workflow has applied the current bot audiences.

## SCM access was not relocked

The `azd deploy` pre-hook temporarily permits the operator's public IP on the MCP and YARP SCM
sites. The post-hook removes that access and restores the private MCP setting.

If deployment is interrupted after the pre-hook, run:

```bash
azd hooks run postdeploy
```

Then confirm the temporary SCM allow rule is gone. Treat an open SCM endpoint as a deployment
failure, not as a supported steady state.

## Self-hosted runner

### Runner is absent or offline

- Confirm both runner inputs were supplied during provisioning.
- Confirm the fine-grained PAT has repository Administration read/write permission.
- Confirm the VM managed identity can read the PAT secret from Key Vault.
- Allow for initial RBAC propagation, then rerun `azd provision`.
- In repository settings, verify an idle runner with labels
  `self-hosted`, `vnet`, and `foundry-private`.

### Workflow is queued

The requested labels must match the private runner. Confirm the runner service is active and the
workflow is allowed to use the `vnet-deploy` environment.

### Security check

Do not add pull-request triggers to a workflow that targets the private runner. The VM has
private network reach and privileged managed identity, so only trusted repository code may run
there.

## Source-zip deployment permissions

The source-zip reusable workflow packages publish output at the ZIP root with the Linux `zip`
tool and preserves symbolic links. Do not replace it with PowerShell `Compress-Archive` for
Linux-hosted agents: it can drop Unix execute bits and cause bundled native tools to fail with
`Permission denied`.

If a deployed source-zip agent fails to start:

1. confirm the configured entry point exists at the archive root;
2. confirm native executables are marked executable before packaging;
3. confirm required symbolic links are present;
4. rebuild through `_deploy-code-agent.yml` rather than uploading a locally created archive.

## Container image OCI media types

Foundry's server-side image handling expects OCI media types. A normal Docker push can emit
Docker schema media types and be rejected even when the image runs locally.

Use the supported image workflow. `scripts/deploy-image-agent.ps1` invokes Buildx with:

```text
--provenance=false
--output type=image,...,oci-mediatypes=true
```

If deployment fails, verify Buildx is available on the runner, inspect the pushed manifest
media types, and rerun the image workflow. Do not bypass the script with a plain `docker push`.

## Teams delegated authentication

### Symptoms

- the Microsoft 365 publish call returns `502`;
- managed-identity authentication succeeds for Foundry operations but publish fails;
- device-code sign-in is blocked or uses the wrong tenant.

The Microsoft 365 publish API requires a delegated user token for its on-behalf-of exchange.
An application-only or managed-identity token is not sufficient.

Run the dedicated Teams publishing workflow, complete its device-code sign-in with a user in
`TEAMS_TENANT_ID`, and ensure that user can publish to the selected `publishScope`. The workflow
restores the VM managed identity after obtaining the delegated token; only the publish call
uses the user token.

If the same `appVersion` is already published, increment `teams.json` and rerun.

## Teams route or audience mismatch

Publishing requires all of the following:

- `agent.yaml`;
- `network.json` with `exposeToM365: true`;
- `teams.json`;
- a successful run of the affected agent's lifecycle workflow.

The generated public route is `/teams/<agentName>`. A missing route returns `404` at YARP.
An outdated audience list fails at APIM. Rerun the affected agent's lifecycle workflow after
agent identity or exposure changes.

## Foundry API route or token-limit denial

The generated route is `/agents/<agentName>/{**remainder}` and exists only when
`exposeFoundryApi` is true. Callers absent from `network.json` are denied by design.

Rerun any per-agent lifecycle workflow after changing exposure or principals. The governance
stage regenerates routes, removes stale routes, and reapplies the token policy.

## MCP `403`, `429`, or missing URL

- `403 agent_not_permitted`: the agent is absent from the server entry, its live identity could
  not be resolved, or governance has not been reapplied.
- `429`: the configured `requestsPerMinute` limit was exceeded.
- Agent run reports no MCP URL: `MCP_SERVER_URL` was not synced or the prompt agent was deployed
  outside the supported workflow.

Run `azd hooks run postprovision`, then rerun the affected agent's lifecycle workflow.

## Private evaluation limitation

Single-version evaluation works from the private runner. Version-over-version comparison uses
Foundry comparison insights and cluster analysis, which is not supported in a Private
BYO-network workspace. The comparison can fail after individual version scores have completed.

Use the nightly workflow's default single-version mode. This is a platform limitation, not a
missing firewall or RBAC rule.

## Portal results differ from runtime

Portal-originated discovery may not reach private-only APIM. A portal showing no models does not
prove that the agent runtime is broken. Test from the private runner and inspect firewall and
APIM logs before changing network policy.
