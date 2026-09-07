# Validation Record — Kilnbrook Foundry

Every number in this file was observed by running the thing it describes. Where something could
**not** be run off the portal, it is listed under "Still to confirm on the real portal" and is not
described as verified anywhere else.

Latest pass: **2026-09-02**, a full review against the module-2 brief. The sections below marked
*(2026-09-02)* are from that pass; everything else was re-verified during it unless it says
otherwise.

## What was executed, and where

**Authoring host** — macOS (darwin 25.5.0), Python 3.14.6 in a clean venv with `openai==3.1.0`,
`mcp==1.9.4` and `pydantic-settings==2.14.0`, the same pins the setup script installs. Neither
`timeout` nor `gtimeout` exists here, so every local measurement exercises the **shell-watchdog**
branch of `run_bounded()`.

**Target image family** — `ubuntu:25.04` under Docker, which is the OS and Python the portal's
"systemd Ubuntu" image was recon-confirmed to ship (Ubuntu 25.04 / Python 3.13.3, PEP 668, no pip).
Both the ordering matrix and the setup timing ran the **real generated setup script** there, and the
checks ran under that image's coreutils `timeout`, so the **other** branch of `run_bounded()` is
validated too.

No Docker is needed to grade this lab; the container is used only to run the setup script and the
ordering matrix against the right OS.

```bash
./gen_tests.sh
./build.sh
PY=<venv>/bin/python ./test-cases/scripts/run-all.sh      # grade the reference
PY=<venv>/bin/python PORT_BASE=9200 ./sweep.sh            # grade every candidate
./validation/permutations.sh                              # ordering matrix, in ubuntu:25.04
RUNS=2 TARGET=15 ./setup-timing.sh                        # setup foreground, in ubuntu:25.04
```

`run-all.sh` assembles a scratch lab directory from `app/` plus a candidate `solution.py`, builds the
database with `service/make_db.py`, starts `service/foundryd.py`, runs `script_01..05` in order and
tallies at 10 points each. Each candidate is graded **on its own port with its own lab directory and
its own database**, so no run can be answered by an endpoint another run started, and a candidate
that damages the database damages only its own copy. `run-all.sh` `cmp`s the assembled
`$LAB_DIR/solution.py` against the file named in `SOLUTION` and aborts with `WRONG-FILE-GRADED` if
they differ; without that guard, omitting `SOLUTION` grades the reference while appearing to grade the
candidate and every row reads 50/50.

## Judge fidelity (2026-09-02) — this was a live production bug

The platform's `/usr/local/bin/judge/test/common.sh` ends with

```
trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
```

so the trap is installed **inside the check's own shell**. Its handler prints `INTERNAL_ERROR: ...`
and exits, landing a second line after the verdict. `main.sh` grades the **last** line of stdout and
stderr combined, so the verdict is discarded, the run reports `evaluated: false`, and the learner
sees an empty "Test Case Results:" panel with no rows at all.

**This pack was unmigrated.** Before this pass, `grep -c 'trap - ERR'` and `grep -c 'exec 2>>'` were
**0 in all five checks**, and `test-cases/scripts/common.sh` was a five-line convenience stub
(`echo "RESULT:$1 | $2"`) with no `jq` and no ERR trap, which is why local validation had never seen
the failure. Fixed:

- `test-cases/scripts/common.sh` is now a **byte-identical copy** of
  `03-agentic-ai-systems/vm-labs/caldon-wire/test-cases/scripts/common.sh`, the faithful replica of
  the platform helper: `jq -n` JSON output, `handle_internal_error` that exits, and the ERR trap.
  Verified with `diff` against that file, no output.
- The **generator's** shared preamble (not the five scripts by hand) now emits `trap - ERR`,
  `set +eE` and `exec 2>>"/tmp/kilnbrook_tc${TC}.err"` after `TC=` is computed. Observed after
  regeneration: `trap - ERR` **5/5**, `exec 2>>` **5/5**, and `build.sh`'s "preamble identical across
  all five" assertion still passes.
- A bug was introduced and caught while writing those comments. The preamble is emitted from an
  **unquoted** heredoc (`<<PRE`), so backticks in a comment are command-substituted. The first
  attempt produced `./gen_tests.sh: line 88: return: can only 'return' from a function`, which is the
  same accident that ate the backticked code out of caldon-wire's comments. The comments are now
  written without backticks and read as complete sentences.

### Negative control, as required

