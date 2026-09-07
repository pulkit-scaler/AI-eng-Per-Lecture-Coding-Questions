#!/usr/bin/env python3
"""Stage 3: drain the spool.

This file is not written yet - it is yours to write.

    python3 -m intake.worker --once
    python3 -m intake.worker --inbox DIR --out DIR --ledger FILE --once
"""


def strategy_for(flavor):
    raise NotImplementedError("write strategy_for in intake/worker.py")


def main():
    raise NotImplementedError("write intake/worker.py")


if __name__ == "__main__":
    main()
