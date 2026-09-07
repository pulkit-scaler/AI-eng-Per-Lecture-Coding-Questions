# Larkspur Transit — Validation Record

Everything below was **run**, on the authoring host, unless a line says otherwise. The rows that
could not be exercised off-VM are listed in section 10 and nowhere else.

- **Host:** macOS 25.5.0, arm64. No root, no `user` account, no `/proc`, no `apt`.
- **Interpreter used for every run:** CPython **3.13.13** in a venv holding exactly the pinned rung.
  Chosen deliberately: the target image ships Python **3.13.3**, so this is the same `cp313` ABI and
  the same wheel tags the VM will resolve.
- **Installed set under test:** `mcp==1.9.4`, `pydantic-settings==2.14.0`, `openai==3.1.0`
  (identical to the pinned rung in the setup script), resolved with `--only-binary=:all:`.
- **Review pass date:** 2026-09-02. Original authoring record: 2026-08-17.

---

## 0. What this review changed, and the before/after matrix

The scores did not move. What moved is whether a verdict survives to the learner, whether a grading
run leaves the project alone, and whether a failure message is actionable.

**Score matrix, before and after the review** (`./sweep.sh`, all five checks run regardless of
failures, which is what shows each defect losing only its own theme):

```
CANDIDATE          BEFORE   AFTER    FAILED CHECKS (after)
__stub__            0/50     0/50    01 02 03 04 05
__reference__      50/50    50/50    -
alt1               50/50    50/50    -
alt2               50/50    50/50    -
alt3               50/50    50/50    -
alt4               50/50    50/50    -
alt5               50/50    50/50    -
_defect1           40/50    40/50    01
_defect2           40/50    40/50    03
_defect3           40/50    40/50    04
_defect4           40/50    40/50    02
_defect5           40/50    40/50    05
_cheat_bypass       0/50     0/50    01 02 03 04 05
_cheat_hardcode    10/50    10/50    02 03 04 05
```

Unchanged row for row, which is the point: the P0 and P1 work is about fidelity and diagnostics, and
none of it was allowed to move discrimination. The one time it did, it was caught and reverted
(section 6).

Defects fixed, each with the evidence in the section named:

1. **The five checks were unmigrated for judge fidelity** (section 1). `grep -c 'trap - ERR'` and
   `grep -c 'exec 2>>'` were **0** in all five, and `test-cases/scripts/common.sh` was a convenience
   stub with no `jq` and no ERR trap, so local validation could never have seen the failure.
2. **`run-all.sh` graded more loosely than the judge** (section 1). It matched the *first* `RESULT:`
   line anywhere in the output; the platform parses the *last* line as JSON.
3. **The ownership repair was gated on the wrong thing** (section 8). `case "$LAB_DIR" in
   /home/user/*)` meant the one line written to stop a learner being locked out never executed in
   any environment that tests it, because every harness runs under `/tmp`.
4. **Grading wrote into the learner's project** (section 8). Measured: 6 root-owned `.pyc` files per
   run. Now 0, by prevention rather than repair.
5. **`curl` and `jq` were installed only in the detached job** (section 3), so a check running in
   the first seconds of a VM could read an empty string for every value it looked up and blame the
   learner's code.
6. **The empty-log dead end** (section 7). Verdicts named a log file that a failed spawn leaves
   empty, and the helpers spliced into those messages were no-ops.
7. **A server that died at import reported only `ExceptionGroup: unhandled errors in a TaskGroup
   (1 sub-exception)`** (section 7). The real cause was in the sub-exceptions and on the server's own
   stderr, and neither reached the learner.
8. **Four `pipefail` races** in `build.sh` and the setup template (section 3).
9. **Three requirements in the statement had no check behind them** (section 5), and one contract
   line disagreed with what the check actually compared.
10. **`_cheat_bypass` was under-detected by one route** and `alt5` carried a dead env override
    (section 6).
11. **The stray-process column disagreed between two passes of the same sweep** (section 4). That
    was the harness, not the lab, and a flaky column is a defect of its own.

Claims from the previous record that this pass **disproved**, corrected rather than deleted:

- *"Both layers are in place ... every check chowns the project back from its `EXIT` trap, guarded by
  `case "$LAB_DIR" in /home/user/*)`."* The guard made the repair unreachable everywhere it was
  tested. Corrected in section 8.
- *"Three consecutive sweeps agreed row for row."* The SCORE column agreed; the STRAYS column did
  not, once anything else on the host had a matching command line. Corrected in section 4.
- *"`_envprobe_hang` ... TC01–04 each fail in 10–11s."* Confirmed at 11s, but only from a clean
  process table; a leftover probe from an earlier attempt made the same check report in 2s. Both
  numbers are in section 4.
- *"A prompt that ignores its argument (defect 3) fails [TC04]."* Still true, but for one revision
  during this pass it also failed TC05. Recorded in section 6 rather than quietly fixed.
- The previous record described defect probes as scoring 40/50 without saying that the platform
  stops at the first failure. Only a defect in check 5 scores 40/50 on the portal. Measured table in
  section 9.

---

## 1. Judge fidelity (the highest-priority item)

### The mechanism

The platform's `/usr/local/bin/judge/test/common.sh` ends with

```bash
trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
```

so sourcing it installs that trap **inside the check's shell**. Its handler prints a line beginning
`INTERNAL_ERROR` and exits. The platform's `main.sh` grades the **last** line of stdout+stderr, so a
second line after the verdict discards the verdict, the run is recorded as `evaluated: false`, and
the learner sees an empty "Test Case Results:" panel with no rows. That voided a whole collection of
module-3 labs on 2026-08-26.

### What was wrong here

```
$ grep -c 'trap - ERR' test-cases/scripts/script_0*.sh     # all five: 0
$ grep -c 'exec 2>>'   test-cases/scripts/script_0*.sh     # all five: 0
$ cat test-cases/scripts/common.sh
print_status() { echo "RESULT:$1 | $2"; }                  # and nothing else
```

The stub had no `jq`, no `handle_internal_error`, and no ERR trap, so it was strictly easier to
satisfy than the real helper. That is why nine sweeps had never seen the problem.

### What was done

- `test-cases/scripts/common.sh` replaced with the **faithful replica**, copied byte-for-byte from
  `03-agentic-ai-systems/vm-labs/caldon-wire/test-cases/scripts/common.sh` (verified with `diff`:
  identical). It emits one line of JSON via `jq -n`, defines `handle_internal_error` that exits, and
  installs the ERR trap.
