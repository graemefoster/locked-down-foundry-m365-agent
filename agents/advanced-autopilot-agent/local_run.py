"""Local-run wrapper for the sample (baseline/pilot use). No sample source is modified.

    LOCAL_NO_MCP=1  -> skip the 6 MCP servers (Mail/Calendar/... need agentic auth that
                       is unavailable locally; Responses API returns 400 tool_user_error).
    MOCK_M365=1     -> swap MCP tools for generated mock Mail/Calendar function tools
                       (mock_m365/; implies no MCP servers). Fixture: python -m mock_m365.generate
Run from agents/advanced-autopilot-agent:  python local_run.py
"""
import os

from hello_world_a365_agent.agent import FoundryDigitalWorkerAgent
from hello_world_a365_agent.main import main

if os.getenv("LOCAL_NO_MCP") == "1" or os.getenv("MOCK_M365") == "1":
    FoundryDigitalWorkerAgent._load_mcp_servers = lambda self: []  # type: ignore[method-assign]

if __name__ == "__main__":
    raise SystemExit(main())
