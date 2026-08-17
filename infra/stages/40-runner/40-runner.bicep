/*
Stage 40 — RUNNER (VMs + seed/runner RBAC).

The in-VNet compute plane, always after the platform (stage 10):
  * linuxVmModule    - ALWAYS. The self-hosted GitHub Actions runner host for agent seeding.
                       Holds the private-plane RBAC.
  * vmModule         - OPTIONAL Windows dev VM (deployWindowsVm), human RDP/Edge only.
  * bastionModule    - OPTIONAL (deployBastion), interactive human access only.
  * vmFoundryRole    - ALWAYS. Foundry User on the project for the Linux VM MI (seeding).
  * runner RBAC + PAT secret + runner extension - opt-in (installGithubRunner), extension LAST.

Depends only downward on stages 00 (vnet/subnet) and 10 (Foundry/KV facts), threaded in as
params. Intra-stage ordering preserved verbatim: the runner extension runs after the KV-secrets
role and the PAT secret; every RBAC/role edge is retained.
*/

param location string
param uniqueSuffix string

// ---- stage 00 (foundation) facts ----
param foundrySpokeVnetName string
param bastionSubnetId string
param vmSubnetName string

// ---- stage 10 (platform) facts ----
param aiAccountName string
param projectNameDev string
param projectNameTest string
param keyVaultName string

// ---- VM admin ----
@secure()
param vmAdminPassword string
param vmAdminUsername string

// ---- optional dev VM / bastion ----
param deployWindowsVm bool
param deployBastion bool

// ---- self-hosted GitHub runner (opt-in) ----
param githubRunnerRepoUrl string
@secure()
param githubRunnerPat string
param githubRunnerPatSecretName string
param githubRunnerLabels string

// ==================== VMs + BASTION (in Foundry Spoke) ====================

// Two boxes, one job each:
//   * linuxVmModule   - ALWAYS deployed. The in-VNet workhorse: the self-hosted Actions
//                       runner host for agent seeding.
//                       Linux because microsoft/ai-agent-evals is effectively Linux-only.
//                       Holds all the private-plane RBAC (Foundry / KV / Contributor).
//   * vmModule        - OPTIONAL Windows dev VM, human RDP + Edge inspection only, no RBAC.
// Bastion is its own module, gated by deployBastion (which defaults to deployWindowsVm):
// it exists purely for interactive human access, and the Linux VM needs no interactive
// path for automation. Deploying it separately means you CAN still opt into Bastion SSH
// on the Linux VM without paying for the Windows VM.

module linuxVmModule './resources/vm-linux.bicep' = {
  name: 'linux-vm-deployment-${uniqueSuffix}'
  params: {
    location: location
    vmName: 'runner-vm-${uniqueSuffix}'
    virtualNetworkName: foundrySpokeVnetName
    subnetName: vmSubnetName
    adminPassword: vmAdminPassword
    adminUsername: vmAdminUsername
  }
}

module vmModule './resources/vm.bicep' = if (deployWindowsVm) {
  name: 'vm-deployment-${uniqueSuffix}'
  params: {
    location: location
    vmName: 'test-vm-${uniqueSuffix}'
    virtualNetworkName: foundrySpokeVnetName
    subnetName: vmSubnetName
    adminPassword: vmAdminPassword
    adminUsername: vmAdminUsername
  }
}

module bastionModule './resources/bastion.bicep' = if (deployBastion) {
  name: 'bastion-deployment-${uniqueSuffix}'
  params: {
    location: location
    bastionSubnetId: bastionSubnetId
  }
}

// ==================== AGENT DEPLOY: VM RBAC ====================