`script_01.sh` with the `trap - ERR` and `set +eE` lines deleted, run against the untouched starter
under `SHELLOPTS=errtrace` (which is what makes the platform's trap reach inside a shell function),
against a live endpoint on port 9256:

```
INTERNAL_ERROR: An error occurred at line 301: 'out="$(Q_CFG="How many moulds are cut in green
sand, and what is their combined capacity?" run_learner "$rid" <<'PY'
  ... 21 more lines ...
)"' exited with status '1'
{ "status": "failed", "message": "TC ended without reaching a verdict (rc=1)" }
```

**23 lines** on stdout, and the real diagnostic is gone: the verdict the learner would receive is the
EXIT trap's fallback, not the message naming what failed. The same check as shipped, same conditions:

```
{ "status": "failed", "message": "build_system_prompt or build_tools_schema did not run to
completion. The check ran your solution.py in a fresh python3 process from /tmp/kb-neg3 and no
result came back, so it printed: File \"/private/tmp/kb-neg3/solution.py\", line 16, in
build_system_prompt | raise NotImplementedError(\"build_system_prompt\") | NotImplementedError:
build_system_prompt [full output in /tmp/kilnbrook_out_tc01_92379.log]" }
```

**1 line**, valid JSON, and the traceback is inside it. The file was restored immediately afterwards
and the sweep re-run.

Note what the first attempt at this control proved instead: a copy of the check placed in `/tmp`
could not `source` `common.sh` (it resolves `$DIR/common.sh`), fell back to the inline
`print_status`, installed no trap, and passed. A green negative control is not evidence; the control
above only became meaningful once the copy sat beside `common.sh` and `errtrace` was inherited.

### The harness is now at least as strict as the judge

`run-all.sh` takes the **last** line of the captured output, parses it with `jq -r '.status'`, and
falls back to the legacy `RESULT:` shape only for that same last line. Anything else lands in a loud
branch:

```
  [!!!!] script_0N.sh      Ns  UNPARSEABLE VERDICT
         The last line of this check is not a verdict, so the portal would
         report this submission as having NO TEST CASES AT ALL - no rows, no
         score, and no message for the learner. Last line was: ...
```

`sweep.sh` surfaces the same condition as a `VOID` row rather than a score. The harness also warns
when a check writes anything other than exactly one line to stdout and stderr combined. Observed
across the whole final sweep: **no warnings on any candidate**. Measured directly as well, counting
non-empty lines from each check run on its own:

```
                 fail path (starter)   pass path (reference)
script_01.sh     1 line                1 line
script_02.sh     1 line                1 line
script_03.sh     1 line                1 line
script_04.sh     1 line                1 line
script_05.sh     1 line                1 line
```

### Scoring is a prefix, not a per-theme sum

`main.sh` `break`s at the first failing case. Credit is therefore a prefix of the five checks. Both
numbers are now reported, and the pack's old claim that each defect probe "loses exactly its own
theme (40/50)" was **only literally true for a defect in check 5**; that wording is corrected here,
in `README.md`, in `SOLUTION.md` and in `INSTRUCTOR-SETUP-GUIDE.md`, and the `PORTAL` column below is
the honest number.

**Check order was wrong and is fixed.** TC01 sat in position 1 but asserted an end-to-end answer,
so it required Tasks 1, 2, 3 **and** 4. Under prefix scoring, a learner who had finished Tasks 1 to 3
and had a bug in the loop scored **0/50**. TC01 now sends one request from the check's own harness,
built out of the learner's `build_system_prompt` and `build_tools_schema`, so it depends on Tasks 1
and 2 only. The order is now genuinely fundamental to advanced:

- **TC01** Tasks 1 and 2 (no `run_agent` involved)
- **TC02** Task 3, the three tools, independent of the loop
- **TC03** Task 4, the loop and its answer
- **TC04** Task 5, the shared conversation
- **TC05** Task 3's guard driven through Task 4's loop, the only check needing both

The `PORTAL` column below is what that ordering buys: `_defect2` (a broken schema tool) keeps 10,
`_defect3` keeps 20, `_defect4` keeps 30, each in proportion to how far the learner got.

### Ownership repair was gated on the wrong thing

Every check had `case "$LAB_DIR" in /home/user/*) chown -R user:user ...`, and every local harness
runs with `LAB_DIR=/tmp/...`, so **the one repair written to stop a learner being locked out of their
own project never fired in the only environment that tests it.** It is now gated on the account
existing, with the `case` arm still refusing an empty variable and a bare `/`:

```bash
case "${LAB_DIR:-}" in
    ""|/) : ;;
    /*)   id -u user >/dev/null 2>&1 && chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
esac
```

Proven in `ubuntu:25.04`, with a project deliberately placed **outside** `/home/user` and chowned to
root first:

```
owner before: root
owner after five checks: user
root-owned files under /tmp/kbtest: 0
```

Under the old gate this would have printed `root` and a non-zero count. This is the first time the
repair has been exercised in the environment that tests it.

### curl and jq are load-bearing and are now installed in the foreground

`print_status` builds its line with `jq -n`, and every verdict message interpolates `jq -r` output.
Before this pass both tools were installed **only by the detached dependency job**, so a submission
made in the minute after provisioning could have found neither. Fixed in the setup template, in
phase 6, deliberately **after** the project, the database and the endpoint are in place, so the
essentials never queue behind an apt call.

`ensure_deps()` no longer treats an `import openai` probe as the fast path on its own. It gates on
the readiness marker, and its fast path `deps_present()` probes **all three** of `curl`, `jq` and
`openai` directly. "curl and jq exist" is never used as a proxy for "the pip install finished": that
proxy is always true once they are in the foreground, and a check built on it would blame the
learner's code for a library the VM never installed. A missing dependency is now reported as an
environment fault naming which one and where its log is.

Measured on `ubuntu:25.04`, running the real generated setup script:

- **Portal-like image** (`python3`, `curl`, `jq` already present, which is the recon-confirmed state
  of the portal image): foreground **4s**. The `installing curl and jq` line does not appear at all,
  so the addition costs nothing there. `base packages done (t+1s)`, `endpoint up (t+2s)`,
  `grading tools checked (t+2s)`, `total setup time: 4s`, **0 warnings**.
- **Bare image** (no `python3`, no `curl`, no `jq`): foreground **54s**, with the endpoint up at
  **t+33s** and the curl/jq install accounting for t+33s to t+52s. **0 warnings**, and
  `curl+jq after foreground: yes / yes`. An earlier placement of this install in phase 1 measured
  **71s** with the endpoint still down at that point, which is why it moved to phase 6.

Worst case remains inside the 95s internal deadline, and the deadline handler finishes with a
summary rather than being killed.

## What each check asserts

Moved here from `SOLUTION.md` on 2026-09-03, verbatim: that document is now a walk-through of the
model answer only, and the grading apparatus belongs in this record and in `README.md`.

Every check couples something the solution returned to something that was independently observed —
the request the endpoint received, or a value computed from the database — so no assertion can be
satisfied by a value alone.

The five checks are ordered by how little each one depends on, because the platform's `main.sh`
breaks out of its loop at the first check that does not report success. Credit is therefore a
**prefix** of the five, not a per-theme sum, and a check in position 1 that needed four of the five
tasks would score a learner who had finished three of them at zero.

- **TC01 (Tasks 1 and 2 only)** — the check itself sends one request built from the learner's
  `build_system_prompt` and `build_tools_schema`, so `run_agent` is not involved. The endpoint reports
  the persona complete (role, 5/5 rules, instructions, output format) and all three schemas usable,
  and answers by asking for `list_tables`, which it only does for a schema it can act on.
- **TC02 (Task 3 only)** — the real table list, the real columns of `moulds` (a table no published
  example mentions), an empty list for a table that does not exist, all cell values of two
  grader-chosen queries, a `DELETE` refused with a `REFUSED:` string, the same count query still
  correct afterwards, and the database file unchanged.
- **TC03** — the endpoint planned exactly `list_tables → get_table_schema → execute_sql`; all three
  results came back matched to the call ids it issued; nothing stalled; the loop finished in between
  four and eight model turns; and the answer carries the database value.
- **TC04** — the first question planned three tools, the second planned only `execute_sql`, an empty
  list of questions returned an empty list, both answers carry their own database values, and the
  turn cap was never hit.
- **TC05** — the plan reached the data-modifying step, the third observation was a refusal, four
  observations were recorded in all, `PRAGMA table_info(pours)` was also refused (which is the only
  assertion that reaches the first half of the guard rule), the answer carries the value of the
  read-only query that followed, and the database is byte-for-byte identical before and after.

Also moved from `SOLUTION.md` in the same pass, and already recorded under "The refusal rule" below:
the reference once refused thirteen keywords while the statement named five, and refused `pragma`
although the statement taught `PRAGMA table_info` as the way to read columns. Both sides now state
and enforce the same two tests, and `alt7_published_rule.py` implements exactly them and nothing
more, at 50/50, so a learner who reads the rule literally is not punished for it.

## Score matrix (2026-09-02)

Reproduce with `PY=<venv>/bin/python PORT_BASE=9200 ./sweep.sh`. Two consecutive full sweeps after
the last edit. **The `SCORE` and `PORTAL` columns are identical between the two passes, row for row,
across all 18 candidates**; the only difference anywhere was the `WORST` wall-clock column reading
1s in one pass and 2s in the other for four rows, which is measurement noise and not a verdict.

`SCORE` is the per-theme sum. `PORTAL` is the prefix, which is what a real submission is awarded.

```
CANDIDATE                      SCORE    PORTAL   WORST  FAILED
solution_stub.py               0/50     0/50     1s     script_01..05
solution.py                    50/50    50/50    1s
alt1_plain_loop.py             50/50    50/50    1s
alt2_spec_driven.py            50/50    50/50    1s
alt3_class_agent.py            50/50    50/50    1s
alt4_generator_loop.py         50/50    50/50    1s
alt5_recursive_session.py      50/50    50/50    1s
alt6_extra_tool.py             50/50    50/50    1s
alt7_published_rule.py         50/50    50/50    1s
_defect1_prompt_role_only.py   40/50    0/50     1s     script_01
_defect2_schema_hardcoded.py   40/50    10/50    1s     script_02
_defect3_wrong_call_id.py      40/50    20/50    1s     script_03
_defect4_fresh_per_question.py 40/50    30/50    1s     script_04
_defect5_guard_only_delete.py  40/50    40/50    1s     script_05
_cheat_hardcode.py             0/50     0/50     1s     script_01..05
_cheat_single_turn.py          0/50     0/50     1s     script_01..05
_cheat_bypass_endpoint.py      20/50    20/50    1s     script_03, 04, 05
_cheat_dump_all.py             20/50    20/50    1s     script_03, 04, 05
```

### Before and after this pass

The rows that moved, and why. Nothing else changed.

- `alt7_published_rule.py` — **new**, 50/50. The read-only guard implemented as exactly the two tests
  the statement publishes and nothing more, so the sweep proves a literal reading of the rule is not
  punished. See "The refusal rule" below.
- `_cheat_dump_all.py` — **new**, 20/50. See "Bypass" below.
- `_cheat_bypass_endpoint.py` — **10/50 before, 20/50 now.** It gains TC01 because TC01 no longer
  requires `run_agent`. This is intended and is not a leak: that file has Tasks 1, 2 and 3 all
  correct, and 20 of 50 for three of five tasks is the honest score. Every check that exists to grade
  the loop still scores it zero. The old row also read `10/50` as though that were what a learner
  would receive; under prefix scoring it was in fact **0/50**, because it failed check 1.
- Every `_defect*` row keeps its `SCORE`, and now also carries the `PORTAL` number that a real
  submission would receive.

Correct implementations, all **50/50** on both columns:

- `reference-solution/solution.py` — the model answer: persona rendered with
  `INSTRUCTIONS/RULES/OUTPUT FORMAT` headings, literal tool schemas, `sqlite_master` +
  `PRAGMA table_info`, the published two-test read-only guard, a `range(MAX_MODEL_TURNS)` loop, and
  one shared message list in `run_session`.
- `alt1_plain_loop.py` — output format placed **before** the instructions, rules bulleted with
  asterisks, schemas from a `_tool(...)` factory, columns discovered via `SELECT * ... LIMIT 0` and
  `cursor.description`, rows rendered as **CSV**, the assistant message appended with **`to_dict()`**,
  and a `while turn < MAX_MODEL_TURNS` counter.
- `alt2_spec_driven.py` — schemas generated from a declarative `TOOL_SPECS` tuple, markdown-heading
  prompt with numbered rules, guard built from two compiled regexes, rows returned as a **JSON array
  of objects**, and the assistant message **rebuilt field by field** rather than dumped.
- `alt3_class_agent.py` — a `FoundryAgent` **class** owning the client, the schemas and the messages,
  so `run_session` reuses one instance; `sqlite3.Row` row factory; rows as an **aligned column
  table**; guard by `startswith` plus substring scan.
- `alt4_generator_loop.py` — the loop as a **generator** yielding each assistant message, consumed by
  a thin driver; `itertools.repeat` for the ceiling; schema from `SELECT * ... WHERE 1 = 0`; guard
  from a token whitelist; rows as `key=value` pairs; message appended via
  `json.loads(model_dump_json(...))`.
- `alt5_recursive_session.py` — the loop as **recursion with a depth argument**, the schema held as a
  module constant and deep-copied per call (and `list_tables` declaring **no `required` key at all**),
  a statement-count plus set-disjoint guard, and rows as a markdown table.
- `alt6_extra_tool.py` — the reference plus a **fourth tool of its own** (`row_count`), declared in
  the schema list and wired into the lookup map.
- `alt7_published_rule.py` — **(new)** the prompt assembled as a list of blocks, schemas from a loop
  over a spec list, the guard as a **token-set** test of exactly the two published rules and nothing
  else, a `_Session` object holding the shared list, and a `while turn < MAX_MODEL_TURNS` counter.

Three of these earn their place beyond "another shape":

- `alt5` proves a no-argument tool may omit `required` entirely rather than declaring it empty, and
  that the loop shape is free: recursion scores exactly what iteration does.
- `alt6` proves TC01 does not grade the *shape* of the schema list. An earlier draft compared sorted
  tool names for equality, which would have failed a learner who offered a helper tool as well as the
  three asked for; it requires the three to be **present** and usable.
- `alt7` proves the published refusal rule is sufficient. This is the regression for the divergence
  described below.

Untouched starter: `app/solution_stub.py` — **0/50**, every check reporting the `NotImplementedError`
path with the traceback inside the verdict.

Defect probes, each failing **only** the check that targets it (and, under prefix scoring, everything
after it):

- `_defect1_prompt_role_only.py` — fails TC01. `build_system_prompt` returns the role line and drops
  the instructions, the rules and the output format. Verdict carries
  `persona complete=false ... missing ["rule1",...,"output_format"]`.
- `_defect2_schema_hardcoded.py` — fails TC02. `get_table_schema` returns the `alloys` columns for
  every table, so the graded lookup of `moulds` is wrong.
- `_defect3_wrong_call_id.py` — fails TC03. Results are fed back under `call_for_<toolname>` instead
  of `call.id`. Every value it returns is still correct; the verdict fails it on
  `results matched to a call id the endpoint issued=0 of 3`. The endpoint pairs observations to plan
  steps **by position**, not by identifier, so this defect does not spuriously break TC04 or TC05.
- `_defect4_fresh_per_question.py` — fails TC04. `run_session` is
  `[run_agent(q) for q in questions]`; both answers are correct and the second question still plans
  three tools instead of one.
- `_defect5_guard_only_delete.py` — fails TC05. The guard keeps only `delete`, `drop` and `truncate`
  and drops the leading-keyword test, so TC02's `DELETE` probe is still refused while TC05's `UPDATE`
  executes: `database unchanged=no`.

Shortcut probes:

- `_cheat_hardcode.py` — **0/50**. Every value the statement and `check_local.py` publish is pasted
  in and nothing touches the database or the endpoint. Re-run after the statement rewrite: still
  exactly 0/50 on both columns.
- `_cheat_single_turn.py` — **0/50**. It makes one real request, with no tools declared, then returns
  a canned answer. Proving a round trip happened is not what any theme is anchored on.
- `_cheat_bypass_endpoint.py` — **20/50, documented.** Its three tools query the database and its
  prompt and schemas are correct, so TC01 and TC02 are earned. `run_agent` and `run_session` never
  call the endpoint, so TC03, TC04 and TC05 all fail on an empty session record.
- `_cheat_dump_all.py` — **20/50, and this is the probe that matters.** Tasks 1 to 3 are done
  properly; `run_agent` then returns **every row of every table** on the theory that an assertion of
  the form "the expected value appears in the returned text" is satisfied by returning everything.
  The theory is correct: TC03 wants `MD-07` and `880`, both of which are rows of `moulds`, and the
  verdict confirms it with `first value absent from the answer=none`. TC03 still fails, on
  `model turns used=0`. That is the evidence that the loop checks rest on what the endpoint recorded
  and not on the answer text, which no input disjointness could have provided.

## The refusal rule: a divergence found and closed (2026-09-02)

**The finding.** `reference-solution/solution.py` refused **13** SQL keywords while
`problem-statement.md` named **5**, and it refused `pragma` although the statement taught
`PRAGMA table_info(<table>)` as the mechanism for `get_table_schema`. A learner implementing the
statement exactly could not know which rule they were held to, and the statement's own teaching
pointed at a statement the reference refused.

**The rule, decided and now stated in Task 3's Requirements.** `execute_sql` strips surrounding
whitespace and a trailing semicolon, then runs the statement only if **both** hold:

1. its first keyword, case-insensitively, is `SELECT` or `WITH`; and
2. it contains none of the words `insert`, `update`, `delete`, `drop`, `alter`.

Both halves are load-bearing, and each was measured against the real database with a hash of the file
before and after every probe:

```
reference (both tests)                     alt7 with test 1 removed
  REFUSED  PRAGMA table_info(pours)          RAN      changed=False
  REFUSED  PRAGMA journal_mode=WAL           RAN      changed=TRUE
  REFUSED  PRAGMA writable_schema=ON         RAN      changed=False
  REFUSED  DELETE FROM pours WHERE 1=1       REFUSED  changed=False
  REFUSED  UPDATE pours SET scrap_kg=0       REFUSED  changed=False
  REFUSED  WITH x AS (SELECT 1) INSERT ...   REFUSED  changed=False
  RAN        select COUNT(*) from pours ;    RAN      changed=False
```

- **Test 1 is what stops `PRAGMA`, and it is not decoration.** `PRAGMA journal_mode=WAL` runs
  without it and **changes the database file**, which is exactly what TC05 hashes. The five-verb scan
  alone does not stop it.
- **Test 2 is what stops the one write that passes test 1.** SQLite accepts
  `WITH x AS (SELECT 1) INSERT INTO pours SELECT ...` as a single statement beginning with `WITH`;
  the reference refuses it on the word `insert`, and a first-keyword-only guard runs it.
- The 8 extra keywords the reference used to carry (`create`, `replace`, `truncate`, `attach`,
  `detach`, `pragma`, `vacuum`, `reindex`) are all **redundant** given test 1: none of them can lead
  a query, so test 1 refuses every one of them as a leading statement. They were removed, so the
  reference now enforces precisely the rule the statement publishes and no more. `pragma` in
  particular was creating a false refusal for a legitimate `SELECT` containing the word.
- **PRAGMA is not an escape hatch**, and it is not a trap for the learner either. `execute_sql`
  refuses it, and `get_table_schema` runs its own `PRAGMA table_info` on a connection from
  `connect()` rather than routing it through `execute_sql`. The reference and all seven alternatives
  do this, and the statement now says it outright in Task 3's Requirements, with the reason. A
  learner who does route it through `execute_sql` gets an empty column list and a TC02 failure whose
  message names the empty list.
- **The rule now has a check behind both halves.** TC02's `DELETE` and TC05's `UPDATE` fail both
  tests, so neither reached test 1 on its own. TC05 now also asserts that
  `execute_sql("PRAGMA table_info(pours)")` comes back `REFUSED:`, which is satisfiable only by
  test 1. Verified safe across every candidate before shipping: reference and `alt1` to `alt7` all
  refuse it; only `_defect5` and the two full cheats run it, and all three already failed TC05, so no
  probe's row moved.
- `alt7_published_rule.py` implements exactly these two tests, in a token-set style rather than a
  regex, and scores **50/50**. That is the proof a literal reading of the published rule is enough.

## Published values, and what the statement may say (2026-09-02)

Every graded expected value was computed from the shipped database and compared against everything
the statement publishes.

Graded expectations:

- TC01 no longer asserts a value at all, only configuration.
- TC02: the table list `["alloys","moulds","pours"]`; the `moulds` columns
  `["mould_id","mould_code","cavity_count","sand_type","max_kg"]`; the cells of a `GROUP BY` over
  `alloys` (`aluminium 2 395`, `bronze 4 1325`, `grey_iron 3 738`, `steel 3 1735`); and
  `20`, `7323`.
- TC03: `MD-07`, `880`.
- TC04: `3575` and `171`.
- TC05: `6`, `2468`.

**One real leak was found and removed.** The old statement published
`SELECT base_metal, COUNT(*) AS n FROM alloys GROUP BY base_metal` with its result, which handed over
**7 of the 12** cell values of TC02's graded `GROUP BY` (`aluminium`, `bronze`, `grey_iron`, `steel`,
`2`, `3`, `4`). That example is gone. Task 3 now shows
`SELECT alloy_code, melt_point_c FROM alloys WHERE base_metal = 'aluminium'` instead, whose values
(`KB-402`, `660`, `KB-409`, `672`) intersect no graded expectation. The old "run and verify" snippet
also suggested `SELECT shift, SUM(poured_kg) FROM pours GROUP BY shift`, which computes TC04's and
TC05's expected sums; it is replaced with a `DISTINCT base_metal` query.

