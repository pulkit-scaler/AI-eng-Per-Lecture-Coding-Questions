#!/usr/bin/env python3
"""claimctl - the Westmere Mutual claims desk command line.

YOU WRITE THIS FILE. It is a program, not a set of functions: it is run from a
shell, it takes a subcommand, and it prints one JSON object on stdout.

    python3 claimctl.py triage --claim WM-3102
    python3 claimctl.py route  --claim WM-3102
    python3 claimctl.py settle --claim WM-3102
    python3 claimctl.py chat   --thread t1 --say "some text"
    python3 claimctl.py trail  --thread t1

What each subcommand has to print is in the problem statement. Print your JSON
object last; anything you print before it is ignored.

Everything the desk provides is importable from `claim_kit`:

    import claim_kit as kit

    kit.get_chat_model()        the chat model, with .with_structured_output()
    kit.load_claim(claim_id)    claim_id, policy, reported, narrative
    kit.claim_ids()             every claim on file
    kit.triage_prompt(...)      build the triage request
    kit.settlement_prompt(...)  build the settlement request
    kit.TRIAGE_SYSTEM, kit.SETTLEMENT_SYSTEM, kit.CHAT_SYSTEM
    kit.CONFIDENCE_FLOOR, kit.MAX_TRIAGE_ATTEMPTS, kit.STEP_CEILING,
    kit.MAX_SETTLE_ATTEMPTS
    kit.policy_lookup, kit.payout_table, kit.fraud_history

Split this into modules beside it if you prefer; only the command line and the
JSON it prints are fixed.
"""
import sys


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    raise NotImplementedError(
        "claimctl is not implemented yet: %s" % (" ".join(argv) or "no arguments")
    )


if __name__ == "__main__":
    sys.exit(main())
