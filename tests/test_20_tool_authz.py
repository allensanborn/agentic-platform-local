"""Labs 3 + 4: tools are served through a gateway, and the gateway filters them by persona.

The property under test is the one the workshop cares most about: two authenticated users
ask the same MCP server for its tool list and get DIFFERENT answers, because authorization
happens at the gateway rather than inside the agent.

Why this file is worth more than it looks: the failure mode is fail-OPEN and silent. If the
AgentgatewayPolicy stops matching — a renamed claim, a pruned field, a CRD upgrade — every
request still returns 200 and every persona simply sees every tool. Nothing crashes. The
only signal is that two lists that should differ no longer do.
"""

import pytest

from conftest import explain, kubectl

MCP_VIA_GATEWAY = "http://127.0.0.1:8081/mcp"
MCP_DIRECT = "http://mcp-server.default.svc.cluster.local:8080/mcp"


def _list_tools(url, bearer=None):
    """List MCP tool names over streamable HTTP. Runs in-process via the mcp client."""
    import asyncio

    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    headers = {"Authorization": f"Bearer {bearer}"} if bearer else None

    async def _go():
        async with streamablehttp_client(url, headers=headers) as (read, write, _):
            async with ClientSession(read, write) as session:
                await session.initialize()
                return sorted(t.name for t in (await session.list_tools()).tools)

    return asyncio.run(_go())


def test_no_token_is_rejected(forwards):
    """jwtAuthentication mode: Strict — anonymous is a 401, not an anonymous pass-through."""
    with pytest.raises(BaseException) as excinfo:
        _list_tools(MCP_VIA_GATEWAY)
    detail = explain(excinfo.value)
    assert "401" in detail, (
        f"expected a 401 for an unauthenticated MCP call. Full exception tree:\n{detail}"
    )


def test_personas_see_different_tool_lists(forwards, token):
    """The lab-4 property. If these two lists are ever equal, authz has failed open."""
    sam = _list_tools(MCP_VIA_GATEWAY, token("sam"))
    ana = _list_tools(MCP_VIA_GATEWAY, token("ana"))

    assert sam, "sam saw no tools at all — that is a broken gateway, not authz"
    assert ana, "ana saw no tools at all — that is a broken gateway, not authz"
    assert sam != ana, (
        f"both personas saw the same tools ({sam}) — per-persona authorization is "
        "not being applied. This is the fail-open state: every request still returns 200."
    )


def test_the_privileged_tool_is_the_one_that_differs(forwards, token):
    """Pin the DIRECTION of the difference, not merely that one exists.

    `sam != ana` alone would still pass if the policy inverted and handed the analyst-only
    tool to the support associate. Assert who gets what.
    """
    sam = _list_tools(MCP_VIA_GATEWAY, token("sam"))
    ana = _list_tools(MCP_VIA_GATEWAY, token("ana"))

    assert "lookup_order" in sam, f"sam lost the tool his role needs: {sam}"
    assert "check_inventory" not in sam, (
        f"sam can see check_inventory, which his group should not grant: {sam}"
    )


def test_the_gateway_is_the_only_gate(forwards):
    """mcp-server has no auth of its own — so bypassing the gateway must expose everything.

    This is not a bug being asserted; it is the ARCHITECTURE being asserted. The workshop's
    claim is that the gateway is the control point. If mcp-server ever started doing its own
    filtering, the demo would still pass while teaching the wrong lesson, and the
    'a gate is only a gate if it is the only path' argument would quietly stop being true.
    """
    out = kubectl(
        "exec", "deploy/customer-agent", "--",
        "python3", "-c",
        (
            "import asyncio\n"
            "from mcp import ClientSession\n"
            "from mcp.client.streamable_http import streamablehttp_client\n"
            "async def go():\n"
            f"    async with streamablehttp_client({MCP_DIRECT!r}) as (r,w,_):\n"
            "        async with ClientSession(r,w) as s:\n"
            "            await s.initialize()\n"
            "            print(','.join(sorted(t.name for t in (await s.list_tools()).tools)))\n"
            "asyncio.run(go())\n"
        ),
        timeout=120,
    )
    direct = [t for t in out.strip().splitlines()[-1].split(",") if t]
    assert "check_inventory" in direct and "lookup_order" in direct, (
        f"expected the unfiltered tool set straight off mcp-server, got {direct}"
    )
