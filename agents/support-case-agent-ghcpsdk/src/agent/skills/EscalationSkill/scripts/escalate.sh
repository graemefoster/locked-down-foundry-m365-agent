#!/usr/bin/env bash
# Wrapper for the EscalationSkill's .NET escalation tool. Locates the agent binary relative to this
# skill (binaries + skills/ share the same publish root) and runs its `escalate` subcommand, so the
# tool works regardless of the shell's current working directory. Requires only the .NET runtime
# (always present for this dotnet_10 hosted agent) -- no Python.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
dll="$root/support-case-agent-ghcpsdk.Agent.dll"

if [[ ! -f "$dll" ]]; then
  dll="$(find "$root" -maxdepth 2 -name 'support-case-agent-ghcpsdk.Agent.dll' 2>/dev/null | head -n1)"
fi

if [[ -z "${dll:-}" || ! -f "$dll" ]]; then
  echo "Could not locate the agent binary (support-case-agent-ghcpsdk.Agent.dll) to run the escalation tool." >&2
  exit 1
fi

exec dotnet "$dll" escalate "$@"
