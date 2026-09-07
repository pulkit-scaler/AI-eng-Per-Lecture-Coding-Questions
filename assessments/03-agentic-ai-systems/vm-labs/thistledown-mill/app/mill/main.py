"""Run one planning job.

Provided, do not modify.

    python3 -m mill.main --order TM-4301

Builds the crew from your configuration, runs it on that order, and writes the
planning note to out/<order>.md.
"""
import argparse
import pathlib
import sys

from . import millkit


def main(argv=None):
    parser = argparse.ArgumentParser(prog="mill.main")
    parser.add_argument("--order", required=True)
    args = parser.parse_args(argv)

    try:
        order = millkit.load_order(args.order)
    except KeyError as exc:
        print("no such order: %s" % exc)
        return 2

    try:
        from .crew import build_crew
    except Exception as exc:  # noqa: BLE001
        print("could not build the crew: %s: %s" % (type(exc).__name__, exc))
        return 3

    crew = build_crew()
    inputs = {
        "order": order["order"],
        "customer": order["customer"],
        "cloth": order["cloth"],
        "metres": order["metres"],
        "wanted": order["wanted"],
    }
    result = crew.kickoff(inputs=inputs)

    millkit.OUT_DIR.mkdir(parents=True, exist_ok=True)
    note = pathlib.Path(millkit.OUT_DIR) / ("%s.md" % order["order"])
    note.write_text("# Planning note %s\n\n%s\n" % (order["order"], result))
    print("wrote %s" % note)
    return 0


if __name__ == "__main__":
    sys.exit(main())
