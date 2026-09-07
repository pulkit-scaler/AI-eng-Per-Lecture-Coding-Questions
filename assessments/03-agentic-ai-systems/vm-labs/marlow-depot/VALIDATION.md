# `marlow-depot` — validation record

Everything below was **run**, not reasoned about. Where a number could not be
obtained on the authoring host, this file says so rather than implying it was.

Authoring host: macOS, Docker Desktop **29.6.2**, `linux/arm64` engine.
Target VM: *Alpine Docker* image, Docker **20.10.11**, Compose **v2.1.1**,
`linux/amd64`, 2 cores.

## 1. Reference solution

`./test-cases/scripts/run-all.sh`

```
SCORE: 50/50   (passed 5, failed 0)
slowest test case: 13s   (portal limit is about 120s)
```

Per-check wall clock on the authoring host: 13s, 1s, 0s, 6s, 4s.

## 2. Alternative correct shapes — all 50/50

- `alt1-purge` — one stage on `python:3.11-slim`, `gcc` installed, used and
  purged inside a single `RUN`. Image 98.1 MB. 50/50.
- `alt2-wheels` — builder runs `pip wheel` into `/wheels`, runtime installs
  `--no-index --find-links`. Image 137.1 MB. 50/50.
- `alt3-no-venv` — no virtualenv at all; the runtime copies
  `/usr/local/lib/python3.11/site-packages` and the `uvicorn` entry point out of
  the builder. 50/50.
- `alt4-split-build` — `indexer` gets its own `build:` block and an
  `entrypoint:`/`command:` split; list-form `environment:` and `env_file:`.
  50/50.
- `alt5-numeric-user` — numeric `USER 65532:65532` with no account in
  `/etc/passwd`, and a `ship.sh` that builds the release tag directly and pipes
  `docker save` to a file with `>`. 50/50.

That is five different Dockerfile and Compose shapes, plus two different
`ship.sh` shapes, all scoring full marks — the checks grade behaviour, not
layout.

## 3. Defect probes — each loses exactly its own theme

- `_defect1-no-ordering` — `depends_on: [llm]` only. **40/50, fails
  `script_01` only.** Reported: *depot-api started at ...:45.914 while the index
  build did not finish until ...:46.209*.
- `_defect2-full-base` — one stage on `python:3.11`. **40/50, `script_02`.**
- `_defect3-no-dockerignore` — `.dockerignore` containing only `.git/`, plus
  `COPY . .`. **40/50, `script_03`** (`.env`, `.venv` and `local_index` all
  found inside the image).
- `_defect4-copy-first` — `COPY . .` before `pip install`. **40/50,
  `script_04`.** The bounded rebuild is killed at 35s and reported as a
  dependency reinstall.
- `_defect5-no-save` — `ship.sh` tags but never saves. **40/50, `script_05`.**
- `_defect6-root-user` — no `USER`, no `/index` ownership. **40/50,
  `script_03`** (uid 0).

## 4. Fabrication probe

`_cheat-static-answers` replaces the API process with a hand-written responder
that returns the right `/health` numbers, the right `/whoami` fingerprint and a
correctly formatted note for the graded need, computed locally.

**30/50** — it fails `script_01`, because the adviser backend records no request
while `/match` is answered, and `script_04`, because the fabricated `/health`
cannot report the version the grader wrote into `version.txt`. The three themes
it does pass (image leanness, credential handling, release archive) were
genuinely achieved: it is the learner's real image underneath.

## 5. Ordering matrix

`./validation/permutations.sh` — **7 rows, 0 failures**:

1. nothing written → 0/50, refused in about a second per check.
2. files written, never built → 0/50, refused with the missing-image message.
3. built and running → 50/50.
4. grading killed after two checks → 20/50, and the learner can still drive
   their own stack afterwards.
5. graded a second time on the same VM → 50/50 again.
6. stack stopped but image built → 50/50 (the checks restart it).
7. `depot-api/version.txt` is back to `1.0.0` after `script_04` edited it.

## 6. Measurements the thresholds are set from

Sizes via `docker image inspect -f '{{.Size}}'` on one daemon, so they are
comparable with each other and with nothing else:

- `python:3.11` — 398 645 969
- `python:3.11-slim` — 45 856 900
- reference `marlow-depot/depot-api:latest` — 105 728 233 → **26.5 %** of the
  full base, against a ceiling of 50 %.
- `_defect2-full-base` exceeds the ceiling and also has `gcc` on its `PATH`, so
  it fails that theme twice over.

Build times, classic builder, warm base images:

- first `docker compose up -d --build` on a cold cache: **71 s**.
- rebuild after editing one line of `version.txt`: **3 s** (10 `Using cache`
  steps), against a 30 s ceiling.
- `_defect4-copy-first` rebuild: killed at the **35 s** bound. One sweep run
  recorded 183 s for this check before the bound was retuned; the bound was then
  verified to fire in isolation (`rc=137 elapsed=40` at a 40 s setting) and the
  check now reports 40 s → 35 s reliably. If a future run ever records a value
  far above the bound again, suspect the daemon rather than the script.
