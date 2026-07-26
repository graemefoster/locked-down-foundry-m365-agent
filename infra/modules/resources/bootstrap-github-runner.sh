#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstraps a self-hosted GitHub Actions runner on the in-VNet Linux worker VM.
#
# Runs ON the VM via a managed Run Command at provision time (NOT via
# `az vm run-command` from a hook, and it does NOT call the Foundry API — it is
# provisioning glue, so it lives under infra/ next to the module that embeds it).
#
# Flow (Posture A — persistent, non-ephemeral runner; the VM is trusted because
# only gated, trusted workflows ever run on it):
#   1. Acquire a managed-identity token for Key Vault via IMDS (169.254.169.254).
#   2. Read the fine-grained PAT from Key Vault over the private data plane.
#   3. Mint a short-lived GitHub Actions registration token with that PAT.
#   4. Download + configure the runner and install it as a systemd service.
#
# Idempotent: if a runner service is already installed it exits early, so the Run
# Command can re-run on subsequent `azd provision` without re-registering.
#
# Secrets: the PAT is only ever read from Key Vault in-memory on the VM. It is
# never written to disk, the azd env, or the repo. The GitHub registration token
# is short-lived (~1h) and single-use.
#
# Config is injected as an environment preamble by vm-runner-extension.bicep
# (REPO_URL / KEY_VAULT_NAME / PAT_SECRET_NAME / RUNNER_LABELS / RUNNER_USER),
# which avoids relying on how the Linux Run Command surfaces `parameters`.
#
# Dependencies (pwsh, az, python3, git) come from cloud-init-linux-vm.yaml; this
# script blocks on `cloud-init status --wait` so it can never race that.
# ---------------------------------------------------------------------------
set -euo pipefail

RUNNER_VERSION="${RUNNER_VERSION:-2.328.0}"
INSTALL_DIR="${INSTALL_DIR:-/opt/actions-runner}"

log() { echo "[bootstrap-runner] $(date -Is) $*"; }

for var in REPO_URL KEY_VAULT_NAME PAT_SECRET_NAME RUNNER_USER; do
  if [[ -z "${!var:-}" ]]; then
    echo "Required variable '$var' was not set." >&2
    exit 1
  fi
done

# Normalise labels to a clean comma-separated list.
RUNNER_LABELS="$(echo "${RUNNER_LABELS:-vnet,foundry-private}" | tr ' ' ',' | tr -s ',' | sed 's/^,//;s/,$//')"

# --- 0. Wait for cloud-init so pwsh/az/python are present --------------------
log 'Waiting for cloud-init to finish installing dependencies...'
cloud-init status --wait || true

# --- 1. Idempotency: skip if a runner service already exists ------------------
if systemctl list-units --type=service --all --no-legend 'actions.runner.*' | grep -q 'actions\.runner\.'; then
  log 'Runner service already installed. Nothing to do.'
  exit 0
fi

# --- 2. Managed-identity token for Key Vault (IMDS) --------------------------
log 'Acquiring managed-identity token for Key Vault...'
kv_token="$(curl -fsSL -H 'Metadata: true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net' \
  | jq -r '.access_token')"

# --- 3. Read the PAT from Key Vault (private data plane) ---------------------
log "Reading PAT secret '${PAT_SECRET_NAME}' from Key Vault '${KEY_VAULT_NAME}'..."
pat="$(curl -fsSL -H "Authorization: Bearer ${kv_token}" \
  "https://${KEY_VAULT_NAME}.vault.azure.net/secrets/${PAT_SECRET_NAME}?api-version=7.4" \
  | jq -r '.value')"
if [[ -z "$pat" || "$pat" == "null" ]]; then
  echo "Key Vault secret '${PAT_SECRET_NAME}' was empty. Seed it with: az keyvault secret set --vault-name ${KEY_VAULT_NAME} --name ${PAT_SECRET_NAME} --value <PAT>" >&2
  exit 1
fi

# --- 4. Mint a GitHub Actions registration token ------------------------------
# Derive owner/repo from the repo URL and call the repo-scoped runner endpoint.
repo_path="$(echo "${REPO_URL}" | sed -E 's#^https?://[^/]+/##; s#/+$##')"
log "Requesting runner registration token for '${repo_path}'..."
reg_token="$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${pat}" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  -H 'User-Agent: locked-down-foundry-runner-bootstrap' \
  "https://api.github.com/repos/${repo_path}/actions/runners/registration-token" \
  | jq -r '.token')"
if [[ -z "$reg_token" || "$reg_token" == "null" ]]; then
  echo 'Failed to mint a runner registration token (check the PAT scopes: Administration read & write).' >&2
  exit 1
fi

# --- 5. Download + configure + install as a systemd service -------------------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

tarball="actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
if [[ ! -f "$tarball" ]]; then
  log "Downloading runner ${RUNNER_VERSION}..."
  curl -fsSL -o "$tarball" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${tarball}"
fi
log 'Extracting runner...'
tar xzf "$tarball"

# The runner refuses to configure or run as root, so it is owned and executed by
# the VM admin user; svc.sh then installs the systemd unit for that account.
chown -R "${RUNNER_USER}:${RUNNER_USER}" "$INSTALL_DIR"

log "Configuring runner '$(hostname)-vnet'..."
sudo -u "${RUNNER_USER}" env RUNNER_ALLOW_RUNASROOT=0 \
  "$INSTALL_DIR/config.sh" --unattended --url "${REPO_URL}" --token "${reg_token}" \
  --name "$(hostname)-vnet" --labels "${RUNNER_LABELS}" --replace --work '_work'

log 'Installing + starting the runner systemd service...'
"$INSTALL_DIR/svc.sh" install "${RUNNER_USER}"
"$INSTALL_DIR/svc.sh" start

log 'Runner installed and started as a systemd service.'
