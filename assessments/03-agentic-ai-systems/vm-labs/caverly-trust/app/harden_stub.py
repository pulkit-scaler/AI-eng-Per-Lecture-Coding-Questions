#!/usr/bin/env python3
"""Assemble the defence layer and record what it achieved.

This file is not written yet - it is yours to write.

Two things are required of it:

* a module-level ``HOOKS`` dict wiring your four rails into the hook names the
  support agent understands;
* a command line that runs a campaign file and writes the scorecard:

      python3 harden.py --attacks <file.json> --out reports/scorecard.json
"""

HOOKS = {}


def main():
    raise NotImplementedError("write harden.py")


if __name__ == "__main__":
    main()