What the rewritten statement publishes, and why each is safe:

- **The three table names.** Published, and they **are** TC02's expected value for `list_tables()`.
  This one cannot be closed by input disjointness and is not being claimed as closed: the database
  file sits in the learner's own project, so `sqlite3 data/foundry.db .tables` prints the list
  whatever the statement says. Withholding the names would buy nothing and would make the document
  much harder to follow. What carries TC02 instead is the other three assertions, all of which need
  live database access: the `moulds` column list in declaration order (not published anywhere), the
  cell values of two queries chosen at grade time, and the refusal. `_cheat_hardcode.py` pastes in
  the table list and still scores **0/50**.
- **The `alloys` column names.** Published, because Task 3's example needs a real return value to
  show. Zero intersection with any graded expectation: the graded column list is `moulds`.
  `check_local.py` prints the `alloys` columns anyway.
- **The `moulds` and `pours` column names.** Not published, and the statement says plainly that they
  are not and that the tools have to read them at run time. Their columns are described by meaning
  instead ("how many cavities it has", "the shift the pour ran on").
- **Row counts.** Not published. `20` is TC02's `pour_count`.
- **The swing-shift session example (`5` and `69`).** Published, and disjoint from every graded
  value: TC04 and TC05 use the **day** and **night** shifts.