- indexer container, end to end: **0.55 s**. That is why `script_01` does not
  rely on the API losing a start race — it reads
  `indexer.State.FinishedAt` and `depot-api.State.StartedAt` out of the daemon
  and compares them.
- `ship.sh`: archive 101 MB, `docker save` + `docker load` + a clean-network
  bring-up: **4 s** total.

## 7. Worst-case check budgets (arithmetic, not measured)

- `script_01` 15 + 25 + 25 + 12 + 6×4 = **101 s**
- `script_02` 15 + 3×15 = **60 s**
- `script_03` 15 + 25 + 12 + 2×15 + 4×4 = **98 s**
- `script_04` 15 + 35 + 25 + 12 = **87 s**
- `script_05` 15 + 30 + 25 + 15 + 12 + 8 = **105 s**

All under the ~120 s portal cap. Observed values on a warm VM are an order of
magnitude smaller because every wait returns immediately when what it waits for
is already there.

## 8. Not settled on this host

- **Root ownership.** The checks run as root on the VM while the learner is
  `user`. `validation/permutations.sh` asserts that nothing under the project is
  root-owned after a full run and after a partial run, but on an authoring host
  with no `user` account those rows **self-report as vacuous**. Run the matrix
  **as root on a provisioned VM once** before the first cohort.
- **Architecture.** Everything above was measured on `linux/arm64`. Image sizes
  differ on `linux/amd64`, which is why every size gate is a ratio against a
  base image measured on the same daemon rather than an absolute figure.
- **Setup wall clock on the real image.** The foreground is a handful of shell
  commands and file writes with no network on the critical path, so it should be
  a few seconds, but that has not been measured on the Alpine VM. The internal
  deadline is 95 s and the script prints `total setup time` on every run.
- **Base image pull time.** `python:3.11` is ~398 MB of content. The detached job
  pulls it after provisioning returns; on the portal network that is expected to
  take tens of seconds. The checks only wait on it when it is genuinely missing.

## 9. Post-cohort fix: the shell prompt (2026-08-26)

Reported from a live VM: the prompt read `bash-5.1$` and never changed on `cd`.

That string is bash's **compiled-in fallback** `PS1='\s-\v\$ '` — shell name and
version, no directory. It appears only when nothing ever set `PS1`. The portal
opens a **non-login interactive** bash, which reads `~/.bashrc` and never
`/etc/profile`, and the Alpine image ships no `/home/user/.bashrc`. Nothing in
the pack wrote one, so the fallback stood. For a lab whose statement repeats
"run every compose command from the project root", a prompt that cannot show the
directory is a real trap.

Setup now writes, in section `[4/6]`:

- `/home/user/.bashrc` — sets `PS1` to `\u:\w\$` (a coloured variant when `TERM`
  looks capable). It returns immediately for non-interactive shells and replaces
  **only** the built-in default, so a learner's own prompt survives.
- `/home/user/.profile` and `.bash_profile` — source `.bashrc`, but only under
  bash (`$BASH_VERSION`), because the colour escapes are bash syntax and busybox
  ash would print `\[` and `\]` raw.
- `/etc/profile.d/marlow-prompt.sh` — plain `\u:\w\$` for a non-bash login shell,
  which Alpine's `/etc/profile` sources. Escapes busybox ash understands, and it
  prints nothing.

All three are `chown`ed to `user` in the same block.

Verified on the authoring host, bash 3.2 on a pty:

- Three sessions started in three different directories each rendered their own
  path (`pulkitmangal:/tmp$`), where before the change the same shell printed a
  static `bash-3.2$`.
- `TERM=dumb` takes the plain branch; `TERM=xterm` emits the wrapped colour
  escapes (`\[\033[1;32m\]…`), so line editing is not corrupted.
- Sourced non-interactively from bash: silent, exit 0. Sourced from POSIX `sh`:
  silent, no bash syntax reaches it.
- `bash -n` clean on the regenerated `setup_script.sh`; `build.sh` prints
  `Max Score = 5 x 10`; `Setup.zip` carries the block.

**Grading is unaffected.** No check runs `su`, a login shell, or reads
`/etc/profile` (`grep -nE '\bsu \b|bash -l|--login|/etc/profile'` over
`script_0*.sh` returns nothing), and every file written here prints nothing under
any shell, so no check's output parsing can be disturbed.

Not settled on this host: the actual rendering in the portal's terminal widget on
the Alpine image. The mechanism is bash's own `\w` expansion, re-evaluated each
time the prompt is displayed, so the remaining risk is the terminal, not the
prompt string.

## 10. Post-cohort fix: no editor was provisioned (2026-08-26)

Reported from the same live VM: `vim docker-compose.yml` returned to the prompt
immediately and created nothing.

The pack's own audit found the cause: **setup installed and checked for no
editor at all.** The Alpine base guarantees only busybox `vi`; `vim` and `nano`
are separate packages. Four files have to be written by hand, so the lab was
depending on a tool it never provided.

Setup section `[1/6]` now:

- probes for `vim`, `nano` and `vi`;
- if either `vim` or `nano` is absent, runs `apk add --no-cache vim nano` under
  `cap 25` — bounded and non-fatal, so a slow mirror cannot stall provisioning;