- The generator's shared preamble now carries `trap - ERR`, `set +eE` and `exec 2>>"$ERRLOG"`,
  patched in `gen_tests.sh` and regenerated, so `build.sh`'s "preamble identical across all five"
  assertion still holds. The comments are written out in full sentences (caldon-wire's lost the
  backticked code inside two of those lines during generation).
- `build.sh` now refuses to ship a check missing any of the three lines.

### An honest finding: on this pack the bug was latent, not live

The brief expected a live production bug. Measured, it is not live **here**, and the reason is worth
recording because it is fragile rather than safe.

An ERR trap set at top level is **not inherited into a shell function** unless `errtrace` is on:

```
$ bash -c 'trap "echo TRAP_FIRED" ERR; f(){ echo hello | grep -q zzz; echo after; }; f; echo end'
after
end
$ bash -c 'set -E; trap "echo TRAP_FIRED" ERR; f(){ echo hello | grep -q zzz; echo after; }; f; echo end'
TRAP_FIRED
after
end
```

Every one of this pack's checks does all of its work inside a `Test0N()` function, so the platform's
trap could not reach any of its guards. Removing `trap - ERR` and `set +eE` from `script_01.sh` and
re-running changed nothing, on the passing path **and** on a failing path (the starter stubs still
scored 0/50 with five real diagnostics).

Which shapes fire at all, measured:

```
[ -f /nonexistent ]                     as a statement   ERR fires
[ -f /nonexistent ] && { echo body; }   condition false  ERR does NOT fire
guard || echo ...                       guard returns 1  ERR does NOT fire
echo hello | grep -q zzz                on a miss        ERR fires
a function returning 1, called bare                      ERR fires
if [ -f /nonexistent ]; then ... fi                      ERR does NOT fire
```

The pack currently uses only the safe shapes. It is one edit away from not doing so, which is
exactly why the three lines stay in.

### Negative control, as required

`script_01.sh` with both lines removed **and** the non-zero command moved to top level, which is
where the platform's trap is genuinely reachable:

```
$ bash test-cases/scripts/script_01.sh 2>&1
{ "status": "success", "message": "An MCP client handshook with server.py over stdio and found ..." }
INTERNAL_ERROR: An error occurred at line 466: 'grep -q ZZZNOMATCH "$LAB_DIR/server.py"' exited with status '1'
```

The verdict is printed and then thrown away. Through the fixed harness:

```
  [!!!!] UNPARSEABLE script_01.sh   1s
         the last line of this check output is not a verdict, so the portal
         would report this submission as having NO TEST CASES AT ALL - not a
         zero, an empty results panel. Last line was: INTERNAL_ERROR: An error occurred at line 466: ...
  [!!!!] script_01.sh wrote 2 line(s) to stdout (want 1) and 0 to stderr (want 0);
         the judge grades the last line of the two combined
```

With `trap - ERR` restored and the same injected command still in place:

```
$ bash test-cases/scripts/script_01.sh 2>&1
{ "status": "success", "message": "An MCP client handshook with server.py over stdio and found ..." }
```

One line. `./gen_tests.sh` then restored `script_01.sh` byte-identical to its pre-control state
(`diff` clean).

### `run-all.sh` now grades the way `main.sh` does

It takes the **last** line of the captured output, parses it as JSON, reads `.status`, and has a
loud `[!!!!] UNPARSEABLE` branch whose text says the portal would report no test cases at all. The
legacy `RESULT:` shape is still gradeable but only from the last line, so the harness can never be
laxer than the judge. It also asserts, from the same single run, that each check writes **exactly
one** line to stdout and **zero** to stderr, on the pass path and the fail path alike. Observed:
`checks whose streams were not one clean stdout line: 0` for every candidate in the matrix.

---

## 2. Check order, and why partial credit is a prefix

`main.sh` breaks at the first failing case. Partial credit is therefore a **prefix** of the five
checks, not a per-theme sum.

The order is fundamental to advanced, and it is the right order for that reason: check 1 asks
whether the server speaks MCP at all, 2 whether its tools do real work, 3 the resource, 4 the
prompt, 5 the whole client and the loop. A learner's prefix therefore tracks how far they have
actually got, and a learner who has written nothing gets a diagnostic about the handshake rather
than about an agent loop they have not reached. Nothing in checks 2 to 5 can pass while check 1
fails, so no information is lost by stopping.

Measured both readings (section 9), and `validation/permutations.sh` row 11 asserts them.

---

## 3. The setup script: pins, tools and races

**Version pins are part of the contract here.** Confirmed on the installed 1.9.4 by running a
signature check rather than from memory:

```
FastMCP.tool      (self, name=None, description=None, annotations=None)
FastMCP.resource  (self, uri, *, name=None, description=None, mime_type=None)
FastMCP.prompt    (self, name=None, description=None)
FastMCP.add_tool  (self, fn, name=None, description=None, annotations=None)
FastMCP.run       (self, transport: Literal['stdio','sse','streamable-http'] = 'stdio', ...)
mcp.server.fastmcp.prompts.base exports UserMessage, AssistantMessage, Message, ...
ClientSession.call_tool     (self, name, arguments=None, read_timeout_seconds=None, ...)
ClientSession.read_resource (self, uri: pydantic.networks.AnyUrl)
ClientSession.get_prompt    (self, name, arguments: dict[str,str] | None = None)
```

Every API form the statement and the reference use exists with those names. `read_resource` really
does demand an `AnyUrl` rather than a `str`, which the statement now says explicitly.

**Fallback rung, corrected.** It was `"mcp<2" "pydantic-settings<2.15" "openai"`. `openai` was
unbounded, so a future major could move `chat.completions.create` under the learner. Now
`"mcp>=1.9,<2" "pydantic-settings<2.15" "openai>=3,<4"`, and `build.sh` asserts all three pins and
all three bounds. The reasons are written beside the rung: `mcp` 2.x removed
`mcp.server.fastmcp`, so every correct 2.x-style solution fails at import; `pydantic-settings` 2.15
warns on every `FastMCP` construction, and on a stdio server that warning lands on the stderr the
client is reading.

The statement's Environment section now states which `mcp` API surface is available, so a learner
who knows the 2.x layout is told rather than silently broken.

**`curl` and `jq` moved to the foreground.** They were installed only in the detached deps job. Both
are load-bearing: the platform's own `print_status` builds its line with `jq -n`, and every verdict
this lab emits interpolates `jq -r` output. Installed now in phase 1, capped and non-fatal, and
still re-run in the detached job as an idempotent retry. `build.sh` asserts both appear before the
phase-2 marker. The service health probe still uses `python3`/`urllib`, so provisioning does not
depend on the new step succeeding.

