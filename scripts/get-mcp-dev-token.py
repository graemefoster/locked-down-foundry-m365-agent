#!/usr/bin/env python3
"""Get a delegated token for the Agent 365 MCP servers, for LOCAL development only.

Signs you in with your own public client app registration and requests the exact
scopes listed in an agent's ToolingManifest.json. Prints ONLY the access token to
stdout (diagnostics go to stderr), so you can do:

    export BEARER_TOKEN=$(uv run --with msal python scripts/get-mcp-dev-token.py \
        --client-id <your-app-id> --tenant <tenant-id> \
        --manifest agents/advanced-autopilot-agent/hello_world_a365_agent/ToolingManifest.json)

Tokens are cached (with the refresh token) in ~/.cache/mcp-dev-token/, so re-running
after the ~1 hour expiry is silent until the refresh token expires.

App registration requirements (your own app, not someone else's):
  * Authentication > "Mobile and desktop applications" redirect URI: http://localhost
    (for the default browser sign-in), and/or
  * Authentication > "Allow public client flows" = Yes (for --device-code).
  * API permissions: the McpServers.*.All delegated scopes from the manifest,
    with admin consent granted (or user consent, if your tenant allows it).

Never put the resulting token in a deployed environment or commit it.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

import msal

DEFAULT_AUDIENCE = "ea9ffc3e-8a23-4a7d-836d-234d7c7565c1"  # Agent Tools Gateway


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def scopes_by_audience(manifest_path: Path) -> dict[str, list[str]]:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    grouped: dict[str, list[str]] = defaultdict(list)
    for server in data.get("mcpServers") or []:
        audience = server.get("audience") or DEFAULT_AUDIENCE
        scope = server.get("scope")
        if scope:
            full = f"{audience}/{scope}"
            if full not in grouped[audience]:
                grouped[audience].append(full)
    return dict(grouped)


def decode_claims(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--client-id", required=True, help="Your public client app ID")
    parser.add_argument(
        "--tenant",
        default=os.getenv("FOUNDRY_TENANT_ID") or "organizations",
        help="Tenant ID or domain (default: $FOUNDRY_TENANT_ID or 'organizations')",
    )
    parser.add_argument("--manifest", required=True, type=Path, help="Path to ToolingManifest.json")
    parser.add_argument("--audience", help="Only this audience (default: the only one, or error)")
    parser.add_argument("--device-code", action="store_true", help="Use device code sign-in")
    parser.add_argument("--force", action="store_true", help="Ignore the cache and sign in again")
    args = parser.parse_args()

    grouped = scopes_by_audience(args.manifest)
    if not grouped:
        log(f"No scopes found in {args.manifest}")
        return 1
    if args.audience:
        if args.audience not in grouped:
            log(f"Audience {args.audience} not in manifest; found: {list(grouped)}")
            return 1
        audience = args.audience
    elif len(grouped) == 1:
        audience = next(iter(grouped))
    else:
        log(f"Manifest has several audiences {list(grouped)}; pick one with --audience.")
        return 1
    scopes = grouped[audience]
    log(f"Requesting {len(scopes)} scope(s) for audience {audience}:")
    for s in scopes:
        log(f"  {s}")

    cache_dir = Path.home() / ".cache" / "mcp-dev-token"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_file = cache_dir / f"{args.client_id}.json"
    cache = msal.SerializableTokenCache()
    if cache_file.exists() and not args.force:
        cache.deserialize(cache_file.read_text())

    app = msal.PublicClientApplication(
        args.client_id,
        authority=f"https://login.microsoftonline.com/{args.tenant}",
        token_cache=cache,
    )

    result = None
    accounts = app.get_accounts()
    if accounts and not args.force:
        result = app.acquire_token_silent(scopes, account=accounts[0])
        if result:
            log(f"Using cached sign-in for {accounts[0].get('username')}")

    if not result:
        if args.device_code:
            flow = app.initiate_device_flow(scopes=scopes)
            if "user_code" not in flow:
                log(f"Could not start device code flow: {json.dumps(flow, indent=2)}")
                return 1
            log(flow["message"])
            result = app.acquire_token_by_device_flow(flow)
        else:
            log("Opening a browser to sign in...")
            result = app.acquire_token_interactive(scopes=scopes, prompt="select_account")

    if cache.has_state_changed:
        with os.fdopen(
            os.open(cache_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w"
        ) as cache_output:
            os.chmod(cache_file, 0o600)
            cache_output.write(cache.serialize())

    if not result:
        log("Sign-in failed: no authentication result was returned.")
        return 1
    if "access_token" not in result:
        log(f"Sign-in failed: {result.get('error')}: {result.get('error_description')}")
        return 1

    token = result["access_token"]
    claims = decode_claims(token)
    granted = set((claims.get("scp") or "").split())
    wanted = {s.split("/", 1)[1] for s in scopes}
    missing = sorted(wanted - granted)
    log(f"app:      {claims.get('appid') or claims.get('azp')}")
    log(f"aud:      {claims.get('aud')}")
    log(f"user:     {claims.get('upn') or claims.get('preferred_username')}")
    log(f"expires:  {time.strftime('%H:%M:%S', time.localtime(claims.get('exp', 0)))}")
    log(f"scopes:   {' '.join(sorted(granted))}")
    if missing:
        log(f"MISSING:  {' '.join(missing)}  <- consent these on the app registration")
        return 1

    print(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
