#!/usr/bin/env python3
"""Run your server and client against a few sample inputs and print the results.

Provided, do not modify. This prints what your code produces - it does not score
you, and the checks use their own inputs.

Usage:  python3 check_local.py
"""
import asyncio
import sys
import traceback

# The lab dependencies finish installing just after the VM finishes provisioning,
# so a terminal opened within a few seconds of the lab starting can get here
# first. Say so plainly instead of letting the import below raise a bare
# ModuleNotFoundError.
try:
    import mcp  # noqa: F401
    import openai  # noqa: F401
except ImportError:
    sys.exit(
        "The lab Python dependencies (mcp, openai) are still installing.\n"
        "This takes well under a minute after the lab starts. Wait a moment and "
        "run this again.\n"
        "Progress:  tail -f /var/log/larkspur-lab/pip.log\n"
        "Finished:  test -f /var/log/larkspur-lab/deps.ready && echo ready"
    )

import solution

RULE = "-" * 72


def show(label, value):
    print(RULE)
    print(label)
    print("  ->", value)


async def walk():
    print("=" * 72)
    print("Tasks 1-3 and 4 - the server, seen through your client")
    async with solution.TransitMCPClient() as client:
        tools = await client.list_tools()
        show("client.list_tools()  [names]", [t.name for t in tools])
        for tool in tools:
            print("     %-18s required=%s" % (
                tool.name, (tool.inputSchema or {}).get("required", [])))

        converted = solution.mcp_tools_to_openai(tools)
        show("mcp_tools_to_openai(...)  [entry count]",
             "%s for %d tools" % (
                 len(converted) if isinstance(converted, list)
                 else type(converted).__name__, len(tools)))
        for entry in (converted if isinstance(converted, list) else []):
            fn = entry.get("function") if isinstance(entry, dict) else None
            print("     type=%-9s name=%-18s parameters=%s" % (
                entry.get("type") if isinstance(entry, dict) else "?",
                (fn or {}).get("name"),
                type((fn or {}).get("parameters")).__name__))

        result = await client.call_tool("list_tables", {})
        show("client.call_tool('list_tables', {})",
             [getattr(b, "text", b) for b in (result.content or [])])

        result = await client.call_tool("get_table_schema", {"table_name": "routes"})
        show("client.call_tool('get_table_schema', {'table_name': 'routes'})",
             "\n     ".join(str(getattr(b, "text", b))
                            for b in (result.content or [])))

        result = await client.call_tool(
            "execute_sql",
            {"query": "SELECT mode, COUNT(*) AS n FROM routes GROUP BY mode"})
        show("client.call_tool('execute_sql', ...)",
             "\n     " + "\n     ".join(
                 str(getattr(b, "text", "")) for b in (result.content or [])))

        result = await client.call_tool("get_table_schema", {"table_name": "drivers"})
        show("a table that is not published",
             "isError=%s  %s" % (getattr(result, "isError", None),
                                 [getattr(b, "text", b)
                                  for b in (result.content or [])]))

        result = await client.call_tool(
            "execute_sql", {"query": "DELETE FROM trips WHERE trip_id = 1"})
        show("a data-modifying query",
             "isError=%s  %s" % (getattr(result, "isError", None),
                                 [getattr(b, "text", b)
                                  for b in (result.content or [])]))

        show("client.read_resource('transit://overview')",
             "\n     " + str(await client.read_resource("transit://overview")
                             ).replace("\n", "\n     "))

        prompts = await client.list_prompts()
        show("client.list_prompts()  [names]", [p.name for p in prompts])
        messages = await client.get_prompt(
            "transit_analyst", {"question": "Which depot has the most vehicles?"})
        rendered = []
        for message in messages or []:
            content = getattr(message, "content", "")
            rendered.append("%s: %s" % (getattr(message, "role", "?"),
                                        getattr(content, "text", content)))
        show("client.get_prompt('transit_analyst', ...)",
             "\n     " + "\n     ".join(rendered).replace("\n", "\n     "))


async def loop_samples():
    print()
    print("=" * 72)
    print("Tasks 5-6 - the agent loop, end to end")
    for question in ("How many bus routes are there?",
                     "How many vehicles are stationed at the Kingsmere depot?"):
        print(RULE)
        print("run_agent_loop(%r)" % question)
        print("  ->", await solution.run_agent_loop(question))


def main():
    for step in (walk, loop_samples):
        try:
            asyncio.run(step())
        except NotImplementedError as exc:
            print(RULE)
            print("  -> not implemented yet (%s)" % exc)
        except Exception:
            print(RULE)
            print("  -> raised:")
            traceback.print_exc()
    print(RULE)


if __name__ == "__main__":
    main()