- **`372`** in the Task 4 example: disjoint.

Re-run after the rewrite: `_cheat_hardcode.py` scores **exactly 0/50** on both columns, and
`_cheat_single_turn.py` **0/50**.

## Fact preservation for the rewritten statement (2026-09-02)

Every grader-visible literal was extracted from `test-cases/scripts/*.sh`, `gen_tests.sh` and `app/`,
then checked for presence in the new `problem-statement.md`. **71 of 71 present**, checked by script:

- Paths and files: `/home/user/kilnbrook-foundry`, `solution.py`, `check_local.py`, `kiln_kit`,
  `data/foundry.db`.
- Provided API: `make_client`, `MODEL_NAME`, `connect()`, `PERSONA`, `DB_PATH`.
- Endpoint: `http://127.0.0.1:8781/v1`, `8781`, `/health`.
- The seven callables: `build_system_prompt`, `build_tools_schema`, `list_tables`,
  `get_table_schema`, `execute_sql`, `run_agent`, `run_session`.
- Argument names: `persona`, `table_name`, `query`, `question`, `questions`.
- Schema keys: `"type": "function"`, `"function"`, `"name"`, `"description"`, `"parameters"`,
  `"object"`, `"properties"`, `"required"`.
- Protocol: `"role": "system"`, `"role": "user"`, `"role": "tool"`, `"tool_call_id"`, `"content"`,
  `tool_choice="auto"`, `model=MODEL_NAME`, `tools=`, `chat.completions.create`,
  `choices[0].message`, `tool_calls`, `call.function.name`, `call.function.arguments`, `json.loads`.
