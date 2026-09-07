# `redcliffe-signals` — validation record

Everything below was **run**. Authoring host: macOS, CPython 3.13 (system
`python3` is enough — this pack needs nothing else). Target VM: *systemd
Ubuntu*, Ubuntu 25.04 / Python 3.13.3.

## 1. The vectoriser separates what the checks rely on

Before any check was written, `signal_kit.embed` was measured against the notes
check 5 grades, with `RECALL_FLOOR = 0.25`:

```
0.7807  AST-2261 axle counter reset loop on RC-BOX-19        <- expected back
0.2887  SEC-4 possession granted from 01:20 to 04:40 ...     <- expected back
-0.1140 the mess room kettle needs descaling                 <- expected out
-0.1091 spare relays reordered from the depot store          <- expected out
```

`build.sh` re-measures those four every time it runs and refuses to ship if any
of them crosses the floor, so a change to the vectoriser cannot silently
invalidate the check.

## 2. Reference solution

```
SCORE: 50/50   (passed 5, failed 0)
slowest test case: 1s   (portal limit is about 120s)
```

Each pattern was also driven by hand against the desk oracle before the checks
existed: three questions (two answerable, one not) matching on steps, actions,
answer and think count; three drafts matching on revisions, acceptance,
outstanding issues and both call counts; and the memory module across separate
processes, including session isolation and the window.

## 3. Alternative shapes — all 50/50

- `alt1_while_loop` — a `while` with its own counter.
- `alt2_class_agent` — the loop held as an object.
- `alt3_no_stored_vectors` — vectors recomputed on read rather than stored.
- `alt4_reflect_recursive` — the reviewer loop as recursion.
- `alt5_sorted_generator` — the floor applied before the ranking, not after.
- `alt6_learner_shapes` — a submitted `react_loop.py` and `memory.py`: a
  bounded `for` over the step budget with no trace entry for the closing turn,
  and a memory module that re-reads the store on every call and accumulates the
  cosine in an explicit loop. Both are the learner's own code, kept because a
  shape that arrived from outside the pack is worth more than one written to
  pass its own checks.

## 4. Defect probes

Single-theme losses:

- `_defect2_fabricated_trace` — the observation field carries the thought.
  **40/50, `script_01`.**
- `_defect3_claims_answer` — reports an answer the desk did not give. **40/50,
  `script_02`.** The first version of this probe changed only the
  out-of-steps fallback and scored 50/50, because the desk returns a final on
  the step after the plan runs out and that path was never reached. It now
  changes the path that actually executes.
- `_defect4_no_early_stop` — every draft goes the full number of rounds.
  **40/50, `script_03`.**
- `_defect8_no_final_review` — `kit.MAX_ROUNDS` read as a cap on *reviews*
  rather than on *revisions*, so the loop revises twice and stops without ever
  showing the second revision to the reviewer. **40/50, `script_03`.**
  `revisions`, `accepted` and `outstanding` all still match — the fixture hands
  back the same issues on every attempt — so only the judge count catches it.
  Added after a solution of this exact shape was graded during authoring.
- `_defect9_reviews_capped` — the same misreading as `_defect8`, one step
  earlier: the loop breaks on a `revise` verdict at the last review it is
  allowed instead of revising once more, so the draft goes back to the writer
  once where the cap allows twice. **40/50, `script_03`**, caught on the
  revision count rather than the judge count — a different assertion from
  `_defect8`, which is why both probes are kept. This is a real submission,
  added after a learner scored 40/50 on it; the statement fixes in section 8
  are what it exposed.
- `_defect6_no_floor` — recall with no relevance floor. **40/50, `script_05`.**
- `_defect7_no_window` — the window keeps everything. **40/50, `script_04`.**

Honest multi-theme losses:

- `_defect1_ignores_step` — always tells the desk it is on step 1. **30/50,
  checks 1 and 2**, because such a loop cannot progress on any question.
- `_defect5_in_process_store` — notes kept in a module-level list. **30/50,
  checks 4 and 5**, because with nothing on file there is nothing to recall.

## 5. Fabrication probe

`_cheat_hardcode` returns canned answers, canned traces and canned verdicts and
never contacts the desk. **20/50**, losing checks 1, 2 and 3 — all three on the
desk trace: no tools ran, the think count is wrong, no review happened.

It keeps checks 4 and 5 because its memory module is the real one. That is worth
stating rather than hiding: the parts of a run cross-checked against a service
cannot be faked, and the parts that are pure local arithmetic can only be graded
on their output.

## 6. Ordering matrix

`./validation/permutations.sh` — **7 rows, 0 failures**, re-run in full after
the `_defect8` fixes:

1. starters untouched → 0/50, refused fast.
2. written, never run by the learner → 50/50.
3. learner ran it first, then graded → 50/50.
4. grading killed after three checks → 30/50.
5. graded a second time → 50/50.
6. graded a third time → 50/50, store grown to 33 notes, score unmoved.
7. store deleted between runs → 50/50, recreated from scratch.

Rows 2, 3, 4 and 6 each appended a note **as the learner** afterwards and
succeeded.

## 7. Interpreter starts per check

1×2 (check 1), 1 (check 2), 1×2 (check 3), 6 (check 4), 5 (check 5). Check 4 is
the reason `HARD_DEADLINE` is shared across the whole script rather than applied
per call: six independent 25 s bounds would sum past the portal cap even though
no single call is slow. Every check finishes in about a second in practice, since
there is no framework to import.

