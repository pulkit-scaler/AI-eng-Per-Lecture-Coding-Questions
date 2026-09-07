# Module 2, Lecture 5 — AI Modalities

Four coding questions, two per modality — Q1 and Q3 rewritten in the 2026-08-18 depth pass so
the libraries the material uses do the work. **Speech:** the capture-side budget a recording is
locked into before any model sees it (Nyquist limit, quantization noise floor, uncompressed
size), and the recognition metric that scores the output (WER with its substitution /
deletion / insertion split). **Video:** the token budget that decides whether a clip fits a
transformer (uniform frame sampling → patch vs tubelet tokenization), and the parameter gap
between a full 3-D convolution and its factorized (2+1)D replacement.

Nothing is downloaded, trained or decoded. Q1 and Q3 do their work in `numpy`, Q2 drives
`jiwer`, Q4 is integer arithmetic on a layer specification. Every question is fully
deterministic and every case runs in well under a tenth of a second.

---

## Q1: Downsampling a Recording Without Aliasing It

**Context:** Halving a sample rate is not the same operation as keeping every second sample. Content
above half the new rate cannot be represented at that rate, and it does not politely disappear — it
folds back into the audible band as a permanent false low tone that no later stage can remove. The
fix is a low-pass filter applied *before* the rate is reduced, which is exactly what a real
resampling routine does and exactly what array slicing does not. A capture-side report should
therefore say what the new rate can represent, what the filtered path actually produced, how far it
diverges from the naive path, and what the session will cost on disk.

**Problem Statement:**

Using the `numpy` and `librosa` libraries, write a function
`resample_budget(excerpt, orig_sr, target_sr, bit_depth, channels, duration_s, tone_hz)`.

1. `excerpt` is a short mono waveform in floating point, captured at `orig_sr`. Report the highest
   frequency `target_sr` can represent, in Hz, and whether a pure tone at `tone_hz` survives the
   move to that rate — it survives only if it lies **strictly below** that frequency.
2. Resample `excerpt` from `orig_sr` to `target_sr` with `librosa`, which low-passes before it
   decimates. Report how many samples come back.
3. Build the naive comparison by taking every `orig_sr // target_sr`-th sample of `excerpt` with
   plain slicing, no filtering. Over the first `n` positions, where `n` is the shorter of the two
   results, report the largest absolute difference between the resampled signal and the naive one,
   rounded to 6 decimal places. This is the aliasing the filter removed.
4. Measure the quantization noise `bit_depth` injects, working from `excerpt`: normalize it by its
   peak absolute value so it spans −1 to +1; round each normalized sample onto `2 ** bit_depth`
   levels spaced evenly from −1 to +1 inclusive, taking the nearest level; then report the
   signal-to-noise ratio in decibels — `20 · log10` of the ratio between the L2 norm of the
   normalized signal and the L2 norm of (normalized − quantized) — rounded to 2 decimal places.
5. Report the uncompressed size of the whole session **at the target rate**, in bytes: every channel
   stores `target_sr × duration_s` samples, each occupying `bit_depth` bits, with no container
   overhead.