**No check uses "curl and jq exist" as a proxy for the install having finished.** `ensure_deps`
gates on the `deps.ready` sentinel, falls back to an import probe only after the bounded wait, and
then checks the two tools separately. A missing library is reported as an environment fault naming
its install log and saying plainly that the learner's code is not at fault:

```
This VM is not ready to be graded: mcp is not installed, so the check could not run your code at
all. Nothing is wrong with server.py or solution.py. The install log is
/var/log/larkspur-lab/pip.log and /var/log/larkspur-lab/deps.ready appears when the install
finishes; wait for that file and submit again.
```

**Four `pipefail` races fixed.** `build.sh` runs under `set -euo pipefail` and had
`unzip -Z1 "$z" | grep -q ...` three times; the setup template (also `pipefail`) had
`python3 -m pip install --help | grep -q break-system-packages`. In each case `grep -q` exits on its
first match, the producer takes SIGPIPE, and `pipefail` reports the pipeline as failed even though
the match succeeded. This raced about one run in five on a module-3 pack. All four now capture the
output first and match against a here-string.

---

## 4. Timing, and the stray-process column

Per-check wall time with the service up and the reference in place, from
`/tmp/larkspur_timing.log`:

```
script_01   1s
script_02   1s
script_03   2s
script_04   1s
script_05   2s        slowest check across the whole matrix: 3s
```