## 8. Bugs found and fixed during validation

- **A verdict message that embeds a quoted command substitution does not
  parse.** `report "failed" "... $(trace_field "$rid" '.tools | join(",")') ..."`
  makes bash report *unexpected EOF while looking for matching quote* tens of
  lines later. Reproduced in isolation, then fixed by precomputing every
  interpolated value into a variable — and `build.sh` now **refuses to ship** a
  check with that shape. This is a sibling of the apostrophe-in-a-heredoc trap
  and belongs in the other packs too.
- **`require_started` had the same shape** and happened to parse. Fixed anyway.
- **The kit listing in the statement invited the `_defect8` misreading.** It
  truncated the comment it mirrors from `prompts.py` — *"the most times a draft
  may go back"* where the source says *"...to the writer"* — nine lines above a
  task step that uses "go back **to the reviewer**", so "go back" had just been
  defined as the other direction. The three dropped words are restored.
- **Task 3 step 4 still invited the `_defect8` misreading after the kit listing
  was fixed.** *"After `kit.MAX_ROUNDS` rounds, stop whatever the last verdict
  was"* names a unit — a *round* — that the statement never defines, and reads
  as a cap on review cycles. Restoring *"to the writer"* in the listing nine
  lines above was not enough: a learner reading the numbered steps in order got
  `for attempt in range(1, kit.MAX_ROUNDS + 1)` and 40/50 (`_defect9`). What was
  missing was the *consequence*, never stated anywhere in the statement — the
  last revision is reviewed too, so a draft never accepted takes
  `MAX_ROUNDS + 1` reviews. Step 4 now says that outright, step 3 names the
  revision counter apart from the review counter, and the requirements
  paragraph gives both counts for the capped case, not only for the accepted
  one. The two caps in this lab resolve in *opposite* directions at the
  boundary — a spent step budget does **not** buy one more `kit.think`, a spent
  revision budget **does** buy one more `kit.judge` — so Task 2 step 1 now says
  its own boundary out loud rather than leaving the pair to be inferred.
- **The Task 1 example recorded a turn the task said not to record.** Step 5
  asks for a trace entry per *acting* turn; the worked example shows the
  closing turn as well, with nulls. Both pass — `script_01` counts only entries
  whose `action` is non-null — so the fix is in the wording, which now says
  either is fine.
- **The TC03 revision-count message gave no hint at all.** The judge-count
  message branches three ways, but a learner who under-revises fails the
  revision count first and never reaches it — which is exactly what happened.
  That message now branches on direction too, and the under-revising case names
  the two counters.
- **The TC03 judge-count message hardcoded the hint for the opposite bug.** A
  learner who under-reviewed was told *"a draft accepted first time must not be
  reviewed again"*, which points at a bug they do not have. The hint now
  branches three ways: never asked, asked too often, asked too few times.
- **The ordering matrix had stopped grading.** `permutations.sh` decided a row
  by `grep -q '^RESULT:success'` — the shape of the *fallback* `print_status`,
  used only when no `common.sh` is found. Once `gen_tests.sh` began writing the
  faithful replica alongside the checks, every check printed a line of JSON
  instead and the grep could never match: all six real rows silently scored
  0/50. Found by re-running the whole matrix rather than only the case being
  fixed. `grade()` now reads the last line as JSON, exactly as the portal does,
  and keeps the `RESULT:` shape as a fallback. Back to 7 rows, 0 failures.
- **Two `build.sh` consistency checks were themselves wrong** on first run: the
  unanswerable-question count matched the word `answerable` outside the question
  table, and the limit check looked for an unquoted shell default where the
  preamble writes a quoted one. Both now scoped and both pass.

## 9. Not settled on this host

- **Root ownership**: vacuous with no `user` account. Run the matrix as root on a
  provisioned VM once. The store is the specific risk — pre-created as `user` in
  setup, and every check chowns the project back from an `EXIT` trap.
- **Setup wall clock on the real image.** Shorter than any other pack in the
  module, since there is nothing to install, but not measured on the VM. The
  script prints `total setup time` on every run.

## Bug found and fixed 2026-08-31

**Every failure message reported `exit 0`.** `ctl` echoed the JSON object, so all
eight call sites across the five checks read it as `got="$(ctl ...)"` — a command
substitution, which runs the helper in a subshell where its `LAST_RC` assignment
dies. `fail_no_json` then printed the initial `LAST_RC=0` whatever had happened,
so a learner could not tell a crash from a timeout from a program that never ran.
Same defect that reached a learner in `orenford-newsroom`; the fix noted in
`westmere-claims` had never been applied here.

`ctl` now leaves the object in `CTL_OUT` and is called as a statement. Proved
against a candidate whose module writes non-JSON to stdout and exits 3:

```
shipped TestCase.zip:  signalctl printed no JSON object (exit 0)
after the fix:         signalctl printed no JSON object (exit 3)
```

Re-graded afterwards on CPython 3.13.13 — reference `signals` **50/50**, six
alternative shapes **50/50** each, nine defect probes losing exactly their own
checks (30/40/40/40/30/40/40/40/40), `_cheat_hardcode` **20/50** as documented
above. No score moved.