- Constants and prefixes: `MAX_MODEL_TURNS = 8`, `REFUSED:`.
- SQL: `sqlite_master`, `PRAGMA table_info`, `cursor.description`, `SELECT`, `WITH`, and the five
  forbidden verbs.
- Data: `alloys`, `moulds`, `pours`. Environment: `openai`, `numpy`, `sqlite3`.
- Persona keys: `role`, `instructions`, `rules`, `output_format`.

Style gates on the rewrite: `grep -c '—'` → **0**; `grep -c '^|'` → **0**; rhetorical questions,
`is not X, it is Y` antithesis, `which is what makes/means/matters` and appeals to the reader's
feelings all → **0 hits**; the banned word list
(*genuinely, actually, simply, seamlessly, robust, leverage, crucial, essentially, elegant,
powerful*) and the banned phrases (*under the hood, at its core, think of it as, keep in mind, it is
worth noting*) → **0 hits**; the build's leak guard (`mock`, `lecture`, `course`, `canary`,
`sentinel`, `oracle`, `deterministic`) → **0 hits**. The "How you are graded" section, with its five
check descriptions and points arithmetic, is **deleted** and replaced by a "Before you submit" block
naming the graded file, the command to run first, and one line saying the assessment uses its own
inputs. Length 639 lines.

### Every "must" has a check, or was demoted

Grepped the new statement for *must / required / do not / never / has to*. Each hit was traced to a
check. Five were unenforced and were **demoted from rules to guidance with a plain reason** rather
than left stated as requirements:

- "Do not import `PERSONA` inside the function and do not rewrite its text" — no check can see this.
  Now a paragraph explaining that both work against the persona shipped here and stop working when
  the dictionary changes.
- "Interpolating a table name into a `PRAGMA` ... but check the name against the real table list
  first" — no injection probe exists. Now stated as what keeps an arbitrary string out of the
  statement, not as a rule.
- "Dispatch through a name-to-function lookup" — a learner using `if name == ...` passes, so this was
  shape-grading. Reworded to the part that **is** graded: do not assume the order the tools are asked
  for, or how many times each is asked for (TC05 asks for `execute_sql` twice).
- "Nothing carries over between two separate `run_agent` calls" — each check calls `run_agent` once
  per process, so nothing can see it. Now a statement of what `run_agent` builds.
- "The return value is a `list` of length 3" contradicted "declaring a fourth tool is allowed", and
  length is not checked. Now "contains an entry for each of the three, three is the normal answer".

Three were unenforced and **gained a check** instead, each verified against all 18 candidates before
shipping so no valid row moved:

- `get_table_schema` returns `[]` for a table that does not exist. TC02 now calls
  `get_table_schema("kilnbrook_no_such_table")` and requires an empty list. All eight correct
  solutions already returned `[]`.
- `run_session([])` returns an empty list. TC04 now requires it. Every candidate already did.
- A statement whose first keyword is not `SELECT` or `WITH` is refused. TC05 now requires
  `execute_sql("PRAGMA table_info(pours)")` to come back `REFUSED:`.

## Failure diagnostics (2026-09-02)

The portal shows the learner **only** the verdict message.

**The empty-log dead end is fixed.** The pack had
`report "failed" "$1 - Python error in $(learner_log "$2")$(trace_hint)"` with `trace_hint()` a
no-op stub, so the message named a log file and contributed nothing else. If a learner's module only
defines functions and never runs, the process exits 0 having printed nothing and that log is
**empty**, so the message named evidence that does not exist. A pack-wide sweep
(`grep -n 'learner_log\|_out_\|\.log' test-cases/scripts/*.sh`) found exactly one message path
naming a log, and it now routes through:

- `log_tail <file>` — `tail -n 3`, newlines flattened to ` | `, capped at 280 characters. Built from
  `paste -s -d '|'`, verified to behave identically on macOS and in `ubuntu:25.04`.
- `run_evidence <file>` — if the file has content, the tail rides inside the verdict with the
  `[full output in <path>]` pointer after it. If it is empty, the message says so and names the
  cause: "it printed nothing at all, so `<path>` is empty. A module that only defines functions
  exits quietly like this: check that solution.py defines every callable in the interface contract,
  that importing it raises nothing, and run `cd <dir> && python3 check_local.py`".