TC05 is the slow one: it is the only check that starts two interpreters (the probe plus the MCP
server the learner's client spawns), makes five round trips to the endpoint, and now also drives the
client through the rest of its surface. Adding that walk cost about 1s and did not change the
slowest-check figure materially (2s to 3s across candidates).

Budget arithmetic is unchanged and still holds. The paths are mutually exclusive, so the worst case
that reaches the learner's code is `~1s + RUN_BUDGET(45) + 4 x CURL_MAX(5)` = about **66s**, and the
worst case that does not is `DEPS_WAIT(20)` or `SVC_WAIT(12)` plus a report. Both are inside the
portal's ~2-minute per-test cap. `MCP_WAIT=10` bounds the grader's own protocol reads, which is what
turns a server that starts and never answers into an 11-second diagnosable failure rather than a
45-second one:

```
$ bash test-cases/scripts/script_01.sh   # against _envprobe_hang_server.py
exit=0 elapsed=11s stdout=1 stderr=0
server.py did not advertise its three tools correctly over MCP: ... Error from your server:
... <- McpError: Timed out while waiting for response to ClientRequest. Waited 10.0 seconds..
Your server printed nothing on its stderr, so there is no traceback to show: either it never
started, or it started and never answered. Check that server.py ends in mcp.run(transport=stdio)
under an if __name__ guard, and that nothing in the file blocks or writes to stdout before that -
stdout is the protocol channel, so a stray print corrupts it.
```

**The stray-process column was a flaky harness, and is fixed.** The previous record claimed three
sweeps agreed row for row. The SCORE column did. The STRAYS column did not:

```
pass 1:  _cheat_bypass strays=0   _defect2 strays=0   alt1 strays=0   alt5 strays=2
pass 2:  _cheat_bypass strays=2   _defect2 strays=1   alt1 strays=1   alt5 strays=1
```

Cause: `strays()` was `pgrep -f 'server\.py'`, which counts **any** process on the host whose
command line contains those characters, including an unrelated authoring probe in another terminal
(which is precisely what was running). It is now a **delta** against a snapshot taken before the
loop, so it reports what this run leaked and nothing else. A prefix match on the work directory was
tried first and rejected: TC01 to TC04 launch the server by absolute path inside `larkspur_work_*`,
but TC05 launches it through the learner's own client with a relative `server.py`, so no single
pattern identifies all of them. After the fix, `strays=0` on every row of both final passes.

This matters beyond tidiness: a non-deterministic column in the validation record is
indistinguishable from a flaky grader, and the brief is right that averaging it would have been the
wrong response.

---

## 5. The statement rewrite, and the two required checks on it

`problem-statement.md` was rewritten end to end, retitled to the portal title **The Model Context
Depot**, and restructured into Scenario / What you will build / Environment / Project layout / The
pieces you are given / The data / Interface contract / Your tasks / Run and verify locally / Before
you submit.

- `grep -c '—' problem-statement.md` = **0**.
- `grep -c '^|' problem-statement.md` = **0**.
- **"How you are graded" is gone**, along with the five check descriptions and the points
  arithmetic. `build.sh` now fails if it comes back, or if the text leaks `10 points`,
  `5 automated checks`, `all-or-nothing` or `TC01`.

**The two-file split is the highest-value clarity work in this pack**, because `server.py` and
`solution.py` are both graded and the sibling packs have only one graded file. The Project layout
block is now a literal tree with an inline marker on every entry, and each of the two learner files
carries three lines saying what it is, that it is never imported by the other, and how it is
reached. Both stub docstrings were rewritten to match, each naming the tasks that belong to it.

**Fact preservation.** 54 grader-visible literals were extracted from `test-cases/scripts/*.sh` and
`app/` and checked against the new text: callables, argument names, file names, the project path,
the endpoint URL and port, the tool and prompt names, the resource URI, the schema keys the checks
assert (`inputSchema`, `"object"`, `required`, `"type": "function"`, `"parameters"`), the tool-message
keys (`"role": "tool"`, `"tool_call_id"`, `"content"`), the kit surface, the table names, and the
version strings. **Missing: none.**

**Publish-leak check.** Every graded value the statement must not contain is absent: the graded
question, the graded answer, the blocked table name, the probe's extra column, the grader header
key, the grader route prefix, the audit path. (`grep` reports the word "stops" twice, both as the
verb in "until it stops asking".) `_cheat_hardcode` still scores exactly 10/50 after the rewrite,
unchanged, and the residue is explained in section 6.

**Every "must" has a check.** All 40-odd occurrences of *must / required / do not / never* were
traced to a check. Three had none, and were demoted from rules to guidance rather than left stated
and ungraded:

- cleanup happening when the `async with` body raises (not observable to any check);
- two clients in one process not interfering (nothing builds two);
- reaching the server through `TransitMCPClient` rather than a second session opened inside the loop
  (a second session would still put the work in a child process, which is the rule that is graded,
  and that rule is stated immediately above it).

Two were **promoted to real checks** instead of demoted, because they are the lab's stated objective
(section 6): `MAX_MODEL_TURNS` being a whole number in 1..8, and `mcp_tools_to_openai` producing the
documented shape.

One contract line **disagreed with the code** and the code was corrected to match the statement: the
statement promised the answer is compared "after stripping surrounding whitespace", but the check
compared a value that had only its trailing newline removed by command substitution, so a leading
space would have failed a correct solution. The probe now returns `produced.strip()`.

**Boundary arithmetic is now stated**, which it was not. `MAX_MODEL_TURNS` counts model calls, not
tool calls; one pass of the loop is one `chat.completions.create`; a question needing `k` tool steps
costs `k + 1`; at the ceiling the loop makes no further call; questions here need up to four tool
steps, so a ceiling below 5 cuts one short and it must also be 8 or less. An undefined counting noun
in a cap is how a correct learner loses ten points, and this one had no unit at all.

Also corrected: the worked example for `get_table_schema("routes")[0]` claimed
`'nullable': False`. The real value is `True` (`route_id INTEGER PRIMARY KEY` is not declared
`NOT NULL`). Verified by running it. `check_local.py` now also prints the `mcp_tools_to_openai`
output, so the statement's claim that it "exercises every method the contract names" is true.

---

## 6. Hardcoding, leaks, bypass and grader-side prose

**Grader side: clean.** No check requires particular prose from the learner.

```
$ grep -n 'grep -q' test-cases/scripts/script_0*.sh | grep -v 'command -v\|pgrep\|print_status'
(no output)
```

Every assertion is structural, over JSON the probe emits. The one content match that could look like
prose matching is TC03's `(?<![0-9])<count>(?![0-9])` next to a table name on the same line, and both
halves of that rule are now stated in the statement, including that the number must not be adjacent
to other digits.

**Learner side: clean, with one removal.** No magic numbers, no fixture tables, no keyword lists
lifted from the grader's or the service's own strings in the reference or any alternative. One dead
configurability found and removed: `alt5_solution.py` honoured a `LARKSPUR_SERVER_SCRIPT`
environment override that nothing sets, no grader reads and the statement never mentions, the same
pattern as `REDCLIFFE_STORE`. Now a plain `["server.py"]`, and the unused `import os` went with it.

**Bypass, re-confirmed after every change.** `_cheat_bypass_server.py` is a plain module that exits
when run; `_cheat_bypass_solution.py` hand-writes the tool schemas and executes every requested tool
**in its own process**. Its answer is right and its tool sequence is right, and it scores **0/50**.
The properties the checks key on:

- **A separate process.** `transit_kit.audit` records the pid of whatever read the database. TC05
  requires the three operations to appear against a pid that is *not* the loop's, and requires the
  set against the loop's own pid to be empty. An MCP server is a separate process by construction,
  so this cannot be faked without actually running one.
- **The protocol handshake.** TC01 to TC04 each complete a real `initialize` against the learner's
  file. A file that is not a working MCP server never gets that far.
- **The audit record**, as above, plus the endpoint's own view of whether the tool declarations it
  was sent were usable.

**Verified against all five alternative server/solution pairs**, including the ones built with the
library's own constructors rather than by hand: `alt3` registers with `add_tool()` and calls the
resource and prompt decorator factories directly, `alt5` loops over a
`(name, description, function)` registry and returns a JSON resource, `alt4` uses
`Annotated[str, Field(...)]` parameters with `async def` tool functions and dispatches with
`asyncio.gather`, `alt1` uses bare decorators with docstring descriptions, `alt2` adds two extra
tools, a templated resource and a second prompt. All five score 50/50, so the mechanism assertions
do not depend on how the server was assembled.

**`_cheat_hardcode` keeps 10/50, documented rather than papered over.** Its server genuinely
advertises three described tools with the right required parameters, a resource at the required URI
and a prompt with the right argument, which is the entirety of what check 1 claims to verify. The
moment it is asked to *do* anything, checks 2 to 5 all fail. Widening check 1 to catch it would mean
folding another theme into that slot. Note also that its client returns the correct answer for the
graded question from a constant table and still scores nothing on check 5, because the structural
assertions do not care that the string is right.

**Two requirements promoted to checks.** `MAX_MODEL_TURNS` and `mcp_tools_to_openai` were stated in
the contract but never exercised: TC05 only called `run_agent_loop`, which reaches the conversion
indirectly and the ceiling not at all. Both are now asserted inside TC05's existing interpreter
start, so no extra process cost. All candidates already satisfied them (`MAX_MODEL_TURNS` is 6, 7 or
8 across the alternatives), so the matrix did not move.

**And a regression this caused, recorded because it is the lesson.** The same addition first drove
`TransitMCPClient` through its full surface and asserted *content*: that the resource carried the
table names and that the prompt carried the argument. `_defect3` (a prompt that ignores its
argument) immediately dropped from 40/50 to **30/50**, failing check 4 *and* check 5. That breaks the
rule that each defect loses exactly the theme it breaks, so the walk was rescoped to **relay only**:
each method must reach the server and hand back non-empty protocol data, and whether the content is
*correct* stays with checks 3 and 4. `_defect3` returned to 40/50. Tightening a check is the most
common way to break a valid path, and here it broke a defect probe's precision instead.

---

## 7. Failure diagnostics

The portal shows the learner the verdict message and nothing else, so every failure path was judged
by one question: can a learner fix their code from this line alone?

**The empty-log dead end.** The pack had
`report "failed" "$1 - nothing was produced; see $(probe_log "$TC").err$(trace_hint)"`. Two problems
at once: a learner module that only defines functions exits 0 having printed nothing, so that file is
**empty** and the message names evidence that does not exist; and `trace_hint()` is a no-op stub in
the shipped configuration, so `$(trace_hint)` contributed nothing to the sentence it was spliced
into. Every hit from
`grep -n 'learner_log\|_out_\|\.log' test-cases/scripts/*.sh` was swept, not just the one.

Now `log_tail` (last 3 lines, newlines flattened to ` | `, capped at 280 characters) and
`run_evidence` fold the evidence into the verdict and keep the `[full output in <path>]` pointer
*after* it. The empty case says so in as many words and names the likely cause. The dead
`$(trace_hint)` splices are gone.

**This pack's extra wrinkle, and it was real.** A learner's MCP server that fails to start writes
its traceback to the *server's* stderr, not the client's log. Before the fix, TC01 against a server
with a module-scope `import numpy` said only:

```
Error from your server: ExceptionGroup: unhandled errors in a TaskGroup (1 sub-exception)
```

The cause was two levels down in the exception group, and the traceback was on the child's stderr,
which `stdio_client` forwards to the parent (`errlog` defaults to `sys.stderr`) and `run_probe`
captures. Neither reached the learner. Two fixes:

- every probe now unwraps exception groups (`describe()` walks `.exceptions`);
- `server_said` splices the tail of the server's own stderr into the verdict, but only when the
  probe actually reported an error, so a working server does not have its ordinary log lines quoted
  back at a learner whose failure was an assertion.

After:

```
server.py did not advertise its three tools correctly over MCP: the server did not complete an MCP
handshake. The tools it did advertise were []. Each of list_tables, get_table_schema and
execute_sql needs a non-empty description, an object input schema, and exactly its own required
parameters (none, table_name, query). Error from your server: ExceptionGroup: unhandled errors in a
TaskGroup (1 sub-exception) <- ExceptionGroup: ... <- McpError: Connection closed. What your server
printed on its stderr: import numpy # noqa: F401 - deliberately absent from the lab environment |
^^^^^^^^^^^^ | ModuleNotFoundError: No module named 'numpy'
```

A second bug was found and fixed while testing this: the new client walk referenced the `solution`
module even when `import solution` had failed, so a learner whose module did not import got
`error from your client=NameError: name 'solution' is not defined` on top of the real cause. The
walk is now guarded on the import having succeeded, and reports
`solution.py could not be imported`.

**Verdicts now lead with a plain sentence.** TC05's failure message was 400+ characters of
`key=value`. It now names the first requirement that did not hold, in the order a learner should fix
things in (where the work ran, then what was declared, then the bookkeeping, then the answer), and
keeps the observed values in a bracket after it:

```
The database was read inside the process running your loop. Every tool must be executed by the
server through the MCP session, never by calling the transit_kit functions from inside
run_agent_loop.  [observed: answer='...' expected='...', turns=5 of 5-6, MAX_MODEL_TURNS=8, ...]
```

**`jq` interpolation degrades.** Every interpolated field now defaults to a readable word
(`unknown`, `none`, `absent`, `nothing`) via `probe_json` / `trace_json`, and numeric fields go
through `trace_num` so a word where a number belongs cannot make bash report an integer error
instead of scoring the check.

**Guard messages name the fix, and say when the learner is not at fault.** The dependency guard, the
service guard and the expected-value guard all now say plainly that nothing is wrong with
`server.py` or `solution.py`, and name the log or the command to run. This one showed up during
testing for real, when a stale service was listening on a probe port:

```
This VM is not ready to be graded: the check could not read the expected result from the operations
endpoint on http://127.0.0.1:9523, so it never got as far as running your code. Nothing is wrong
with server.py or solution.py. Confirm the endpoint answers with: curl -s http://127.0.0.1:9523/health
```

---

## 8. Ownership: prevention and repair

### The hazard, measured

`mcp.client.stdio` builds the child environment as

```python
env=({**get_default_environment(), **server.env} if server.env is not None
     else get_default_environment())
```

and `get_default_environment()` returns a fixed whitelist that `PYTHONDONTWRITEBYTECODE` is not on:

```
{'HOME': ..., 'LOGNAME': ..., 'PATH': ..., 'SHELL': ..., 'USER': ...}
```

Explicit `env=` entries are merged over it, so the checks' own probes (which pass
`PYTHONDONTWRITEBYTECODE: "1"`) are safe. The **learner's** client is not: it passes `env=None`, so
its server child writes bytecode into whatever directory it started in. Under grading that is root.
Measured, running TC05 with the probe in the project as it was:

