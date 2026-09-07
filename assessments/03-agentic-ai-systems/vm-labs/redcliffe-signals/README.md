# `redcliffe-signals` — Advanced Agent Patterns: ReAct, Reflection & Memory (M3-L8)

A VM lab with **one module per pattern** and a store that has to survive the
process. The learner writes `signals/react_loop.py`, `signals/reflect.py` and
`signals/memory.py`; the command line that calls them is provided, so the
graded surface is the three patterns and nothing else.

- **Target image:** *systemd Ubuntu* (Ubuntu 25.04 / Python 3.13.3).
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/redcliffe-signals`. Control desk on
  `127.0.0.1:8622`. Note store at `store/signals.jsonl`.
- **Standard library only.** No pip install at all, which makes this the
  lightest pack in the module to provision and the fastest to grade.

## Why this shape

The three patterns are independent, so they get independent files and
independent checks. Two consequences worth knowing:

- **A defect in one pattern costs one theme, not the lab.** Verified: seven
  defect probes, five of them losing exactly one check.
- **Persistence is genuinely tested.** Every `signalctl` command is a separate
  process, so a module-level dict fails where in-process grading would have
  passed it. That is the same lever `westmere-claims` uses, with a store the
  learner designs rather than a framework checkpointer.

The similarity arithmetic is the learner's: `signal_kit.embed()` hands back 64
floats and there is no numpy on the machine, so cosine, ranking and the
relevance floor are all written by hand — which is exactly how the lecture
presents it.

## The five themes

1. **The loop acts on what came back.** Two questions; the actions match what
   each question needs, every acting step of the trace carries a thought, the
   action, its input and the observation, and each observation is checked
   against the shape that tool really returns — plus the desk's own record of
   which tools ran and how many times it was asked to think.
2. **Honest failure inside the cap.** A question the desk does not record ends
   with `answered` false, a null answer, a stated reason, and no more actions
   than `MAX_STEPS`.
3. **The reviewer loop.** A draft accepted first time is reviewed **once** and
   never revised; a draft never accepted stops at `MAX_ROUNDS` revisions —
   `MAX_ROUNDS + 1` reviews, since the last revision is reviewed too — and
   carries both outstanding issues. Review and revision counts are read off the
   desk.
4. **Memory across processes.** Five notes in five separate processes, a second
   session that stays separate, and a window that keeps the last four in order
   and has dropped the oldest.
5. **Recall, ranked and floored.** All four notes scored, the two related ones
   returned best first, the two unrelated ones left out — and the desk asked
   nothing at all.

## Marking notes

All 50/50: a `while` loop with its own counter; the loop wrapped in a class;
vectors recomputed on read instead of stored; the reviewer loop written as
recursion; the relevance floor applied before the ranking instead of after.

Single-theme losses: a fabricated observation (check 1), a guess on running out
(check 2), no early stop when the reviewer accepts (check 3), no relevance floor
(check 5), a window that keeps everything (check 4).

Two honest multi-theme losses: a loop that never advances the step number loses
checks 1 and 2, because it cannot make progress on anything; an in-process store
loses checks 4 and 5, because with nothing on file there is nothing to recall.

The fabrication probe — canned answers and canned verdicts, desk never
contacted — scores **20/50**. It loses checks 1, 2 and 3, all three on the desk
trace: no tools ran, the think count is wrong, no review happened. It keeps 4 and
5 because its memory module is the real one; a probe that fakes everything scores
nothing.

## Pack layout

```
app/                  everything provided, plus the three starters
service/signalsvc.py  the control desk (root-only, outside the project)
setup/                setup_script.template.sh -> scripts/setup_script.sh
reference-solution/   the model answer, 5 alternative shapes, 7 defect probes,
                      1 fabrication probe
test-cases/scripts/   script_01..05.sh (shipped) + common.sh, run-all.sh
validation/           the ordering matrix
dist/                 Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh
./build.sh                       # includes a guard no other pack has: see below
./test-cases/scripts/run-all.sh
./sweep.sh
./validation/permutations.sh
```

### One trap this pack paid for

A verdict message must not embed a command substitution whose single-quoted
argument contains a double quote:

```bash
# breaks - bash loses the single quote and reports an unmatched one 60 lines later
report "failed" "the desk saw [$(trace_field "$rid" '.tools | join(",")')]"

# fine - compute first, interpolate a plain variable
seen="$(trace_field "$rid" '.tools | join(",")')"
report "failed" "the desk saw [${seen}]"
```

A plain assignment (`x="$(printf '%s' "$got" | jq -r '.y')"`) is safe; the hazard
is the substitution nested *inside* another double-quoted string. `bash -n` in
`build.sh` catches it, which is how it was found — but it points at a line that
looks fine, so the practice is to precompute every interpolated value. This is a
sibling of the apostrophe-in-a-heredoc trap and the same discipline applies.