Observed against the untouched starter, which is the case that used to be undiagnosable:

```
build_system_prompt or build_tools_schema did not run to completion. The check ran your solution.py
in a fresh python3 process from /tmp/kb-neg2 and no result came back, so it printed: File
"/tmp/kb-neg2/solution.py", line 16, in build_system_prompt | raise
NotImplementedError("build_system_prompt") | NotImplementedError: build_system_prompt [full output
in /tmp/kilnbrook_out_tc01_88815.log]
```

The traceback arrives **with** the failure. `build.sh` refuses to ship a check that names a log
without going through `run_evidence`, and refuses one that still splices `trace_hint`.

**`trace_hint()` is gone**, from both the logging-off and logging-on generator branches, along with
the message that spliced it. `log()`, `log_verdict()` and `log_file()` remain as no-ops in the
default branch, but nothing interpolates them into a learner-visible string, so they read as
disabled instrumentation rather than a hint that never arrives.

**Every interpolated `jq` field degrades to a word.** `word_or <default> <value>` maps an empty
string and the literal `null` to `unknown`, `none` or `0`; `json_field` and `json_compact` wrap it
for the LABJSON payload (with `jq -c` where the value is a list, so the verdict stays one line).
Every inline `$(trace_field ...)` inside a message was hoisted into a local with a default first, so
no verdict can read `... missing  ) tool_schemas_valid=`.

**Every verdict now leads with one plain sentence naming the requirement that failed**, then the
expectation, then the observed values in readable `key=value` form. For example, TC04 now opens
"run_session did not answer both questions on one shared message list." before any values. The
environment guards name a fix rather than a fault:

- Dependencies: "This VM is not ready to be graded: `jq` is not installed, so the lab environment is
  incomplete and this is not a fault in your code. The dependency install log is
  `/var/log/kilnbrook-lab/pip.log` and the readiness marker it writes when it finishes is ..."
- Endpoint down: names `curl -s <url>/health` and `/tmp/kilnbrook_svc.log`.
- No `solution.py`: names the file to write and the command to run first.
- Missing database: says it is an environment fault and that re-provisioning rebuilds the file.
- The EXIT-trap fallback used to read "TC01 ended without reaching a verdict (rc=1)", which tells a
  learner nothing. It now says the check stopped before assessing anything, that this is a lab fault
  rather than theirs, and names `/tmp/kilnbrook_tc<NN>.err`.

## Hardcoding audit, both directions (2026-09-02)