```
$ find <project> -name '*.pyc'
transit_kit/__pycache__/audit.cpython-313.pyc
transit_kit/__pycache__/db.cpython-313.pyc
transit_kit/__pycache__/sql_tools.cpython-313.pyc
transit_kit/__pycache__/client_factory.cpython-313.pyc
transit_kit/__pycache__/endpoint.cpython-313.pyc
transit_kit/__pycache__/__init__.cpython-313.pyc
6
```

### The repair was unreachable

Every check had `case "$LAB_DIR" in /home/user/*) chown -R user:user "$LAB_DIR"`, and every local
harness runs with `LAB_DIR=/tmp/...`. So the one line written to stop a learner being locked out of
their own project never executed in any environment that tests it. It is now gated on whether a
learner account exists, which is the actual condition:

```bash
hand_project_back() {
    id -u user >/dev/null 2>&1 || return 0
    case "$LAB_DIR" in
        /*/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 || true ;;
    esac
}
```

The `case` guard is kept so an unset or empty variable can never let the chown reach `/`. `build.sh`
asserts both the `chown` line and the `id -u user` gate in all five checks.

### Prevention, which is the part that actually fixes it

No check runs anything inside the learner's project any more. Each one creates its own `WORK`
directory under `/tmp`, copies the project into it (`stage_project`), and runs the probe there. The
probe source, the probe JSON, the seeded probe databases and the project copy all live there, and
`WORK` is removed from the `EXIT` trap. `kill_stray_servers` was extended to accept a child whose
working directory is `WORK` as well as one whose working directory is the lab, because the probes now
run against the copy. `build.sh` asserts `stage_project` in all five checks.

Measured, same check, before and after:

```
BEFORE (probe runs in the learner project):   6 bytecode files in the project
AFTER  (probe runs in the check work dir):    0 bytecode files in the project
leftover work directories after the run:      0
```

### Asserting the invariant, not just the symptom

`find /home/user -user root` cannot see this class of bug when provisioning pre-creates the file and
root's write lands in place, and this pack's setup **does** pre-create both `__pycache__`
directories. So `validation/permutations.sh` gained row 10, which asserts the invariant itself and
needs no root:

1. the "learner" writes `NOTES.txt` and runs `import solution` once, as they would before submitting;
2. the project is fingerprinted: every file's path, byte size, mode string, and a digest of the
   concatenated contents;