- re-probes and either reports `editors available: …` or warns that only a shell
  heredoc is left.

The summary now prints the editor list plus a `cat > file <<'END'` example, and
`problem-statement.md` carries the same fallback in **Environment**. Rendering
the summary with `EDITORS_FOUND=" vim nano vi"` confirmed the nested heredoc
survives the outer one.

Undetermined from the report: whether `vim` was genuinely missing or the portal's
terminal cannot render a full-screen application. The screenshot showed **no**
`command not found`, which fits the second reading. The heredoc route in the
statement covers both, since a line-oriented terminal defeats `vi`, `vim` and
`nano` equally.

`reference-solution/paste-to-vm.sh` was added for instructor smoke tests: paste
it into a VM and it writes all four deliverables with heredocs, no editor
involved. Verified byte-identical to the four reference files with `diff`. It
sits outside the `alt*`/`_defect*`/`_cheat*` globs `sweep.sh` enumerates, so it
is never graded as a candidate, and `reference-solution/` never ships to the
learner.

## 11. First field measurements from a real VM (2026-08-26)

From a provisioned Alpine Docker VM, after a no-op submit:

- **Setup wall clock: 9 s**, `setup finished with no warnings`. §8 listed this as
  unmeasured; it is now measured, against a 95 s internal deadline.
- **Editors: `vim nano vi`** — the §10 fix works on the real image, inside the 9 s.
- **Prompt: `user:~/marlow-depot$`** — the §9 fix works, and tracks `cd`.
- **`find /home/user -user root` prints nothing.** The root-ownership invariant
  from §8 held on a real VM with the checks actually running as root — the row
  the permutation matrix could only self-report as vacuous on the authoring host.
- **`/tmp/marlow_timing.log` contained exactly one row: `script_01 1s`.** The
  refusal path is as designed (one second, no bootstrapping) but **only
  `script_01` ran**; `script_02..05` left no row, and their `EXIT` trap would have
  written one even if the judge had killed them. So the judge stopped after the
  first check.
- `/usr/local/bin/judge/test/` holds `common.sh` **and `main.sh`** (3770 bytes) —
  a driver the platform contract in the authoring skill does not describe. The
  portal rendered one empty bullet under "Test Case Results:", which matches one
  test case having run with its message dropped.

Open, and blocking: the contents of `main.sh` and `common.sh`. Whether the
one-check stop is the driver aborting on first failure, or the lab entry having a
single test case configured, cannot be told apart from outside. This applies to
all seven packs, not just this one - they share the preamble.

## 12. Statement clarity audit (2026-08-26)

Gate 3 of the review skill, run after the pack was confirmed green end to end on
the portal. Method: extract every *must / never / do not / has to* from the
statement and find the check that enforces it; then cross-check that every
identifier the checks look up by name is fixed by the statement.

**Identifiers: clean.** All eleven the checks resolve by name are stated -
`marlow-depot/depot-api:{latest,1.0}`, `ai-lab/depot-llm:1.0`, `depot-index`,
`DEPOT_INDEX_DIR`, `DEPOT_LLM_URL`, `DEPOT_API_KEY`, `dist/depot-api-1.0.tar`,
`/index`, 8000, 9000. Nothing is graded that the statement leaves to an "e.g.".

**Six revisions made:**

1. **The one a careful learner would have got stuck on.** Task 2 says *exclude
   `.env`*; Task 3 says *read `DEPOT_API_KEY` from `depot-api/.env` at run time*.
   Read together those look contradictory, and nothing in the statement resolved
   it. Task 2's Requirements now says plainly that `.dockerignore` governs only
   what the **build** sees, the file stays on disk, and Compose reads it from
   disk at start - both are required and they do not conflict.
2. `Do not add a HEALTHCHECK that installs extra packages` was a rule with no
   check of its own. Demoted to guidance tied to the real gate: a `HEALTHCHECK`
   is optional, and anything it installs counts against the size ceiling.
   The credential clause beside it now says the ENV/build-arg rule **is** checked.
3. `must not be restarted` gave a rule without its reason. Now: leave the restart
   policy alone, because a service Compose keeps restarting never reaches the
   completed state step 4 waits for.
4. `the key must not be written into your compose file or your Dockerfile` was
   also unenforced - no check reads those files, by design. The step now states
   the graded property exactly (container has it, image does not, in environment,
   build argument, history or filesystem) and keeps the compose-file practice as
   a reason rather than a rule. First draft of this said the shortcut "would
   satisfy the checks" - reworded, because advertising a bypass is worse than
   leaving it unstated.
5. `Print what was written` is a step with nothing matching stdout. Added: the
   wording is yours, nothing matches your output text.
6. `Do not include the credential in the archive` implied a separate scan of the
   tarball. There is none, and none is needed: `docker save` writes exactly the
   image, so a clean image gives a clean archive. Said so.

**No graded value changed** - the revisions are prose only, no identifier, port,
path, tag or threshold was touched, so the portal run that passed end to end
remains valid. `build.sh` still passes, including its statement/check consistency
gates and its zero-markdown-tables check.

Not done here: the same audit for the other six packs.
