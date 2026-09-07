# Module 2 VM Labs — Classes 1–3

The three agent/MCP lectures are assessed as **VM labs** rather than ML Function Descriptor
questions: their material is "build a working agent", which a single graded function cannot
express. Each lab hands the learner a fresh Linux VM, has them write real code, and grades it by
**executing** that code — running their agent, inspecting what the model endpoint actually
received, speaking MCP to their server — never by matching strings in a file.

Classes 4–9 are descriptor questions instead; see [`../`](../) and
[`../../README.md`](../../README.md).

## The three labs

**Class 1 — [`kilnbrook-foundry/`](kilnbrook-foundry/) — Agents: Foundations & Planning**
Build a Text2SQL agent from scratch: persona → system prompt, tool schemas in OpenAI format, three
real `sqlite3` tools with a SELECT-only guard, the function-calling ReAct loop, and one shared
message history across turns. Foundry operations database. Endpoint on `127.0.0.1:8781`, project
`/home/user/kilnbrook-foundry/`.

**Class 2 — [`ashford-grid/`](ashford-grid/) — Advanced Agent Concepts**
Build the layer that sits on top of a working loop: a critique gate that stops a bad query before it
runs, a bounded evaluator-optimizer refine loop, execution-aware feedback that carries a real
database error forward, routing through a dispatch table, and guard checks that genuinely run in
parallel. Electricity-grid operations database. Endpoint on `127.0.0.1:8836`, project
`/home/user/ashford-grid/`.

**Class 3 — [`larkspur-transit/`](larkspur-transit/) — MCP: Theory + Server & Client**
Build a real MCP server (three tools, a resource, a prompt, over stdio) and a real MCP client, then
drive the server through an agent loop with the schemas converted to OpenAI format. Transit
operations database. Endpoint on `127.0.0.1:8757`, project `/home/user/larkspur-transit/`.

## What is the same across all three

- **Max Score 50 = 5 checks × 10 points.** The platform accepts at most five test scripts, so each
  script asserts one behavioral *theme* — the cluster of facts one claim implies — and names the
  broken member in its failure message.
- **The judge stops at the first failing check**, so the score a learner receives is the leading run
  of passes, not the per-theme sum. The five checks in each pack are ordered fundamental →
  advanced for that reason, and every harness reports both numbers (`SCORE` = per-theme sum,
  `PORTAL` = the prefix the learner actually gets).
- **Target image:** "systemd Ubuntu", which is really **Ubuntu 25.04 / Python 3.13.3**, no pip, no
  `ensurepip`, PEP 668 externally-managed, password-gated `sudo`. No Docker needed by any of them.
- **No hosted model.** Each lab ships a stdlib-only, OpenAI-compatible endpoint installed to
  `/opt/<lab>-svc/` as `root:root 0700`, whose planner is computed rather than sampled. Real tools,
  deterministic model *decisions* — grading a hosted model's tool selection is not reproducible.
- **The learner's importable set is bounded** and stated in each problem statement: `openai` (plus
  `mcp` for Class 3), their dependencies, and the standard library. There is no numpy/pandas on the
  VM, and a `ModuleNotFoundError` at module scope costs all five checks, not one.
- **Cold-start discipline.** Setup's foreground is the shortest path to a usable lab, plus `curl`
  and `jq`, which are load-bearing for grading itself: the platform's own `print_status` builds its
  line with `jq -n`, so a check that runs before they exist cannot report at all. The `pip` install
  stays in a `setsid`-detached job that publishes a `deps.ready` sentinel. Every check waits on the
  sentinel, never on "curl and jq are present" as a proxy for it, and reports a missing library as
  an environment fault naming its install log.
- **Each pack carries its own proof**: `build.sh` (regenerates the setup script from `app/` +
  `service/` and enforces the invariants), `run-all.sh` (grades one candidate), `sweep.sh` (grades
  every candidate on its own port and lab directory), `validation/permutations.sh` (the ordering
  matrix), and a `VALIDATION.md` recording observed numbers and open items.

## Judge fidelity

All five checks in each pack carry `trap - ERR`, `set +eE` and a per-check stderr redirect. This is
not cosmetic. The platform's `common.sh` installs an `ERR` trap inside the check's own shell and its
`main.sh` grades the **last** line of stdout and stderr combined, so a check whose top-level
`TestNN` call returns non-zero (the ordinary `preflight || return` guard does exactly that) appends
`INTERNAL_ERROR: ...` after its verdict, and the learner sees an **empty results panel** rather than
a score. The three packs shipped without those lines and were migrated on 2026-09-02. The local
`common.sh` in each is now a faithful replica of the platform helper rather than a convenience stub,
and `run-all.sh` grades the last line with a loud `UNPARSEABLE` branch, so a pack's own harness can
no longer be laxer than the judge.

## Verification status

Every pack was validated by its author and then **independently re-verified**: `build.sh` re-run,
and every candidate re-graded from a separate `openai`/`mcp` virtualenv on fresh ports and fresh lab
directories. Observed, not reported:

- **Reference solution 50/50** in all three labs; slowest single check 3s against a ~120s cap.
- **Every alternative correct shape 50/50** — 7 for Class 1, 7 for Class 2, 5 for Class 3, varying
  loop construction (while / for / class / generator / recursion), dispatch style, JSON mode,
  concurrency primitive, and the number of tools registered.
- **Every `_defect*` probe loses exactly its own theme in the per-theme sum** (40/50). Under the
  portal's prefix scoring the same probes score 0, 10, 20, 30 or 40 depending on how early the
  broken theme sits, which is why check order matters and why a bare "40/50" figure misleads.
- **Full-hardcode probes 0/50.** Class 3's MCP-bypassing client — which returns the *right answer*
  via the right tool sequence but never speaks the protocol — also scores **0/50**, because the
  provided kit records which process ran each query and an MCP server is a separate process by
  construction. Two documented residues, each losing exactly the requirement it violates rather
  than scoring nothing: Class 1's endpoint-bypassing probe keeps the two checks whose tasks it
  genuinely implements (20/50), and Class 3's hardcoded server keeps the advertisement check
  (10/50). Both are recorded in their pack's `VALIDATION.md` with the reason.

Each pack's `problem-statement.md` was rewritten on 2026-09-02: no grading section (it was a
reverse-engineering map), a marked project tree, every provided module's API documented with
signatures and a real usage snippet, and per-task Requirements pinning return types, edge cases and
the unit and boundary arithmetic of every cap.

The one item no local run can settle is the **root-ownership invariant with the checks actually
running as root** — off a real VM that assertion is vacuous, and each `VALIDATION.md` says so
plainly instead of implying it was proven. Both defences are in place and build-enforced in all
fifteen check scripts (pre-created state owned by `user`, plus a bounded `chown -R user:user` from
an `EXIT` trap). That repair used to be gated on `case "$LAB_DIR" in /home/user/*)` while every
harness runs under `/tmp`, so it had never once executed during validation; it is now gated on
`id -u user`, which makes the first real VM run also the first execution of that path. Run each
pack's `validation/permutations.sh` **as root on the image once** before the first cohort.

Class 3 was the one to watch, and it is now fixed at the prevention layer as well. Its
learner-spawned stdio server really does write `__pycache__` files, because `mcp`'s
`get_default_environment()` strips `PYTHONDONTWRITEBYTECODE`, and its checks ran the learner's code
inside the project: six root-owned `.pyc` files per grading run, measured. The checks now stage a
copy of the project into their own work directory, which takes that count to zero, and the
`EXIT`-trap `chown` stays as the second layer.
