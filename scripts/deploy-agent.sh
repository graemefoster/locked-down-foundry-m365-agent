#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install_hint() {
  local command_name="$1"

  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    case "$command_name" in
      pwsh) echo "brew install --cask powershell" ;;
      yq) echo "brew install yq" ;;
      az) echo "brew install azure-cli" ;;
    esac
  else
    case "$command_name" in
      pwsh) echo "Install PowerShell 7 and ensure 'pwsh' is on PATH." ;;
      yq) echo "Install mikefarah/yq v4 and ensure 'yq' is on PATH." ;;
      az) echo "Install Azure CLI and ensure 'az' is on PATH." ;;
    esac
  fi
}

for required_command in pwsh yq az; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Missing required command: $required_command" >&2
    echo "Install it with: $(install_hint "$required_command")" >&2
    exit 1
  fi
done

exec pwsh -NoLogo -NoProfile -File "$script_dir/deploy-agent.ps1" "$@"