6. Return a dictionary with exactly these six keys: `"nyquist_hz"` (float), `"tone_survives"`
   (boolean), `"resampled_len"` (integer), `"aliasing_max_diff"` (float), `"quant_snr_db"` (float)
   and `"raw_bytes"` (integer).

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: excerpt (numpy_1d)
    Line 1: N (array length)
    Line 2: N space-separated values
  Argument 2: orig_sr (integer)
    Single line: one integer
  Argument 3: target_sr (integer)
    Single line: one integer
  Argument 4: bit_depth (integer)
    Single line: one integer
  Argument 5: channels (integer)
    Single line: one integer
  Argument 6: duration_s (float)
    Single line: one float
  Argument 7: tone_hz (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `resample_budget()` on a new line.

**Sample Input:**

```
excerpt = np.array([0.0, 0.198828, 0.026466, 0.528245, ...])   # 48 samples
orig_sr    = 16000
target_sr  = 8000
bit_depth  = 16
channels   = 1
duration_s = 5.75
tone_hz    = 7000.0
```

**Sample Output:**

```
{'nyquist_hz': 4000.0, 'tone_survives': False, 'resampled_len': 24, 'aliasing_max_diff': 0.263083, 'quant_snr_db': 96.05, 'raw_bytes': 92000}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is downloaded and no audio file is read: the excerpt arrives as an array. Pass the two rates to the
resampler by name, and leave its filter settings at their defaults — the difference you report in
step 3 is meant to be the difference between a filtered path and an unfiltered one, not between two
filter configurations. `bit_depth` is always a multiple of 8.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: resample_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. excerpt    → Numpy 1D Array
2. orig_sr    → Integer
3. target_sr  → Integer
4. bit_depth  → Integer
5. channels   → Integer
6. duration_s → Float
7. tone_hz    → Float
```

(`librosa.resample` takes both rates as keyword arguments with no defaults; they are required here
and supplied in every test case. Six values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
import librosa
import numpy as np


def resample_budget(excerpt: np.ndarray, orig_sr: int, target_sr: int, bit_depth: int,
                    channels: int, duration_s: float, tone_hz: float) -> dict:
    nyquist = target_sr / 2

    filtered = librosa.resample(excerpt, orig_sr=orig_sr, target_sr=target_sr)
    naive = excerpt[:: orig_sr // target_sr]
    n = min(len(filtered), len(naive))
    aliasing_max_diff = float(np.max(np.abs(filtered[:n] - naive[:n])))

    x = excerpt / np.max(np.abs(excerpt))
    levels = 2 ** bit_depth
    xq = (np.round((x * 0.5 + 0.5) * (levels - 1)) / (levels - 1) - 0.5) * 2.0
    snr_db = 20 * np.log10(np.linalg.norm(x) / np.linalg.norm(x - xq))

    raw_bytes = int(target_sr * duration_s) * channels * (bit_depth // 8)

    return {
        "nyquist_hz": float(nyquist),
        "tone_survives": bool(tone_hz < nyquist),
        "resampled_len": int(len(filtered)),
        "aliasing_max_diff": round(aliasing_max_diff, 6),
        "quant_snr_db": round(float(snr_db), 2),
        "raw_bytes": raw_bytes,
    }
```

**Test Cases —** `in.txt`

```
2
48
0.0 0.198828 0.026466 0.528245 0.132454 0.687213 0.339669 0.656937 0.589372 0.504255 0.76939 0.336681 0.775784 0.237288 0.573564 0.217828 0.220875 0.217343 -0.15793 0.146429 -0.43541 -0.049788 -0.544521 -0.348108 -0.506597 -0.649999 -0.408773 -0.830304 -0.345269 -0.804446 -0.357827 -0.575482 -0.410728 -0.233743 -0.415065 0.090903 -0.287674 0.29681 -0.009382 0.359634 0.352671 0.335205 0.673025 0.315872 0.83115 0.367181 0.774114 0.483064
16000
8000
16
1
5.75
7000.0
32
0.000308 0.074686 -0.068534 -0.222648 -0.113668 -0.247912 0.015036 0.335054 -0.123052 -0.155119 0.122461 0.089222 0.026354 -0.232617 -0.007313 0.173826 -0.336054 -0.114404 -0.475306 -0.322384 -0.460434 -0.058773 -0.316862 0.067816 0.039188 -0.046733 -0.62919 -0.134673 -0.012125 0.028327 -0.382534 -0.119438
44100
22050
8
2
1.5
8000.0
```

**Test Cases —** `out.txt`

```
{'nyquist_hz': 4000.0, 'tone_survives': False, 'resampled_len': 24, 'aliasing_max_diff': 0.263083, 'quant_snr_db': 96.05, 'raw_bytes': 92000}
{'nyquist_hz': 11025.0, 'tone_survives': True, 'resampled_len': 16, 'aliasing_max_diff': 0.252895, 'quant_snr_db': 43.74, 'raw_bytes': 66150}
```

**Grader Notes:**

- **Environment:** `librosa` 1.0.0 and `numpy` 2.5.2 on Python 3.12.13, CPU, no network. The first
  `librosa.resample` call in a fresh process costs ~7 s of lazy import and back-end warm-up;
  subsequent calls are milliseconds. Budget for that once per submission, not once per case.
- **The library produces the graded value.** `aliasing_max_diff` is the gap between `librosa`'s
  polyphase anti-aliased output and plain slicing. Those filtered samples are not derivable by any
  formula a learner could write from the statement — they are the output of the resampler's filter
  bank. `resampled_len` is likewise the library's own output length. This replaced an earlier
  version of this question that computed Nyquist, an SNR and a byte count from the arguments and
  never imported `librosa`, even though `librosa.resample` is the call the material makes and the
  anti-aliasing contrast is the section's whole point.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities.md`:
  - *Nyquist and the strictly-below survival rule* — §1.1, **lines 283–287**: "**Nyquist:** only
    frequencies below `fs/2` survive… Content above `fs/2` doesn't vanish; it **aliases**, so an
    anti-alias low-pass must run *before* downsampling".
  - *The filtered path and the naive path, side by side* — **lines 286–294**, verbatim:
    "(`librosa.resample` does; naive `y[::k]` does not)", then
    `y8  = librosa.resample(y, orig_sr=SR, target_sr=8_000)` and
    `y_naive = y[:: max(1, SR // 8_000)]`. Steps 2 and 3 are those two lines and the comparison the
    material sets up between them.
  - *The printed rate/Nyquist table* — **lines 296–303**, including `16000 Hz -> usable < 8000 Hz`
    and `8000 Hz -> usable < 4000 Hz`; case 1's rates are that table's own pair.
  - *Bit depth and the quantizer* — §1.2, **lines 352–376**: `def quantize(x, bits)` with
    `(np.round((x*0.5+0.5)*(L-1))/(L-1) - 0.5) * 2.0` and the SNR line
    `20*np.log10(np.linalg.norm(x) / np.linalg.norm(x - quantize(x, b)))`. Step 4 is that pair of
    expressions stated in prose; the reference reproduces them, minus the material's `1e-9`/`1e-12`
    guards, which cannot bite on a non-silent excerpt.
  - *Byte count from samples × channels × bytes-per-sample* — the storage reasoning of §1, applied
    at the target rate.
  - **Disclosed, not taught:** taking the **maximum absolute difference** between the two paths as
    a scalar summary. The material shows the divergence as a plot (lines 335–350) and never reduces
    it to a number; step 3 defines the reduction, including the shorter-of-the-two truncation.
- **Determinism.** `librosa.resample` at its default back-end is deterministic; the same call was
  run twice in one process and across two processes and compared with `np.array_equal` — identical
  each time. Pin `librosa == 1.0.0`: the default `res_type` is a library default, and a change to it
  would move `aliasing_max_diff`. `resampled_len`, the Nyquist figure, the SNR and the byte count are
  all robust to that.
- Compare `"resampled_len"`, `"raw_bytes"` and `"tone_survives"` exactly; `"nyquist_hz"` and
  `"quant_snr_db"` with tolerance `1e-2`; `"aliasing_max_diff"` with tolerance `1e-4` — it is the one
  value that carries the resampler's filter design in it.
- **What each case is for:**
  - **Case 1** — 16 kHz → 8 kHz, the material's own pair. The excerpt is a 440 Hz tone plus a
    **7 kHz** component, which is above the 4 kHz target Nyquist, so the filter has real work to do
    and `aliasing_max_diff` is large (0.26 on a signal of peak ~0.83). `tone_hz` sits at that 7 kHz
    component and does **not** survive.
  - **Case 2** — 44.1 kHz → 22.05 kHz on broadband noise, a tone that **does** survive, 8-bit depth
    (so the SNR is 43.74 dB rather than 96.05 — the ~6 dB-per-bit relation across an 8-bit gap), and
    2 channels, so a solution that ignores `channels` is caught here.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Slicing instead of resampling** (`excerpt[::k]` for both paths): `aliasing_max_diff` 0.0 on
    both cases. This is the reading the question exists to catch, and it is caught loudly.
  - **Resampling positionally** (`librosa.resample(excerpt, orig_sr, target_sr)`): raises
    `TypeError` in `librosa` 1.0 — the rates are keyword-only. A loud failure; the Note warns.
  - **Byte count at the original rate**: 184000 / 132300 against 92000 / 66150 — caught on both.
  - **Ignoring `channels`**: case 2 gives 33075 against 66150 — caught by case 2 only.
  - **Non-strict tone comparison** (`<=`): flips case 1's `tone_survives` to `True`, since 7000 is
    below 8000 but the *target* Nyquist is 4000 — this wrong reading actually needs a tone exactly
    at the boundary to trip, so it is **not** covered by the shipped cases; noted here so nobody
    assumes it is.
  - **Quantizing with a step of `2 / levels`** instead of levels on the closed interval: 96.02 /
    43.71 against 96.05 / 43.74 — caught at the `1e-2` tolerance.
- **Overlap check:** the topic-organized bank's log-mel question
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q7) works
  on frame/hop geometry and mel-filter shape and never resamples or quantizes. No shared graded
  value.
- Both cases executed against the reference solution.

---

## Q2: Word Error Rate and Its Substitution / Deletion / Insertion Split

**Context:** Recognition output is not scored the way free-form generation is. The standard
metric aligns the hypothesis against the reference word by word and counts the three ways they
can disagree — a wrong word (substitution), a missing word (deletion), an extra word
(insertion) — then divides the total by the number of reference words. The comparison is made
*after* normalisation, so that capitalisation and punctuation, which a recogniser renders however
it likes, are not scored as recognition errors. The breakdown matters as much as the rate: a
system that mostly deletes is failing differently from one that mostly inserts, and the two call
for different fixes.

**Problem Statement:**

Using the `jiwer` library, write a function `wer_breakdown(reference, hypothesis)`.

1. Normalize both strings the same way, in this order: lowercase the text; then remove every
   character that is not a lowercase letter, a digit or a space — remove it outright rather than
   replacing it with a space, so `"I'd"` becomes the single word `id`; then take the words to be
   whatever whitespace-separated tokens remain.
2. Align the normalized hypothesis against the normalized reference at word level and count the
   **substitutions**, the **deletions** (reference words the hypothesis is missing) and the
   **insertions** (words the hypothesis adds).
3. Compute the word error rate as
   `(substitutions + deletions + insertions) / (number of normalized reference words)`, rounded
   to 4 decimal places.
4. Return a dictionary with exactly these four keys:
   - `"substitutions"` — the substitution count, as an integer
   - `"deletions"` — the deletion count, as an integer
   - `"insertions"` — the insertion count, as an integer
   - `"wer"` — the rate from step 3, as a float

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: reference (string)
    Single line: a string
  Argument 2: hypothesis (string)
    Single line: a string
```

**Output Format:**

For each test case, print the result of `wer_breakdown()` on a new line.

**Sample Input:**

```
reference  = "MISTER QUILTER IS THE APOSTLE OF THE MIDDLE CLASSES AND WE ARE GLAD TO WELCOME HIS GOSPEL"
hypothesis = "Mr. Quilter is the apostle of the middle classes, and we are glad to welcome his gospel."
```

**Sample Output:**

```
{'substitutions': 1, 'deletions': 0, 'insertions': 0, 'wer': 0.0588}
```

**Note:** The input handling is already in place — you only need to implement the function. Each
string arrives on a single line. Reach for the library's alignment output rather than its rate
alone: the same call that scores a pair also reports how the errors break down.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: wer_breakdown
RETURN TYPE: Dictionary

ARGUMENTS:
1. reference   → String
2. hypothesis  → String
```

(No argument carried a default. Four values must come back — three counts and a rate — so they
fold into one `Dictionary`.)

**Reference Solution:**

```python
import re

import jiwer


def _normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()


def wer_breakdown(reference: str, hypothesis: str) -> dict:
    ref = " ".join(_normalize(reference).split())
    hyp = " ".join(_normalize(hypothesis).split())

    out = jiwer.process_words(ref, hyp)

    return {
        "substitutions": int(out.substitutions),
        "deletions": int(out.deletions),
        "insertions": int(out.insertions),
        "wer": round(float(out.wer), 4),
    }
```

**Test Cases —** `in.txt`

```
2
MISTER QUILTER IS THE APOSTLE OF THE MIDDLE CLASSES AND WE ARE GLAD TO WELCOME HIS GOSPEL
Mr. Quilter is the apostle of the middle classes, and we are glad to welcome his gospel.
I WOULD LIKE TO RESCHEDULE THE DELIVERY TO TUESDAY MORNING AND PLEASE CONFIRM THE NEW TIME BY TEXT
I'd like to reschedule the delivery to Thursday morning, and please confirm the new time by text right away.
```

**Test Cases —** `out.txt`

```
{'substitutions': 1, 'deletions': 0, 'insertions': 0, 'wer': 0.0588}
{'substitutions': 2, 'deletions': 1, 'insertions': 2, 'wer': 0.2778}
```

**Grader Notes:**

- **Scope trace.** All of it traces to `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities.md`:
  - *The metric and its three error types* — §4.1, lines 753–756: "**WER** = (substitutions +
    insertions + deletions) / reference words, computed *after* normalization (case, punctuation)
    so you measure recognition, not formatting." Steps 2–3 are that sentence, split into the
    counts and the quotient.
  - *The library* — §4.1, lines 762–780 and 783–798: `from jiwer import wer`, twice, including
    the deterministic toy pair annotated `# 1 sub + 1 del` with the printed
    `toy WER : 0.222 (2 word errors / 9 ref words = 0.222)`. `jiwer` is the source material's
    own WER library, so per-operation library matching puts this question in `jiwer` rather than
    in a hand-rolled edit distance.
  - *The normalization rule* — §4.1, lines 788–793: the fallback normalizer
    `lambda s: re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()`, used when
    `BasicTextNormalizer` is unavailable. Step 1 is that regular expression stated in prose,
    including the "remove, don't replace with a space" behaviour that the character class
    implies. The reference solution uses the same expression.
  - *Reporting the normalized rate* — §4.1 line 797–798 prints both and marks the normalized one
    `<- report this one`.
  - **Disclosed, not taught (API only):** the source material calls `jiwer.wer(...)`, which
    returns the rate alone; the aligned counts come from `jiwer.process_words(...)` on the same
    library. The *metric* is fully in scope and the statement asks for the counts explicitly;
    only the one-call-deeper entry point is not shown in the source. A hand-rolled
    edit-distance backtrace is an accepted alternative (see below), so no learner is blocked.
- **Determinism.** Integer counts plus one rational; `round(..., 4)` on a quotient of small
  integers. Compare the three counts exactly and `"wer"` with tolerance `1e-4`. Pin
  `jiwer == 4.0.0` (verified); the counts are a property of the alignment, not of the release, but
  the attribute names on the returned object are library API.
- **The S/D/I split is unambiguous on both cases.** Equal-cost alignments can in general permute
  a substitution against a deletion+insertion pair, so this was checked rather than assumed: a
  hand-rolled Levenshtein backtrace was run under **three different tie-break priorities**
  (`s>d>i`, `d>i>s`, `i>d>s`) and all three returned `(1, 0, 0)` on case 1 and `(2, 1, 2)` on
  case 2 — identical to `jiwer`. If either pair is ever edited, re-run that check: the *total*
  is always unique, the split is not.
- **Case 1 reproduces the source material's own printed figure.** Its normalized forms are
  `mister quilter is the apostle…` and `mr quilter is the apostle…` — 17 reference words, one
  substitution — giving `1/17 = 0.0588`, against the printed `WER normalized : 0.059`. (The
  material's `WER raw : 0.176` is the same pair *without* normalization beyond lowercasing, which
  is the first wrong reading below.) Case 2 is an independent pair carrying all three error
  types: `id` for `i would` (one substitution + one deletion), `thursday` for `tuesday` (one
  substitution), and a trailing `right away` (two insertions) — 5 errors over 18 reference words,
  `0.2778`.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **No normalization at all** (passing the raw strings to the library): `(17, 0, 0, 1.0)` and
    `(18, 0, 1, 1.0556)` — caught on both, and note `jiwer` neither case-folds nor strips
    punctuation on its own, which is exactly why step 1 exists.
  - **Lowercasing but not stripping punctuation** — identical to the above on these cases
    (`1.0` / `1.0556`) because the case difference alone already substitutes every word; the
    combined reading is what the two bullets here and below pin down.
  - **Not lowercasing** (stripping punctuation only): `(17, 0, 0, 1.0)` and `(18, 0, 1, 1.0556)`
    — caught on both.
  - **Replacing punctuation with a space instead of removing it:** `(1, 0, 0, 0.0588)` and
    `(2, 0, 2, 0.2222)`. **Case 2 catches this alone** — its `"I'd"` becomes `i d` under that
    reading, which then matches `i` and substitutes `d` for `would`, turning the deletion into a
    hit and dropping the rate from `0.2778` to `0.2222`. Case 1 contains no intra-word
    punctuation, so it cannot see the difference. Case 2 must stay in any shipped subset.
  - **Dividing by the hypothesis word count** instead of the reference's: `0.2632` on case 2.
    **Case 2 catches this alone** — case 1's reference and hypothesis are both 17 words long.
  - **Dropping insertions from the numerator** (`(S+D)/N`, the "errors against the reference
    only" misreading): `0.1667` on case 2. **Case 2 catches this alone** — case 1 has no
    insertions.
  - **Reporting the library's `wer` but hand-counting the breakdown wrongly** is covered by the
    tie-break check above; no permutation of the counts survived.
- **Accepted routes — verified to return identical values on both cases:**
  1. `jiwer.process_words(ref, hyp)` and reading `.substitutions` / `.deletions` /
     `.insertions` / `.wer` (the reference).
  2. Taking the rate from `jiwer.wer(ref, hyp)` or recomputing it as `(S+D+I)/len(ref.split())`
     — all three are bit-identical (`0.058823529411764705`, `0.2777777777777778`).
  3. A hand-rolled word-level Levenshtein DP with backtrace, under any tie-break order — same
     counts, same rate (checked under three orders). Slower and not the route the source material
     takes, but correct; do not mark it down.
  4. Collapsing runs of whitespace or not: the library splits on whitespace, so both spellings
     agree.
- **Overlap check:** no WER question exists in the topic-organized bank
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q1–Q8:
  LoRA budget, symmetric INT8, KV-cache sizing, function calling, asymmetric INT8, PEFT LoRA,
  log-mel shape, speculative decoding). An older superseded question bank did include a
  WER exercise that returned the **rate only**; this one is graded on the breakdown, so even
  against that one it is not a duplicate.
- Both cases executed against the reference solution (Python 3.12.13, jiwer 4.0.0,
  rapidfuzz 3.14.5); 0.09 s for the whole file, including the import.

---

## Q3: Cutting a Frame Into Patches and Budgeting a Clip's Tokens

**Context:** A transformer does not consume a video; it consumes a sequence of tokens. Getting from
one to the other is two decisions. First, which frames survive — a fixed number spread evenly across
the clip is the cheapest and most reproducible choice. Second, how each surviving frame becomes
tokens: it is cut into non-overlapping square patches, and a partial patch along an edge is not a
patch, so the frame is cropped down to a whole number of them first. A tubelet generalises the patch
into a space-time cube spanning several frames at once, dividing the token count by its depth. Token
count is the number to watch, because attention cost grows with its square.

**Problem Statement:**

Using `numpy`, write a function
`clip_token_budget(frame, patch_size, total_frames, n_sampled, tubelet_depth)`.

1. Sample `n_sampled` frame indices from a clip of `total_frames` frames, evenly spaced across the
   whole clip: the first is frame `0`, the last is the clip's final frame, and every position in
   between is rounded to the nearest whole index.
2. `frame` is one sampled frame, a 2-D array of pixel values. Crop it down to a whole number of
   `patch_size × patch_size` patches along each axis — the crop takes the top-left region and
   discards any partial patch at the right or bottom edge — then cut the cropped region into those
   patches. Report the patch grid as `[rows, columns]` and the resulting token count for one frame.
3. Per-frame tokenization emits one token per patch per sampled frame; report that total. Tubelet
   tokenization instead groups the sampled frames into non-overlapping cubes `tubelet_depth` frames
   deep, so each such stack contributes what a single frame contributed before; report that total.
   (`tubelet_depth` always divides `n_sampled`.)
4. Report the mean pixel value of every patch, rounded to 4 decimal places, keyed by the patch's
   position in row-major order over the grid — the top-left patch is `0`, the next one to its right
   is `1`, and the first patch of the second row follows the last of the first.
5. Return a dictionary with exactly these six keys: `"frame_indices"` (list of integers, increasing),
   `"grid"` (a two-element list, rows then columns), `"tokens_per_frame"`, `"per_frame_tokens"` and
   `"tubelet_tokens"` (integers), and `"patch_means"` (a dictionary from patch index to mean).

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: frame (numpy_2d)
    Line 1: H W (number of rows, number of columns)
    Next H lines: W space-separated values each
  Argument 2: patch_size (integer)
    Single line: one integer
  Argument 3: total_frames (integer)
    Single line: one integer
  Argument 4: n_sampled (integer)
    Single line: one integer
  Argument 5: tubelet_depth (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `clip_token_budget()` on a new line.

**Sample Input:**

```
frame = np.array([[0.625, 0.897, ...], ...])   # 10 x 14
patch_size    = 4
total_frames  = 40
n_sampled     = 8
tubelet_depth = 2
```

**Sample Output:**

```
{'frame_indices': [0, 6, 11, 17, 22, 28, 33, 39], 'grid': [2, 3], 'tokens_per_frame': 6, 'per_frame_tokens': 48, 'tubelet_tokens': 24, 'patch_means': {0: 0.6248, 1: 0.4434, 2: 0.3636, 3: 0.5951, 4: 0.5393, 5: 0.4532}}
```

**Note:** The input handling is already in place — you only need to implement the function. No video
is decoded and no model is loaded. The frame's height and width are not necessarily multiples of
`patch_size`, and the discarded strip is part of the answer — a patch mean computed over a region
that includes cropped pixels will not match. Both tokenizations apply to the **sampled** frames, not
to the full clip.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: clip_token_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. frame         → Numpy 2D Array
2. patch_size    → Integer
3. total_frames  → Integer
4. n_sampled     → Integer
5. tubelet_depth → Integer
```

(Six values must come back — a schedule, a geometry, three counts and a per-patch table — so they
fold into one `Dictionary`, with the per-patch table nested inside it.)

**Reference Solution:**

```python
import numpy as np


def clip_token_budget(frame: np.ndarray, patch_size: int, total_frames: int,
                      n_sampled: int, tubelet_depth: int) -> dict:
    idx = np.linspace(0, total_frames - 1, n_sampled).round().astype(int)

    H, W = frame.shape
    Hc, Wc = (H // patch_size) * patch_size, (W // patch_size) * patch_size
    gh, gw = Hc // patch_size, Wc // patch_size
    grid = frame[:Hc, :Wc].reshape(gh, patch_size, gw, patch_size).swapaxes(1, 2)

    tokens_per_frame = gh * gw

    return {
        "frame_indices": idx.tolist(),
        "grid": [gh, gw],
        "tokens_per_frame": tokens_per_frame,
        "per_frame_tokens": tokens_per_frame * n_sampled,
        "tubelet_tokens": tokens_per_frame * (n_sampled // tubelet_depth),
        "patch_means": {i * gw + j: round(float(grid[i, j].mean()), 4)
                        for i in range(gh) for j in range(gw)},
    }
```

**Test Cases —** `in.txt`

```
2
10 14
0.625 0.897 0.776 0.225 0.3 0.874 0.005 0.821 0.797 0.468 0.303 0.278 0.255 0.445
0.505 0.553 0.996 0.793 0.622 0.989 0.215 0.16 0.613 0.044 0.036 0.515 0.466 0.917
0.629 0.514 0.497 0.248 0.012 0.192 0.692 0.201 0.37 0.004 0.83 0.154 0.268 0.88
0.51 0.847 0.64 0.742 0.091 0.541 0.508 0.871 0.361 0.598 0.059 0.388 0.323 0.15
0.816 0.379 0.979 0.59 0.605 0.638 0.676 0.151 0.44 0.24 0.402 0.097 0.968 0.215
0.672 0.3 0.874 0.662 0.132 0.845 0.945 0.904 0.57 0.145 0.192 0.928 0.552 0.181
0.884 0.642 0.57 0.376 0.411 0.239 0.038 0.876 0.468 0.548 0.322 0.751 0.025 0.372
0.03 0.123 0.967 0.658 0.428 0.524 0.873 0.344 0.59 0.684 0.355 0.519 0.765 0.909
0.151 0.933 0.005 0.753 0.811 0.137 0.419 0.815 0.014 0.628 0.793 0.513 0.726 0.226
0.199 0.363 0.179 0.346 0.948 0.573 0.34 0.272 0.952 0.444 0.98 0.516 0.521 0.897
4
40
8
2
9 6
189.4 148.1 108.8 223.9 105.0 235.3
17.5 109.6 132.5 242.5 64.0 205.5
172.5 182.9 160.6 247.7 84.8 101.6
51.7 12.9 54.3 233.4 214.2 28.7
154.0 122.2 151.6 168.1 78.2 245.1
118.8 160.2 162.0 46.9 15.8 104.9
194.8 207.9 186.1 28.9 232.9 204.5
223.8 133.4 233.5 11.9 7.7 5.2
64.5 63.4 47.8 144.6 9.9 150.5
3
250
16
4
```

**Test Cases —** `out.txt`

```
{'frame_indices': [0, 6, 11, 17, 22, 28, 33, 39], 'grid': [2, 3], 'tokens_per_frame': 6, 'per_frame_tokens': 48, 'tubelet_tokens': 24, 'patch_means': {0: 0.6248, 1: 0.4434, 2: 0.3636, 3: 0.5951, 4: 0.5393, 5: 0.4532}}
{'frame_indices': [0, 17, 33, 50, 66, 83, 100, 116, 133, 149, 166, 183, 199, 216, 232, 249], 'grid': [3, 2], 'tokens_per_frame': 6, 'per_frame_tokens': 96, 'tubelet_tokens': 24, 'patch_means': {0: 135.7667, 1: 167.8111, 2: 109.7444, 3: 126.1444, 4: 150.5778, 5: 88.4556}}
```

**Grader Notes:**

- **Environment:** `numpy` 2.5.2 on Python 3.12.13. Milliseconds per case, no download.
- **The array work produces the graded value.** `patch_means` cannot be predicted from the geometry
  arguments — the patches have to be cut out of the real array, with the crop applied first. This
  replaced an earlier version that returned only counts, all of which followed from
  `height // patch_size` arithmetic; that version accepted a solution which never touched a pixel.
  The counts are retained, so nothing the earlier version graded was lost.
- **Scope trace.** Every technique traces to
  `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities.md`:
  - *Uniform frame sampling* — §3, **lines 1728–1729**:
    `def uniform_idx(T, n): return np.linspace(0, T - 1, n).round().astype(int)`, called with
    `N = 8` and printing `uniform idx       : [0, 6, 11, 17, 22, 28, 33, 39]` (the call at line 1748, its
    output at line 1772). **Case 1
    reproduces that printed list exactly.**
  - *Patchify, the crop, and the grid* — §5, **lines 1951–1962**, verbatim:
    `Hc, Wc = (H // P) * P, (W // P) * P`, `img = img[:Hc, :Wc]`, then
    `grid = img.reshape(Hc // P, P, Wc // P, P, -1).swapaxes(1, 2)  # (gh,gw,P,P,C)` and
    `tok_per_frame = gh * gw`. Steps 2 and 4 are that function; the reference reproduces it for a
    2-D frame, where the trailing channel axis the material carries with `-1` is simply absent.
  - *"A partial patch is not a patch"* — the crop line above is the material's own answer to
    non-divisible frames.
  - *Tubelets and the token division* — §5, **lines 1945–1946** ("A **tubelet** generalizes this to
    a `P×P×t` space-time cube, dividing the token count by the tubelet depth `t`") and the printed
    comparison at **lines 1964–1972** (`toks = tok_per_frame * (T // depth)`).
  - *Why token count is the number to watch* — the `(attention ∝ {toks}²)` annotation at line 1971;
    motivation only, nothing graded depends on it.
  - **Disclosed, not taught:** the per-patch **mean** as a reported statistic, and the row-major
    index it is keyed by. The material cuts patches and displays them as a mosaic (lines 1978–1996)
    but never reduces one to a number; step 4 defines both the statistic and the ordering.
- **Determinism.** Integer arithmetic, one `np.linspace(...).round()`, and means over float64
  slices. Both cases re-run byte-identical.
- Compare the counts and `"grid"` exactly, `"frame_indices"` element-wise, and each patch mean with
  tolerance `1e-4`. Dictionary key order is not significant at either level; `"patch_means"` keys are
  integers, not strings.
- **No rounding ties, deliberately.** `np.round` breaks a `.5` tie to the nearest **even** integer,
  so a tie would split solutions using `round()` from those using `int(x + 0.5)`. Both cases were
  checked: the minimum distance from any sampled position to a `.5` boundary is `0.0714` (case 1)
  and `0.1000` (case 2). Any new case must be re-checked.
- **What each case is for:**
  - **Case 1** — `10 × 14` at patch 4 crops on **both** axes (to `8 × 12`), giving a 2×3 grid; its
    sampling schedule is the material's own printed list.
  - **Case 2** — `9 × 6` at patch 3 divides **exactly** on both axes, so the crop is a no-op and the
    grid is 3×2 — a transposed aspect that catches any solution reporting the grid as
    `[columns, rows]`. Its 250 frames / 16 samples / depth 4 mirror a real 16-frame model input.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Patch means without cropping first** (reshaping the full frame with a ragged final patch):
    raises `ValueError: cannot reshape array` on case 1 — a loud failure, and case 2 is unaffected,
    so case 1 must stay.
  - **Column-major patch indexing**: case 1's means become
    `{0: 0.6248, 1: 0.5951, 2: 0.4434, ...}` — the same six values in a different order, so the
    dictionary comparison catches it while any order-insensitive check would not. Compare per key.
  - **Omitting `.swapaxes(1, 2)`**: means become
    `{0: 0.6248, 1: 0.4434, 2: 0.3636, 3: 0.5951, ...}` on case 1 — unchanged, because the axis
    swap reorders *within* the grid tuple, not across patches, for this layout. It is therefore an
    **accepted** route here; the material's own spelling keeps it for the general `(gh,gw,P,P,C)`
    case.
  - **Truncating instead of rounding** the sample positions: `[0, 5, 11, 16, 22, 27, 33, 39]` and
    `[0, 16, 33, 49, 66, 83, 99, …]` — caught on both.
  - **Spanning `0…T` instead of `0…T-1`**: `[0, 6, 11, 17, 23, 29, 34, 40]` — caught on both, and it
    indexes one frame past the end.
  - **Tubelet count as `tokens_per_frame * n_sampled // tubelet_depth` with integer division applied
    last**: identical here (both `tubelet_depth` values divide `n_sampled`), so it is accepted; the
    statement guarantees divisibility.
- **Overlap check:** nothing in the topic-organized bank touches video.
- Both cases executed against the reference solution.

---

## Q4: Full 3-D Convolution vs the Factorized (2+1)D Pair

**Context:** A 3-D kernel mixes space and time in one operation, and its footprint grows with the
cube of the kernel size — which is why 3-D convolutional models are capped at a few dozen frames
per clip. Factorizing the layer into a 2-D convolution over the frame plane followed by a 1-D
convolution along time keeps a comparable receptive field while collapsing that spatio-temporal
factor from `k³` to `k² + k`. That scale-free footprint comparison is only half the story,
though: a real layer also pays for its input and output channel counts, and the factorized
version introduces an intermediate width between its two stages. Both numbers are worth having
before committing to a backbone.

**Problem Statement:**

Write a function `conv_param_gap(c_in, c_out, c_mid, k_t, k_h, k_w)`.

1. The full 3-D layer convolves `c_in` input channels into `c_out` output channels with one
   kernel spanning `k_t` frames × `k_h` rows × `k_w` columns.
2. The factorized alternative is two layers back to back: a spatial convolution whose
   `k_h × k_w` kernel maps `c_in` channels to the intermediate width `c_mid`, followed by a
   temporal convolution whose `k_t`-long kernel maps `c_mid` channels to `c_out`. No layer here
   trains a bias term — not the two factorized ones and not the full 3-D one.
3. Report each option's **kernel footprint**: the number of weights in one kernel, counting only
   its spatial and temporal extent and ignoring channels entirely. For the factorized pair that
   is the spatial kernel's footprint plus the temporal kernel's.
4. Report each option's full **parameter count**, channels included.
5. Report how many times larger the full 3-D layer's parameter count is than the factorized
   pair's, rounded to 2 decimal places.
6. Return a dictionary with exactly these five keys:
   - `"footprint_full"` — the full 3-D kernel's footprint, as an integer
   - `"footprint_factorized"` — the factorized pair's footprint, as an integer
   - `"full_params"` — the full 3-D layer's parameter count, as an integer
   - `"factorized_params"` — the factorized pair's parameter count, as an integer
   - `"param_ratio"` — the ratio from step 5, as a float

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: c_in (integer)
    Single line: one integer
  Argument 2: c_out (integer)
    Single line: one integer
  Argument 3: c_mid (integer)
    Single line: one integer
  Argument 4: k_t (integer)
    Single line: one integer
  Argument 5: k_h (integer)
    Single line: one integer
  Argument 6: k_w (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `conv_param_gap()` on a new line.

**Sample Input:**

```
c_in  = 64
c_out = 128
c_mid = 144
k_t   = 3
k_h   = 3
k_w   = 3
```

**Sample Output:**

```
{'footprint_full': 27, 'footprint_factorized': 12, 'full_params': 221184, 'factorized_params': 138240, 'param_ratio': 1.6}
```

**Note:** The input handling is already in place — you only need to implement the function. This
is arithmetic on a layer specification: nothing is built, initialised or run.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: conv_param_gap
RETURN TYPE: Dictionary

ARGUMENTS:
1. c_in   → Integer
2. c_out  → Integer
3. c_mid  → Integer
4. k_t    → Integer
5. k_h    → Integer
6. k_w    → Integer
```

(`c_mid` carries a default in every real factorized-convolution implementation — required here
and supplied in every test case. Five values must come back, so they fold into one
`Dictionary`.)

**Reference Solution:**

```python
def conv_param_gap(c_in: int, c_out: int, c_mid: int,
                   k_t: int, k_h: int, k_w: int) -> dict:
    footprint_full = k_t * k_h * k_w
    footprint_factorized = k_h * k_w + k_t

    full_params = footprint_full * c_in * c_out
    factorized_params = k_h * k_w * c_in * c_mid + k_t * c_mid * c_out

    return {
        "footprint_full": footprint_full,
        "footprint_factorized": footprint_factorized,
        "full_params": full_params,
        "factorized_params": factorized_params,
        "param_ratio": round(full_params / factorized_params, 2),
    }
```

**Test Cases —** `in.txt`

```
2
64
128
144
3
3
3
192
384
288
5
7
7
```

**Test Cases —** `out.txt`

```
{'footprint_full': 27, 'footprint_factorized': 12, 'full_params': 221184, 'factorized_params': 138240, 'param_ratio': 1.6}
{'footprint_full': 245, 'footprint_factorized': 54, 'full_params': 18063360, 'factorized_params': 3262464, 'param_ratio': 5.54}
```

**Grader Notes:**

- **Scope trace.** Every technique traces to §4b of
  `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities.md`:
  - *The kernel-footprint comparison* — lines 1841–1844: "A 3-D kernel `k×k×k` … costs `∝ k³`
    per channel pair… Factorizing into a 2-D **spatial** conv followed by a 1-D **temporal** conv
    keeps the receptive field while collapsing the *spatio-temporal* factor from `k³` to
    `k²+k`." The printed cell (lines 1905–1911, output 1928–1932) reports
    `full 3-D params = 27 (k³)`, `(2+1)D params = 12 (k² + k)`,
    `parameter ratio full / (2+1)D = 2.25x` and `at k=11 the ratio grows to 10.08x`. Steps 3
    and 5 are those two quantities.
  - *The channel-aware parameter counts* — lines 1846–1853, printed as a formula block:
    `full 3-D conv : k_t · k_h · k_w · C_in · C_out` and
    `(2+1)D conv : (k_h · k_w · C_in · C_mid) + (k_t · C_mid · C_out)`. Step 2 describes those
    two stages structurally (spatial `c_in → c_mid`, then temporal `c_mid → c_out`) and step 4
    asks for the counts; the reference solution is those two expressions.
  - *No bias terms* — the source formulas contain no bias, which is why step 2 states it; also
    the recap, line 2548–2549: "Full 3-D conv's kernel footprint is `∝ k³`; factorized `(2+1)D`
    is `∝ k²+k` for the same receptive field (multiply by channels for the true param/FLOP
    budget)."
  - *R(2+1)D / S3D as the named family* — line 1856 and the model-family table, line 2014. Both
    test cases are plain layer specifications, so nothing needs to be recalled about either
    paper.
  - The source material computes these figures as **plain Python integer arithmetic** on scalars
    (`K**3`, `K**2 + K`), reaching for numpy only to plot the curve over a range of `k`. The
    reference solution therefore uses plain arithmetic and imports nothing; a numpy-based
    solution returning the same integers is equally acceptable.
- **Cross-checked against the printed figures.** Running the reference with unit channels
  (`c_in = c_out = c_mid = 1`) reproduces the source material's own output exactly: at `k = 3`,
  `{'footprint_full': 27, 'footprint_factorized': 12, 'full_params': 27, 'factorized_params': 12,
  'param_ratio': 2.25}`; at `k = 11`, footprints `1331` and `132` with `'param_ratio': 10.08` —
  matching the printed `2.25x` and `10.08x`.
- **Determinism.** Exact integer arithmetic plus one division rounded to 2 places. Compare the
  four integers exactly and `"param_ratio"` with tolerance `1e-2`.
- **Case 2's channel widths are deliberately all different.** An earlier draft used
  `c_in = c_out = c_mid = 256`, which makes the parameter ratio algebraically **equal** to the
  footprint ratio (the common `C²` cancels) and let three separate wrong readings return the
  correct answer. `192 / 384 / 288` breaks that degeneracy: the footprint ratio is `4.54` while
  the parameter ratio is `5.54`. Do not "simplify" the case back to equal widths.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Returning the footprint ratio as `param_ratio`** (`k³ / (k²+k)`, the scale-free number):
    `2.25` and `4.54` against `1.6` and `5.54` — caught on both, but only because of the bullet
    above.
  - **`footprint_factorized` as `k_h + k_w + k_t`** instead of `k_h·k_w + k_t`: `9` and `19`
    against `12` and `54` — caught on both.
  - **`full_params` without channels** (returning the footprint twice): `27` and `245` — caught
    on both.
  - **Ignoring `c_mid`** and routing `c_in → c_out` through both factorized stages
    (`k_h·k_w·c_in·c_out + k_t·c_in·c_out`): `98304` and `3981312` against `138240` and
    `3262464` — caught on both.
  - **Giving the temporal stage a full 3-D kernel** (`k_t·k_h·k_w·c_mid·c_out` for stage two):
    `580608` and `29804544` — caught on both.
  - **Swapping the two stages' channel roles** (spatial `c_mid → c_out`, temporal
    `c_in → c_mid`): `193536` and `5695488` — caught on both, again only because the widths
    differ.
  - **Inverting the ratio** (factorized ÷ full): `0.62` and `0.18` — caught on both.
- **Accepted routes:** any spelling of the same integer arithmetic. There is no library choice to
  make and no floating-point path other than the final division, so no alternative needed
  checking beyond the wrong readings above.
- **Overlap check:** the topic-organized bank
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`) has
  two parameter-counting questions — Q1 `lora_param_budget` and Q3 KV-cache sizing — and this
  file's sibling `M2-L4-fine-tuning-existing-models.md` has a third (`lora_trainable_reduction`).
  All three count parameters of **attention/adapter** matrices and end in a reduction percentage
  or a byte figure. This question counts **convolution kernel** parameters and returns a ratio
  plus two channel-free footprints, so the arithmetic being exercised is different; still, avoid
  stacking more than two "count the parameters" questions in one paper.
- Both cases executed against the reference solution (Python 3.12.13, standard library only);
  0.03 s for the whole file.
