"""The control desk command line.

Provided, do not modify. It calls the three modules you write and prints one
JSON object.

    python3 signalctl.py ask    --question "why is RC-BOX-19 showing red"
    python3 signalctl.py review --draft RC-D-118
    python3 signalctl.py note   --session nightturn --say "..."
    python3 signalctl.py recall --session nightturn --about "..."
    python3 signalctl.py window --session nightturn
"""
import argparse
import json
import sys


def main(argv=None):
    parser = argparse.ArgumentParser(prog="signalctl")
    subs = parser.add_subparsers(dest="command", required=True)

    ask = subs.add_parser("ask")
    ask.add_argument("--question", required=True)

    review = subs.add_parser("review")
    review.add_argument("--draft", required=True)

    note = subs.add_parser("note")
    note.add_argument("--session", required=True)
    note.add_argument("--say", required=True)

    recall = subs.add_parser("recall")
    recall.add_argument("--session", required=True)
    recall.add_argument("--about", required=True)

    window = subs.add_parser("window")
    window.add_argument("--session", required=True)

    args = parser.parse_args(argv)

    try:
        if args.command == "ask":
            from signals.react_loop import answer
            payload = answer(args.question)
        elif args.command == "review":
            from signals.reflect import refine
            payload = refine(args.draft)
        elif args.command == "note":
            from signals.memory import remember
            payload = remember(args.session, args.say)
        elif args.command == "recall":
            from signals.memory import recall as do_recall
            payload = do_recall(args.session, args.about)
        else:
            from signals.memory import window as do_window
            payload = do_window(args.session)
    except NotImplementedError as exc:
        print(json.dumps({"error": "not implemented", "detail": str(exc)}))
        return 4
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"error": type(exc).__name__, "detail": str(exc)[:300]}))
        return 3

    print(json.dumps(payload, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
