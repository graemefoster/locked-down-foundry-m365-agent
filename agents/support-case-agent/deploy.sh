#!/usr/bin/env bash
# Build support-case-agent for a Foundry code (source-zip) deploy: publish -> zip -> sha256 -> metadata.json.
# Then use deploy.http to upload. Usage: ./deploy.sh [--clean]
set -euo pipefail
cd "$(dirname "$0")"

CSPROJ="support-case-agent.Agent/support-case-agent.Agent.csproj"
ENTRY_DLL="support-case-agent.Agent.dll"
MANIFEST="agent-code.yaml"
PUBLISH_DIR="publish"
ZIP_PATH="agent.zip"
METADATA_PATH="metadata.json"

[[ "${1:-}" == "--clean" ]] && rm -rf "$PUBLISH_DIR" "$ZIP_PATH" "$METADATA_PATH"

echo "==> dotnet publish -> $PUBLISH_DIR (linux-x64, Release)"
rm -rf "$PUBLISH_DIR"
dotnet publish "$CSPROJ" -c Release -r linux-x64 --self-contained false -o "$PUBLISH_DIR"
[[ -f "$PUBLISH_DIR/$ENTRY_DLL" ]] || { echo "error: '$ENTRY_DLL' missing from publish output." >&2; exit 1; }

# Foundry expects the entry DLL at the archive root, so zip from inside publish/.
echo "==> zip -> $ZIP_PATH"
rm -f "$ZIP_PATH"
( cd "$PUBLISH_DIR" && zip -q -r -X "../$ZIP_PATH" . )

echo "==> metadata.json (name/description/definition from $MANIFEST)"
if command -v yq >/dev/null 2>&1; then
  yq -o=json '{"name": .name, "description": .description, "definition": .definition}' "$MANIFEST" > "$METADATA_PATH"
else
  python3 - "$MANIFEST" "$METADATA_PATH" <<'PY'
import json, sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
json.dump({"name": m["name"], "description": m.get("description"), "definition": m["definition"]}, open(sys.argv[2], "w"), indent=2)
PY
fi

if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
else
  SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
fi
SHA="$(printf '%s' "$SHA" | tr '[:upper:]' '[:lower:]')"

# Write .env (gitignored) that deploy.http reads via {{$dotenv ...}}: the sha, plus a fresh
# Foundry data-plane token if az is logged in (token lasts ~1h; re-run ./deploy.sh to refresh).
{
  echo "zipSha256=$SHA"
  if command -v az >/dev/null 2>&1; then
    TOKEN="$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>/dev/null || true)"
    [[ -n "$TOKEN" ]] && echo "token=$TOKEN"
  fi
} > .env

echo
echo "zip     : $ZIP_PATH"
echo "sha256  : $SHA"
echo "-> wrote .env (zipSha256$( [[ -n "${TOKEN:-}" ]] && echo ' + token' )). Just send the request in deploy.http."
