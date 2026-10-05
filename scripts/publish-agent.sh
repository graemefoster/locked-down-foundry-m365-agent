#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "Missing required command: pwsh" >&2
  echo "Install it with: brew install --cask powershell" >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Missing required command: az" >&2
  echo "Install it with: brew install azure-cli" >&2
  exit 1
fi

exec pwsh -NoLogo -NoProfile -File "$script_dir/publish-agent.ps1" "$@"