// Agent deploys run from the in-VNet self-hosted GitHub Actions runner (the per-agent
// .github/workflows/deploy-*-agent.yml workflows), which execute scripts/create-agent.ps1 natively
// on the private LINUX VM (the only host that can reach the Foundry private endpoint — the Windows
// dev VM is optional and intentionally has no such access). The Linux VM's system-assigned identity
// needs
// Foundry User on BOTH projects (dev + test) so the on-VM script can acquire a token and call
// the Agents API against either environment — that RBAC is provisioned here.
module vmFoundryRoleDev './rbac/vm-foundry-role.bicep' = {
  name: 'vm-foundry-role-dev-${uniqueSuffix}'
  params: {
    accountName: aiAccountName
    projectName: projectNameDev
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

module vmFoundryRoleTest './rbac/vm-foundry-role.bicep' = {
  name: 'vm-foundry-role-test-${uniqueSuffix}'
  params: {
    accountName: aiAccountName
    projectName: projectNameTest
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// ==================== SELF-HOSTED GITHUB ACTIONS RUNNER (opt-in) ====================

// When BOTH githubRunnerRepoUrl AND githubRunnerPat are set, install a self-hosted runner
// on the Linux worker VM so complex, representative deployments can run INSIDE the VNet
// (reaching the private Foundry endpoint directly) instead of being marshalled through
// `az vm run-command`. The VM MI needs Key Vault Secrets User to read the runner PAT; the
// Run Command that runs the bootstrap is sequenced AFTER that role assignment.
//
// The PAT is REQUIRED: without it there is no secret to seed into Key Vault, so the on-VM
// bootstrap would 404 reading `gh-runner-pat` and fail provisioning. There is no point
// deploying the runner half — so a repo URL supplied without a PAT simply skips the runner
// (no RBAC, no PAT secret, no Run Command) rather than failing. See docs/github-runner.md.
var installGithubRunner = !empty(githubRunnerRepoUrl) && !empty(githubRunnerPat)

module vmKeyVaultSecretsRole './rbac/vm-keyvault-secrets-role.bicep' = if (installGithubRunner) {
  name: 'vm-kv-secrets-role-${uniqueSuffix}'
  params: {
    keyVaultName: keyVaultName
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Grant the VM MI Contributor over the resource group so the runner (which runs AS the
// VM MI) can do control-plane work for representative end-to-end deployments — e.g.
// create the Azure Bot Service in the gated Teams / M365 publish workflow. Opt-in
// (runner only) and scoped to the resource group to bound the blast radius.
module vmContributorRole './rbac/vm-contributor-role.bicep' = if (installGithubRunner) {
  name: 'vm-contributor-role-${uniqueSuffix}'
  params: {
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Grant the VM MI Cognitive Services OpenAI User on the AI Services account so the nightly
// eval workflow's AI-assisted evaluators can call the judge model's inference API. This is a
// data-plane action neither Contributor (management-plane) nor Foundry User (Agents API)
// covers — without it the judge calls fail with 401 PermissionDenied. See the module header
// for the full rationale. Opt-in (runner only) and scoped to the account.
module vmOpenAiUserRole './rbac/vm-openai-user-role.bicep' = if (installGithubRunner) {
  name: 'vm-openai-user-role-${uniqueSuffix}'
  params: {
    accountName: aiAccountName
    vmPrincipalId: linuxVmModule.outputs.vmPrincipalId
  }
}

// Write the PAT into Key Vault via ARM (control plane) — only when a value is
// supplied. Skipped (leaving any existing secret intact) when GITHUB_RUNNER_PAT
// is empty, so the secret can be seeded once and the env var cleared afterward.
module runnerPatSecret './resources/runner-pat-secret.bicep' = if (installGithubRunner && !empty(githubRunnerPat)) {
  name: 'runner-pat-secret-${uniqueSuffix}'
  params: {
    keyVaultName: keyVaultName
    secretName: githubRunnerPatSecretName
    patValue: githubRunnerPat
  }
}

module vmRunnerExtension './resources/vm-runner-extension.bicep' = if (installGithubRunner) {
  name: 'vm-runner-extension-${uniqueSuffix}'
  params: {
    vmName: linuxVmModule.outputs.vmName
    location: location
    githubRunnerRepoUrl: githubRunnerRepoUrl
    keyVaultName: keyVaultName
    githubRunnerPatSecretName: githubRunnerPatSecretName
    githubRunnerLabels: githubRunnerLabels
    runnerUser: vmAdminUsername
  }
  dependsOn: [
    vmKeyVaultSecretsRole
    runnerPatSecret
  ]
}

@description('Name of the private Linux VM that hosts the in-VNet self-hosted GitHub Actions runner.')
output vmName string = linuxVmModule.outputs.vmName
