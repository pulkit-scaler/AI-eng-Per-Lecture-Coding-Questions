#!/usr/bin/env python3
"""Exercise the tools and run one planning job, showing what came back.

    python3 check_local.py

This calls your tools directly - no planning model involved - and then runs one
order end to end, the same way the mill does.
"""
import importlib.util
import pathlib
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
DEMO_ORDER = "TM-4301"

# crewai is a 600 MB install. Provisioning starts it in the background and does
# not wait for it, so the first minute or two of the lab has no crewai in it -
# and a plain ModuleNotFoundError here reads like a bug in mill/tools.py when it
# is nothing of the kind. Wait it out instead, and say what is being waited on.
DEPS_READY = ("/var/log/thistledown-lab/deps.ready",
              "/tmp/thistledown-lab/deps.ready",
              "/tmp/deps.ready")
PIP_LOG = "/var/log/thistledown-lab/pip.log"
DEPS_WAIT = 240

DIRECT = [
    ("run_query", {"sql": "SELECT yarn_code, cones_on_hand FROM yarn_stock ORDER BY yarn_code"}),
    ("run_query", {"sql": "SELECT cloth, yarn_code FROM cloth_spec WHERE cloth = 'worsted suiting'"}),
    ("run_query", {"sql": "DELETE FROM yarn_stock"}),
    ("run_query", {"sql": "SELECT 1; DROP TABLE looms"}),
    ("run_query", {"sql": "SELECT nosuchcolumn FROM yarn_stock"}),
    ("stock_lookup", {"yarn_code": "YN-LN22"}),
    ("stock_lookup", {"yarn_code": "YN-ZZ99"}),
]


def have_crewai():
    importlib.invalidate_caches()
    try:
        return importlib.util.find_spec("crewai") is not None
    except (ImportError, ValueError):
        return False


def wait_for_crewai():
    """True once crewai is importable, waiting out the background install."""
    if have_crewai():
        return True
    print("crewai is not installed yet: provisioning is still fetching it in "
          "the background.")
    print("Waiting up to %d s. Nothing is wrong with your code yet." % DEPS_WAIT)
    for waited in range(1, DEPS_WAIT + 1):
        time.sleep(1)
        if have_crewai():
            print("  crewai arrived after %d s.\n" % waited)
            return True
        # The readiness file is written only once the install has resolved,
        # so finding it with no crewai behind it means the install failed
        # rather than lagged.
        if any(pathlib.Path(path).is_file() for path in DEPS_READY):
            print("  the install finished without crewai in it.")
            break
        if waited % 15 == 0:
            print("  still waiting (%d s)" % waited)
    print("crewai is still not importable. That is provisioning, not your "
          "code - look at the install log:")
    print("  tail -n 20 %s" % PIP_LOG)
    return False


def main():
    sys.path.insert(0, str(HERE))
    if not wait_for_crewai():
        return 1
    try:
        from mill.tools import RunQueryTool, StockLookupTool
    except Exception as exc:  # noqa: BLE001
        print("could not import your tools: %s: %s" % (type(exc).__name__, exc))
        print("crewai imports fine, so this is mill/tools.py itself.")
        return 1

    tools = {"run_query": RunQueryTool(), "stock_lookup": StockLookupTool()}
    problems = 0
    for name, args in DIRECT:
        print("=" * 70)
        print("%s(%s)" % (name, ", ".join("%s=%r" % kv for kv in args.items())))
        try:
            answer = tools[name].run(**args)
        except NotImplementedError:
            print("  not written yet")
            problems += 1
            continue
        except Exception as exc:  # noqa: BLE001
            print("  RAISED %s: %s" % (type(exc).__name__, exc))
            print("  a tool should hand an error back as text, not raise")
            problems += 1
            continue
        for line in str(answer).splitlines()[:6]:
            print("  " + line)

    print("=" * 70)
    print("running one planning job on %s" % DEMO_ORDER)
    done = subprocess.run([sys.executable, "-m", "mill.main", "--order",
                           DEMO_ORDER], cwd=str(HERE), capture_output=True,
                          text=True, timeout=180, stdin=subprocess.DEVNULL)
    for line in (done.stdout + done.stderr).strip().splitlines()[-6:]:
        print("  " + line)
    note = HERE / "out" / ("%s.md" % DEMO_ORDER)
    if note.is_file():
        print("-" * 70)
        print(note.read_text()[:900])
    else:
        print("  no planning note was written to out/%s.md" % DEMO_ORDER)
        problems += 1

    print("=" * 70)
    if problems:
        print("%d thing(s) above are not right yet." % problems)
    else:
        print("The tools answered and a planning note was written. That is the "
              "shape; the values still have to be right.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