**Learner side.** `reference-solution/solution.py` and all seven `alt*.py`: no fixture data, no
magic numbers, no undocumented env var, port or path literals. The one keyword list that existed
(the reference's 13 write keywords) overlapped the endpoint's own `_WRITE_WORDS` almost exactly,
which would mislead the next reviewer about where the requirement came from; it is now the five
verbs the **statement and the persona** name, and the comment says so.

**Grader side.** No check greps learner-produced prose. Every string comparison against learner
output is either a value computed from the database at grade time (`contains_all`) or the `REFUSED:`
prefix, which the interface contract fixes and the statement states. `grep -n 'grep -qi\|grep -q '`
over the checks returns only `command -v` probes.

**Dead configurability.** `KILN_ENDPOINT` is read by the provided `kiln_kit/client.py` and is
**exported by every check**, so it is live, not dead. `KILN_DB`, `KILN_PORT` and `KILN_SESSION` are
all set by the harness or the setup script. `KILN_MODEL` and `KILN_TURN_CAP` are read by provided or
instructor code and set by nothing; both are documented in the file that reads them and neither is
honoured by any solution, so neither is the `REDCLIFFE_STORE` pattern. No solution in the pack reads
an environment variable.

**Bypass.** Both mechanism assertions re-confirmed. `_cheat_dump_all.py` defeats the value assertion
outright (`first value absent from the answer=none` on TC03) and still scores 0 on TC03, TC04 and
TC05, on the session record. `_cheat_single_turn.py` proves a round trip having happened is not what
any theme rests on.

## Curriculum alignment (Gate 2) — 2026-08-18, re-checked 2026-09-02

Every import, API and syntax form the learner must write, grepped against
`modules/02-advanced-ai-agents/markdown/L1_Agents_Foundations_&_Planning.md`.

Taught and cited, all confirmed present in L1: `chat.completions.create` (4 occurrences),
`tool_choice` (2), `tool_calls` (4), `tool_call_id` (1), `json.loads` (1), `call.function.name` (5),
`call.function.arguments` (2), `choices[0]` (4), `{"role": "tool", ...}` (1), the
`tool_functions` name-to-function map (3), `while True` (1), `temperature` (5).

**One gap found and bridged.** The learner writes `list_tables()` and `get_table_schema()` against a
`sqlite3` connection; L1 builds those same two tools against MySQL (`SHOW TABLES;`,
`SHOW COLUMNS FROM`, lines 1041 to 1146). The SQLite spellings score **0 occurrences in L1**
(`sqlite_master` 0, `PRAGMA table_info` 0) and are first taught two classes later. Every one of the
five "sqlite" hits in L1 is incidental output noise: a progress bar at lines 568 and 580 and a pandas
`UserWarning` at 1166, 1507 and 1558. An identifier appearing only in printed output is not taught as
an API. Bridged in Task 3, which names both statements outright and, as of this pass, also names the
`SELECT * ... LIMIT 0` plus `cursor.description` route that needs no `PRAGMA` at all. Phrased without
the words *lecture* or *course* so the build's leak guard still passes.

Not a defect, checked and cleared: the reference uses `message.model_dump(exclude_none=True)` while
L1 teaches `ai_message.to_dict()`. Both are accepted; `alt1` and `alt5` use the taught `to_dict()`
form and both score 50/50. The starter pushes neither.

Scope note: the learner never authors analytical SQL. That is the model's output, arriving through
`json.loads(call.function.arguments)` and run verbatim by `execute_sql`. Dialect exposure is confined
to the two catalogue lookups above.

## Environment probes (never graded; wrong prefix for the sweep glob)

- `_envprobe_numpy.py` — the reference with `import numpy as np` at module scope. Observed
  **0/50 SCORE, 0/50 PORTAL**: `ModuleNotFoundError` is raised at `import solution`, so it costs all
  five checks rather than the one line that wanted it. Re-run this after any change to the setup
  script's dependency list; if numpy is ever added to the VM it should score 50/50 and the
  Environment block's warning in `problem-statement.md` should come out.
- `_envprobe_hang.py` — the reference with `time.sleep(600)` at the top of `run_session`. Run with
  `RUN_BUDGET=20`: TC04 failed at exactly **20s**, the other four checks passed, **40/50 SCORE** and
  **30/50 PORTAL**. The verdict carried the kill notice as its evidence. That is the proof
  `run_bounded()`s bound is real on a host with no `timeout(1)`.

## Ordering matrix

`./validation/permutations.sh`, inside `ubuntu:25.04`, running the real generated setup script before
every row. Re-run for this pass after the `id -u user`, curl/jq and check-order changes.

The matrix now grades the way `main.sh` does: last line, parsed as JSON, and it **stops at the first
check that does not report success**, so the scores it asserts are prefix scores. It also asserts
`jq` is present after setup, since it is what the matrix parses verdicts with.

Every row asserts the intended score **and** three invariants: nothing under
`/home/user/kilnbrook-foundry` is owned by root, the database and its parent directory are owned by
`user`, and, wherever a solution was written, the learner can still run `python3 check_local.py`
themselves afterwards.

- wrote solution, ran it, then graded → **50**
- wrote solution, ran **nothing**, then graded → **50**
- wrote **nothing** (starter only), then graded → **0**
- ran it, **partial** grading (killed after check 3) → **30**
- a **broken** attempt first, then a good run → **50**
- ran it, graded **twice** → **50** and **50**
- graded **first**, learner then worked, graded again → **50**, learner able to work in between, **50**
- the starter alone → **0**

**40 assertions, 0 failures, `PERMUTATIONS PASSED`, exit 0.** The `jq`-present assertion
added for this pass also passed, so the phase-6 foreground install works on that image.

Two design facts this matrix confirms. First, **no row depends on the learner having run anything**:
every check runs the learner's code itself, so submitting before ever opening a terminal still scores
full marks, which is why the "ran nothing" row is 50 rather than 0. Second, the **partial** row is
the one that catches ownership bugs a full run masks, since a later check's `chown` would hide what
an earlier one did; it passes because the `chown` sits in an `EXIT` trap in every check rather than on
a success path.

**What the matrix still cannot prove.** It runs in a container as root with a `user` account created
by the setup script. It is not the portal's VM, there is no systemd, and the judge is not the real
`main.sh`. The ownership rows are now genuinely exercised (see the `/tmp/kbtest` result above), but
they are exercised by a `chown` this pack calls, not by the platform's own grading sequence.

## Time budgets

**Test cases.** Every wait sits under one of four constants in the shared preamble, and `build.sh`
refuses to ship a script that lacks any of them:

```
SVC_WAIT=12     endpoint health wait
RUN_BUDGET=55   bound around the one learner run
CURL_MAX=5      each restricted-surface request
DEPS_WAIT=20    wait for the dependency readiness marker
```

Worst case is 12 + 55 + 8×5 ≈ **107s**, inside the ~120s per-test limit. Measured across every sweep,
**each check on each candidate finished in 1 to 2s** on the authoring host and inside the container.
Each check also appends its own wall time to `/tmp/kilnbrook_timing.log`.

`RUN_BUDGET` is enforced by `run_bounded()`: coreutils `timeout -k 5` where it exists (the container,
and the portal image), a shell watchdog where it does not (macOS). **Both branches have been
exercised.**

**Setup foreground**, measured with the real generated script on `ubuntu:25.04`: **4s** on a
portal-like image, **54s** on a bare image with no `python3`, `curl` or `jq`. Endpoint up at t+33s in
the bare case. **0 warnings** in `/var/log/kilnbrook-lab/setup-status` on both.

**Dependency install on the target image**, run to completion in `ubuntu:25.04`:

```
deps.state=pinned
openai 3.1.0
Python 3.13.3
warm-up complete
```

So `pip install --only-binary=:all: openai==3.1.0` resolves to wheels on Python 3.13, with no source
build, and the warm-up request through the SDK against the local endpoint succeeds on that image.

## Mechanism probes run by hand

**A malformed tool schema stalls the plan.** The reference with `required` removed from
`get_table_schema`:

```
returned:  UNABLE: this request needs the get_table_schema tool, and it was not offered
           in a usable form.
recorded:  tools.ok=false, get_table_schema.problems=["table_name is not in required"],
           planned=["list_tables"], stalled=true
```

So Task 2 is load-bearing: a schema the endpoint cannot act on produces an agent that will not work.

**An unbounded loop fails fast instead of hanging.** A caller that never appends its tool results, so
the plan can never advance:

```
raised after 0.2s: BadRequestError: Error code: 400 - this conversation has already used
                   30 turns; a tool calling loop needs a turn ceiling and a stop condition
recorded:  chat_turns=30, capped=true, turn_cap=30
```

**The restricted surface is closed without its header.** `curl -s 127.0.0.1:8781/__kbz7q/oracle`
returns `{"error": "not found"}`, a plain 404 with no hint that the path exists.

**The endpoint cannot write the database.** It opens it as `file:<path>?mode=ro`, and its own
read-only check refuses anything that is not a `SELECT`/`WITH`. That is what makes TC05's
byte-for-byte comparison meaningful: the only process that could have changed the file during the
check is the learner code.

**The published examples are accurate.** Both worked examples in `problem-statement.md` were run
against the endpoint and the trace read back:

```
run_agent("What is the highest tensile strength among the bronze alloys?")
  chat_turns=4, planned=["list_tables","get_table_schema","execute_sql"]
run_session([swing pour count, swing scrap weight])
  chat_turns=6, first=["list_tables","get_table_schema","execute_sql"], second=["execute_sql"]
```

So the statement's claims, "four model turns" and "the second cost two", are observed rather than
asserted.

**What one model turn counts, and the boundary.** `chat_turns` in the session record is the number of
`POST /v1/chat/completions` requests. TC03 requires between 4 and `CEILING=8`; TC04 requires at most
`2 × CEILING`. The statement's Task 4 Requirements now state this explicitly: one model turn is one
call to `chat.completions.create` and its response, running a tool is not a turn, `MAX_MODEL_TURNS`
is the largest number of those calls for **one** question, the count restarts per question in
`run_session`, and after the eighth response no ninth call is made. Both
`for _ in range(MAX_MODEL_TURNS)` and `while turns < MAX_MODEL_TURNS` are named as giving that
behaviour. This was the unstated boundary arithmetic that cost a learner 10 points on
`redcliffe-signals`.

## check_local.py (2026-09-02)

Re-read as a learner and improved, since the brief asks whether it actually helps. It now:

- says, above the Task 3 block, that the first three calls read the database and the fourth must come
  back as a `REFUSED:` string without running;
- calls `get_table_schema('sand_deliveries')` so the empty-list answer for an unknown table is
  visible, and `execute_sql('PRAGMA table_info(alloys)')` so the first half of the guard rule is
  visible;
- says, before the delete question, that the model will ask for a data-modifying statement, that the
  guard has to refuse it, and that the answer shown is the read-only query the model falls back to,
  with nothing in the database changing. Without that line the learner saw a row count and no sign
  that a refusal had happened at all;
- renders `run_session` one answer per question with the question above it, instead of printing the
  `repr` of a list of two strings full of `\n` escapes.

Its Task 3 output was run against the reference and pasted into the statement's "Run and verify
locally" section, so the sample output in the statement is a transcript rather than an invention.

## Build invariants

`./build.sh` regenerates `setup/scripts/setup_script.sh` from the template and refuses to ship when:

- a `@@FILE:@@` marker is left unexpanded, or an inlined copy has drifted from its `app/`/`service/`
  mirror (**8/8 match byte for byte** as shipped);
- `PERSONA` differs between `app/kiln_kit/persona.py` and `service/foundryd.py`;
- there are more than five test scripts;
- a check is missing `SVC_WAIT`, `RUN_BUDGET`, `CURL_MAX`, `DEPS_WAIT`,
  `PYTHONDONTWRITEBYTECODE=1`, the `EXIT`-trap `chown -R user:user`, `trap on_exit EXIT`, or its
  verdict calls;
- **(new)** a check is missing `trap - ERR`, `set +eE`, the `exec 2>>` stderr redirect, the
  `id -u user` ownership gate, or `run_evidence`;
- **(new)** a check still splices the dead `trace_hint` stub;
- an apostrophe appears inside a `<<'PY' ... PY` body in a check or in `gen_tests.sh`;
- the five checks' shared preamble has drifted between scripts;
- `problem-statement.md` contains a markdown table (`grep -c '^|'` → **0**, verified);
- a learner-visible file leaks an internal term;
- either zip is missing `scripts/` or `data/`, or `TestCase.zip` contains `common.sh`, `run-all.sh`
  or a `.DS_Store` (verified: **0** such entries).

**(new)** The three zip-content assertions used `unzip -Z1 "$z" | grep -q ...`. Under `pipefail`,
`grep -q` exits at its first match, the producer takes SIGPIPE and the pipeline fails intermittently:
this exact shape raced 1 in 5 in a module-3 `build.sh`. All three now capture the listing once and
match against a here-string. `validation/permutations.sh` had the same shape and was fixed the same
way.

`bash -n` passes on all **14** shell files in the pack and `py_compile` on all **26** Python files.

## Zip artifacts

```
dist/Setup.zip      scripts/  scripts/setup_script.sh   data/
dist/TestCase.zip   scripts/  scripts/script_01..05.sh  data/
```

Confirmed with `unzip -Z1` on both after the final `build.sh`. `TestCase.zip` carries `scripts/` and
`data/` and does not smuggle `common.sh` or `run-all.sh`. The eight sources inlined into the
generated `setup_script.sh` come from `app/` and `service/` by construction, so the copy the VM
receives cannot drift from the readable mirrors in this pack.

## Claims from earlier passes that this pass disproved

Recorded rather than deleted, because a stale validation row is a defect of its own.

1. "Each defect probe fails **only** the check that targets it, 40/50." True as a per-theme sum,
   **false as a score a learner would receive**: `main.sh` breaks at the first failure, so
   `_defect1` is 0/50 on the portal, not 40/50. Corrected everywhere it appeared.
2. "`_cheat_bypass_endpoint.py` scores 10/50, the one theme it implements." Now 20/50, because TC01
   no longer depends on `run_agent`. Its portal score under the old ordering was in fact 0/50, since
   it failed check 1.
3. "`calls ensure_deps` before anything that shells out to `curl` or `jq`, and the readiness marker
   gates those two as well as `openai`." The ordering was right, but `ensure_deps` short-circuited on
   an `import openai` probe before the marker was consulted, and neither `curl` nor `jq` was ever
   probed or installed in the setup foreground. Both fixed.
4. "The four constants bound every wait, so nothing can hang." Still true, but the ownership repair
   that runs on the way out was gated on `LAB_DIR` starting `/home/user/`, so it had never once
   executed in local validation. Fixed and now proven.
5. The Gate 2 section previously said "**Not re-run for this pass:** the score matrix below". The
   matrix in this file is current: it was produced twice after the last edit in this pass.

## Still to confirm on the real portal

Everything above was executed. These can only be observed on the portal itself.

1. **The judge fidelity fix, end to end.** This is the first item to check. The replica `common.sh`
   and the errtrace negative control are strong evidence, but the real
   `/usr/local/bin/judge/test/common.sh` and the real `main.sh` were not run. On the first real
   submission, confirm the "Test Case Results:" panel shows **five rows**, that a deliberately
   failing submission shows a row with its message rather than an empty panel, and that
   `/tmp/kilnbrook_tc01.err` exists on the VM afterwards (its presence proves the stderr redirect
   took effect).
2. **The ownership repair under the platform's own sequence.** The `chown` now fires, proven with
   `LAB_DIR=/tmp/kbtest` in `ubuntu:25.04`. What a real VM must confirm is the case this authoring
   host cannot produce: grade a submission, then as the `user` account run
   `find /home/user/kilnbrook-foundry -user root` (expect no output) and
   `cd /home/user/kilnbrook-foundry && python3 check_local.py` (expect it to run). Repeat after a run
   killed at the time cap, since that is the path the `EXIT` trap exists for.
3. **First-attempt provisioning.** The 4s and 54s figures were measured under Docker on an arm64 host
   running amd64 under emulation, which inflates compute while leaving network waits representative.
   The remaining unknown is the portal front end's own polling window, which is not published. After
   the first provisioning, read the last line of `/var/log/kilnbrook-lab/setup.log`
   (`total setup time: <n>s`) and `grep '^WARN' /var/log/kilnbrook-lab/setup-status`. Confirm
   specifically that the phase-6 curl/jq install prints nothing, which is what the portal image
   should produce.
4. **The systemd unit.** In a container there is no systemd, so every local run took the `nohup`
   fallback. On the portal image `kilnbrook-foundryd` should come up under systemd instead;
   `systemctl status kilnbrook-foundryd` is the whole check. Either path leaves the endpoint
   answering and the checks start it on demand, so this is a tidiness confirmation.
5. **Where the platform leaves its copy of the setup script.** That script carries the endpoint source
   inline, including the `X-Kiln-Audit` value and the restricted paths. The endpoint itself is
   installed `root:root` mode `0700`, so the only exposure is the platform's own copy of
   `Setup.zip` or the expanded script; worth confirming it is not readable by `user`. The practical
   impact is bounded by the fact that every check couples returned values to what the endpoint
   recorded, which is why `_cheat_hardcode` and `_cheat_single_turn` are both 0/50.