3. grade, fingerprint, grade again, fingerprint again, and require **both** unchanged;
4. count the bytecode files grading added, and require **zero** (the learner's own are theirs);
5. delete `NOTES.txt`, grade a third time, and require grading does **not** recreate it, which is
   what would show the checks bootstrapping state into the project.

Observed, mode LOCAL:

```
[10] grading does not touch the learner project
      (the learner own run left 7 bytecode files, which are theirs)
      ok   score, first grading               50
      ok   score, second grading              50
      ok   project unchanged by grading       yes
      ok   project unchanged by regrading     yes
      ok   deleted file not recreated by grading yes
      ok   bytecode files added by grading    7
      skip files not owned by user            no lab user off-VM; the invariant above is what can be proven here
```

Also removed: the setup script's comment claiming the pre-created `__pycache__` directories were the
defence against this. They are now belt and braces, and the comment says so.

---

## 9. Score and ordering matrices

### `./sweep.sh`, run twice after the last edit

**Every SCORE row and every STRAYS row is identical across both passes.** The only column that
differed is `WORST`, the wall-clock reading, and one of those readings needs recording rather than
smoothing over (see the note under the table):

```
CANDIDATE                  SCORE    WORST   FAILED
__stub__                   0/50     2s      script_01 script_02 script_03 script_04 script_05  [strays=0]
__reference__             50/50     3s      -                                                  [strays=0]
_cheat_bypass              0/50     2s      script_01 script_02 script_03 script_04 script_05  [strays=0]
_cheat_hardcode           10/50     2s      script_02 script_03 script_04 script_05            [strays=0]
_defect1                  40/50     2s      script_01                                          [strays=0]
_defect2                  40/50     2s      script_03                                          [strays=0]
_defect3                  40/50     2s      script_04                                          [strays=0]
_defect4                  40/50     3s      script_02                                          [strays=0]
_defect5                  40/50     3s      script_05                                          [strays=0]
alt1                      50/50     2s      -                                                  [strays=0]
alt2                      50/50     2s      -                                                  [strays=0]
alt3                      50/50     2s      -                                                  [strays=0]
alt4                      50/50     2s      -                                                  [strays=0]
alt5                      50/50     2s      -                                                  [strays=0]
```

Two further passes were run after the last edit (four post-fix sweeps in total). All four agree on
the candidate, score, failed-checks and strays columns; the last two reported every candidate at 1 to
2s.

**The one timing anomaly, stated rather than smoothed.** In the second of the four passes the
reference row reported its slowest check as **766s** while still scoring 50/50 and leaving no
strays. A check that really ran for 766s would be killed by the portal and score zero with no
message, so this was chased rather than averaged away:

- it did not reproduce in **five** consecutive reference runs immediately afterwards, every one
  50/50 with a slowest check of **2s** and per-check times of 1 to 2s, nor in either of the two
  further full sweeps, where the slowest figure on any row was 2s;
- the score, the stray count and the per-check log were all normal in the anomalous run itself, so
  the check did its work and passed;
- `pmset -g log` shows this host taking idle-sleep assertions and releasing them inside the window
  the unattended second pass ran in (483 sleep/wakes since boot). `SECONDS` is wall clock, so a host
  suspend of about 12 minutes during one check produces exactly this reading for work that took a
  second.

Best explanation is therefore a suspended authoring host inflating a wall-clock measurement, not a
slow check. It is **not** fully excluded off-VM, so it is named in section 10 as something the first
real VM run should confirm. Two things make it low risk in production: the VM does not idle-suspend
mid-grading, and every wait inside a check is bounded by one of `DEPS_WAIT`, `SVC_WAIT`, `CURL_MAX`,
`RUN_BUDGET` or `MCP_WAIT`.

Related, and worth knowing when reading any timing number from this host: **neither `timeout` nor
`gtimeout` exists here** (`command -v` for both: absent), so `run_bounded` always takes its pure-bash
watchdog path locally. On the target image coreutils `timeout` is present and takes the other branch.
The fallback is the one that has been exercised; the `timeout` branch has not.

The shipped starter (`app/server_stub.py` + `app/solution_stub.py`) scores 0/50 with a real
diagnostic per check, each naming the starter: check 1 reports the three tools are not advertised and
that the advertised list was `[]`, check 5 reports
`error from your loop=NotImplementedError: Task 6: run the loop`.

### Portal-order scores, measured

`main.sh` stops at the first failing case, so these are the numbers a learner actually sees. Measured
by stopping at the first non-success verdict:

```
CANDIDATE          PORTAL   ALL FIVE
reference            50       50
alt1 .. alt5         50       50   (each)
_defect1              0       40   fails check 1
_defect4             10       40   fails check 2
_defect2             20       40   fails check 3
_defect3             30       40   fails check 4
_defect5             40       40   fails check 5
_cheat_hardcode      10       10
_cheat_bypass         0        0
starter stubs         0        0
```

The 40/50 figures elsewhere in this pack are the all-five column, which is the right number for
judging that each defect loses only its own theme. The wording in `README.md` and the instructor
guide has been corrected to say which is which, rather than the sweep data being deleted. `SOLUTION.md`
no longer carries scores at all: all of it now lives in this record, in section 12.

### Environment probes

Never graded (the sweep glob skips the `_envprobe` prefix), run individually:

```
_envprobe_hang_server.py     a server that starts and never answers
                             TC01 fails in 11s, one clean stdout line, bounded by MCP_WAIT
_envprobe_numpy_server.py    module-scope import numpy in server.py
                             fails all five; the verdict now carries ModuleNotFoundError
_envprobe_numpy_solution.py  module-scope import numpy in solution.py
                             fails TC05 only; the verdict names the module and says the
                             client could not be imported
```

The last two are the regression test behind the Environment section: numpy is absent, and where the
stray import lands decides whether it costs all five checks or one.

### `./validation/permutations.sh`

**28 assertions ok, 0 failed, 7 skipped** (mode LOCAL).

```
[1] both files written, graded once          score 50   strays 0   learner can still work: yes
[2] nothing written (starter stubs)          score  0   strays 0
[3] server written, client still a stub      score 40
[4] client written, server still a stub      score  0
[5] solution.py missing from disk entirely   score 40   strays 0
[6] partial grading (killed after check 3)   score 30              learner can still work: yes
[7] graded twice in a row                    50 then 50, 6s then 7s
[8] graded first, then learner works, graded  0 then 50            learner can work in between: yes
[9] data/transit.db deleted by accident      score 40   strays 0   no crash
[10] grading does not touch the project      50, 50, fingerprint unchanged twice, 0 pyc added,
                                             deleted file not recreated
[11] portal scoring is a prefix              defect in check 1: 40 across five, 0 in portal order
                                             defect in check 5: 40 in portal order
```

Also verified: `./gen_tests.sh && ./build.sh` run twice in a row leaves
`setup/scripts/setup_script.sh` and all five checks byte-identical, so the generated artefacts are
stable and the shipped zips match the sources.

`grade()` in that harness was reading the *first* `RESULT:` line, which stopped matching once
`common.sh` became the faithful JSON replica. It now parses the last line as JSON, and takes a
`portal` mode that stops at the first failure.

Row [4] is the dependency ordering worth stating out loud: a perfect client scores nothing without a
server, because four of the five checks are conversations *with* the server. Row [9] is the soft
edge: a learner who deletes their database keeps 40/50 and loses check 5, and re-running setup
restores the file.

The seven skipped assertions are the ownership columns; see section 10.

### `./build.sh`

Clean end to end, `dist/` restaged:

```
Setup.zip     scripts/ scripts/setup_script.sh data/
TestCase.zip  scripts/ scripts/script_01..05.sh data/
```

`TestCase.zip` carries `scripts/` **and** `data/`, and does not smuggle `common.sh`, `run-all.sh` or
`.DS_Store`. New guards: the three judge-fidelity lines, the `id -u user` gate, `stage_project`,
`run_evidence`, all three pins and all three fallback bounds, `curl` and `jq` in the foreground, and
the statement having no em dash, no grading section and no leaked check structure.

---

## 10. What could not be validated off-VM, stated plainly

0. **The `timeout(1)` branch of `run_bounded`, and the 766s timing reading.** This host has neither
   `timeout` nor `gtimeout`, so every local run took the pure-bash watchdog path; the
   `"$TO" -k 5 "$RUN_BUDGET"` branch that the VM will take is unexercised. Related: the single 766s
   wall-clock reading in section 9 is best explained by the authoring host suspending, and could not
   be reproduced in five further runs. **On the first VM run, read `/tmp/larkspur_timing.log` after
   grading and confirm every check is in single-digit seconds**, and that
   `command -v timeout` resolves.

1. **The ownership columns.** `find /home/user/larkspur-transit ! -user user | wc -l` = 0 needs a
   `user` account and a root grader. This host has neither, so those seven assertions print
   `skip ... no lab user off-VM`. What **was** proven here: the write happens (6 files, measured);
   the prevention stops it (0 files, measured); the project is byte-and-metadata identical after two
   grading runs and grading resurrects nothing (row 10, measured); and the `chown` line plus its
   `id -u user` gate are present in all five checks (asserted by `build.sh`). What is unproven is
   only that `chown -R user:user` succeeds as root on the image.

   **First thing a real VM run must confirm:** run `validation/permutations.sh` as root with
   `/home/user` present, and check that row 1 and row 10 both report `files not owned by user 0`
   **and** `learner can still work yes`. Then repeat after killing a grading run before check 5, which
   is the ordering a later check's chown would otherwise mask.

2. **`kill_stray_servers` has never been seen to fire.** It reads `/proc/<pid>/cwd` and
   `stat -c %U /proc/<pid>`, neither of which exists on macOS, so it is a verified no-op here. Its
   Linux invocations are correct GNU forms and its conditions are right, but the sweep is unproven.
   Off-VM the authoring harness reaps strays itself, which is why the hang probe leaves nothing
   behind locally. On the VM, confirm with `pgrep -f 'server\.py'` after a run that was killed at
   `RUN_BUDGET`.

3. **The judge itself.** `trap - ERR` and `exec 2>>` were validated against the faithful replica of
   `common.sh`, not against the platform's own file. The replica is byte-identical to the copy taken
   from a real lab VM (`diff` clean against caldon-wire's), so this is as close as it gets without a
   VM, but the `INTERNAL_ERROR` line and the empty-panel symptom were reproduced against the replica
   rather than observed on the portal. Section 1 also records that on this pack the trap is
   **latent** rather than live, because every check body sits inside a shell function and `errtrace`
   is off; a real VM run should still be checked for a clean single-line verdict per check.

4. **Provisioning wall clock, and the new foreground `curl`/`jq` install.** `setup_script.sh` needs
   root, apt, `/opt` and `systemctl`. Its syntax is checked, every inlined file round-trips
   byte-for-byte, and every network step is `cap`-bounded under a 95s internal deadline that prints a
   summary and exits 0 rather than being killed. The `curl`/`jq` step is new in this pass and adds
   one bounded apt call to the foreground (about 7s with `--no-install-recommends` on a warm index,
   capped at 45s, non-fatal). **Confirm the reported `total setup time` on the image**, and that the
   summary still says the lab is ready.

5. **The apt and get-pip ladders.** No apt on this host. The rung order and the
   `--no-install-recommends` choice are carried over from earlier measurements, not re-measured.

6. **PEP 668, the `~/.local` `.pth` bridge, and the `python` symlink.** All conditional on image
   properties this host does not have. Each is guarded so a wrong assumption degrades rather than
   aborts. The `pip install --help` probe behind the PEP 668 branch was changed in this pass to
   avoid a `pipefail` race, so it is worth confirming the `break-system-packages` flag is still
   picked up on the image.

7. **The portal itself:** zip acceptance, the Max Score field, the front end's status-poll window.
   Unchanged in shape from the packs that already ship.

---

## 11. Reproducing all of it

```bash
python3.13 -m venv /tmp/lkvenv
/tmp/lkvenv/bin/python -m pip install --only-binary=:all: \
    "mcp==1.9.4" "pydantic-settings==2.14.0" "openai==3.1.0"

cd assessments/02-advanced-ai-agents/vm-labs/larkspur-transit
./gen_tests.sh && ./build.sh

# one candidate
PY=/tmp/lkvenv/bin/python ./test-cases/scripts/run-all.sh                  # expect 50/50

# every candidate, each on its own port and lab directory
PY=/tmp/lkvenv/bin/python PORT_BASE=9500 ./sweep.sh                        # expect the matrix above

# the ordering matrix, including the project-invariant row
PY=/tmp/lkvenv/bin/python PORT=9540 ./validation/permutations.sh           # expect 0 failed
```

Run the sweep with **nothing else running on the host**. The stray column is now a delta rather than
an absolute count, but two sweeps sharing a port range will still answer each other's health checks
and produce a green run that proves nothing.

On the VM, as root, after provisioning:

```bash
PY=python3 bash validation/permutations.sh     # mode VM - asserts the ownership columns too
find /home/user/larkspur-transit ! -user user | wc -l
pgrep -f 'server\.py'
su - user -c 'cd ~/larkspur-transit && python3 check_local.py'
```

---

## 12. What each check asserts

Moved here verbatim from `SOLUTION.md`, which is now a walk-through of the model answer only: the
grading apparatus belongs in this record and in `README.md`, not in the answer key. The candidate
scores these anchors produce are in section 9, and the stopping rule that turns them into a portal
number is in section 2.

**TC01 — advertisement.** Real `initialize` + `tools/list` over stdio. Asserts the three names are
present (extras ignored), each description is non-empty, each input schema is an object schema, the
needed parameter appears in `properties`, and `required` is exactly `[]`, `["table_name"]`,
`["query"]`. Unfakeable because a file that is not a working MCP server never completes the
handshake. Protocol reads are bounded by `MCP_WAIT=10`, so a server that starts and then hangs is a
ten-second diagnosable failure rather than a stalled test case.

**TC02 — the tools do the work, the guards hold.** The check writes a **fresh database in root's own
temp directory** — an extra `livery` column on `vehicles`, seeded row counts and capacities derived
from the check's own pid, and an extra `stops` table that exists in the file but is not on the
published allowlist — then starts the learner's server with `LARKSPUR_DB` pointing at it. It then
asserts, over one session: `list_tables` reports that database's tables; `get_table_schema` on
`vehicles` reports its real columns; `execute_sql` returns the seeded fleet total; the *existing but
unpublished* `stops` table is refused without its `stop_id` column leaking; a `DELETE` comes back as
a refusal and the trips row count in the file is unchanged when read directly afterwards; and the
session still answers a plain count after both refusals. Nothing here is answerable from memory of
the bundled database, and the `DELETE` assertion is behavioural — it reads the file, not the message.

**TC03 — the resource.** Same variant-database trick with different seeded counts.
`resources/list` must advertise `transit://overview`; `resources/read` must return a text body with,
for each table, a line carrying both the table name and that table's real row count. The layout is
free — `routes: 6 rows`, `routes -> 6`, `"routes": 6` all match — but the number has to be queried.
A hand-written overview (defect 2) reports the bundled counts and fails.

**TC04 — the prompt.** `prompts/list` must advertise `transit_analyst` with an argument named
`question`; `prompts/get` must return at least one message, and the combined message text must
contain a value the check makes up at run time. A prompt that ignores its argument (defect 3) fails.

**TC05 — the loop and the client, end to end.** One interpreter start runs the learner's
`run_agent_loop` on a question that needs **four** tool calls (`list_tables`, `get_table_schema`
twice for the join, `execute_sql`), and then drives `TransitMCPClient` through the rest of its
documented surface in the same process. These facts have to line up:

- the returned answer equals the answer the oracle computes from SQLite;
- the tools the endpoint was asked to emit match the plan, in order;
- the tool declarations were accepted on every turn — a mis-nested `parameters` stalls the walk and
  is reported as `stalled=true` rather than as a mysterious wrong answer;
- no tool result carried an unrecognised `tool_call_id`;
- the set of ids that came back equals the set of ids that went out;
- the loop took between `len(plan)+1` and `len(plan)+2` model turns, so it stopped when the model
  stopped asking;
- every one of the three database operations was recorded as having run in a process **other** than
  the one running the loop;
- **no** database operation was recorded in the loop process;
- `MAX_MODEL_TURNS` is a whole number in 1..8 (the contract fixes it; without this assertion the
  ceiling in the statement was an unenforced rule);
- `mcp_tools_to_openai` called directly returns one dict per input tool, in order, each with
  `type == "function"` and a `function` sub-dict whose `name` matches the MCP tool and whose
  `parameters` is a dict (this is the lab's stated objective, and until this was added the function
  was only graded indirectly through the endpoint's view of the request);
- and `TransitMCPClient` relays `list_tools`, `call_tool`, `read_resource`, `list_prompts` and
  `get_prompt` to the server and hands back non-empty protocol data. Deliberately **relay only**:
  whether the resource carries the right counts and whether the prompt interpolates its argument
  belong to TC03 and TC04. Asserting content here as well made one server mistake cost two themes,
  which showed up immediately as `_defect3` dropping to 30/50.

The last two are what make the MCP session load-bearing rather than decorative: an MCP server is a
separate process by construction, so a client that calls the SQL functions itself gets the right
answer and still fails. That is `_cheat_bypass`.

### The candidate roster the anchors discriminate

Reference and five alternatives at 50/50; five defects each losing exactly one theme; two cheats
near zero. The measured tables are in section 0 (all five checks run) and section 9 (portal order).

- `alt1` — bare `@mcp.tool()` / `@mcp.resource()` / `@mcp.prompt()` with no kwargs, descriptions
  from docstrings, plain annotations; client holds the two context managers by hand, no
  `AsyncExitStack`, `MAX_MODEL_TURNS = 6`, assistant message built as a manual dict.
- `alt2` — two extra tools (`count_rows`, `get_sample_rows`), a templated resource and a second
  prompt alongside the required ones, a three-message prompt; client is a dataclass over an
  `@asynccontextmanager` factory.
- `alt3` — no decorator syntax at all: `add_tool()` for the tools and the decorator factory called
  directly for the resource and the prompt; client caches the discovered tools and the loop is
  recursive.
- `alt4` — `Annotated[str, Field(...)]` parameters, `async def` tool functions; client is built on a
  `_SessionHolder` base and dispatches the requested calls with `asyncio.gather`.
- `alt5` — tools registered by looping over a `(name, description, function)` registry, resource
  returns JSON; client wraps the message list in a `_Conversation` helper.

- `_defect1_server` — `table_name` optional, so nothing is declared required → loses TC01 only
  (40/50 across all five; 0/50 on the portal, because check 1 is where it stops).
- `_defect2_server` — the overview is a hand-written constant → loses TC03 only (40/50 across all
  five; 20/50 on the portal).
- `_defect3_server` — the prompt ignores its argument → loses TC04 only (40/50 across all five;
  30/50 on the portal).
- `_defect4_server` — `execute_sql` is the provided function with the read-only guard removed, so a
  `DELETE` executes → loses TC02 only (40/50 across all five; 10/50 on the portal).
- `_defect5_solution` — tool results appended as `user` messages with no `tool_call_id` → loses TC05
  only, which is the last check, so 40/50 either way.

- `_cheat_bypass_*` — no MCP anywhere: `server.py` is a plain module that exits when run, and the
  client hand-writes the tool schemas and executes them in-process → 0/50.
- `_cheat_hardcode_*` — a correctly advertised FastMCP server whose every answer is a constant
  lifted from the worked examples, plus a client that returns a canned answer → 10/50 (TC01 only;
  see the residue note in the instructor guide).

- `_envprobe_hang_server` / `_envprobe_numpy_server` / `_envprobe_numpy_solution` — never graded
  (the sweep glob does not pick up the `_envprobe` prefix). They exist so the bounded-failure and
  missing-dependency behaviours stay regression-tested.
