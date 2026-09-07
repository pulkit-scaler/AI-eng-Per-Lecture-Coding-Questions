# Module 2, Lecture 5 (Part 2) — AI Modalities: Video

Two coding questions on the runnable half of the video material: **measuring the temporal redundancy**
that motivates every design decision in video AI, and turning it into a uniform sampling schedule
(Q1); and **tubelet tokenisation** with the VideoMAE masking budget and the clip's memory cost (Q2).

Neither downloads anything and neither needs a GPU. Q1 works on a real clip tensor in `torch`; Q2 is
integer arithmetic on a clip specification — the video material's own tokenisation cell is itself a
counting exercise, so that is what there is to grade.

**Scope note.** This file, with its audio sibling, replaces an earlier `M2-L5-ai-modalities.md`
written against the previous version of this lecture. That lecture taught **full 3-D convolution
against the factorized (2+1)D pair** (`k³` vs `k²+k`) and a **per-frame patchify with a tubelet
depth divisor**; the current one teaches neither. It covers the 4-D tensor and its memory cost,
temporal and spatial redundancy, frame-sampling strategies, the three generations of video models,
3-D tubelet tokenisation and VideoMAE masking. The old questions have been retired rather than
patched; the superseded file is kept at `superseded/M2-L5-ai-modalities-pre-2026-08-24.md`.

---

## Q1: Measuring Temporal Redundancy and Sampling Around It

**Context:** Video is massively redundant. Adjacent frames of a talking head differ by a slight
movement of the mouth and nothing else, so a model fed every frame spends most of its compute
re-reading what it already knows. That is why the first question asked of a clip is how much it
actually changes from frame to frame — the change is the signal, and what stays the same is the
redundancy. Once you have that measurement you can justify the standard remedy: keep a small fixed
number of frames spread evenly across the clip, and accept the order-of-magnitude reduction that buys.

**Problem Statement:**

Using `torch` and `numpy`, write a function `clip_redundancy_report(clip, n_sampled)`.

1. `clip` is a clip whose rows are frames in order: row `t` holds frame `t`'s pixel values, already
   flattened. Report how many frames it holds, and how many adjacent frame pairs that gives.
2. For each adjacent pair, measure the change as the **mean absolute difference** between the two
   frames' pixel values. Report the mean of those per-pair measurements, rounded to 4 decimal places.
3. Report which pair changed most and which changed least, identified by the index of the **later**
   frame in the pair — so the pair (frame 0, frame 1) is reported as `1`. When several pairs tie,
   report the earliest.
4. Choose `n_sampled` frames spread evenly across the whole clip: the first sampled frame is frame
   `0`, the last is the clip's final frame, and each position in between is rounded to the nearest
   whole frame index. Report the indices in increasing order.
5. Report the reduction the sampling buys — the frame count divided by `n_sampled`, rounded to 4
   decimal places.
6. Return a dictionary with exactly these seven keys: `"num_frames"`, `"num_pairs"`,
   `"max_change_pair"` and `"min_change_pair"` as integers, `"mean_abs_change"` and
   `"reduction_factor"` as floats, and `"sampled_indices"` as a list of integers.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: clip (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
      (row t is frame t, flattened — R is the frame count)
  Argument 2: n_sampled (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `clip_redundancy_report()` on a new line.

**Sample Input:**

```
clip = tensor([[10., 10., 10., 10.],
               [10., 11., 12., 10.],
               [10., 40., 12., 10.],
               [12., 41., 12., 11.],
               [90., 41., 12., 11.],
               [90., 44., 13., 11.]])
n_sampled = 3
```

**Sample Output:**

```
{'num_frames': 6, 'num_pairs': 5, 'mean_abs_change': 5.9, 'max_change_pair': 4, 'min_change_pair': 1, 'sampled_indices': [0, 2, 5], 'reduction_factor': 2.0}
```

**Note:** The input handling is already in place — you only need to implement the function. No video
is decoded: the clip arrives as a `float32` tensor with one row per frame, so the pixel layout inside
a frame never matters — every measurement here is over a whole frame at once. The sampled indices
span the clip inclusively at both ends, so the first and last frames are always among them.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: clip_redundancy_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. clip      → Torch 2D Tensor
2. n_sampled → Integer
```

(`n_sampled` is the material's `n=8` default — required here and supplied in every test case. Seven
values must come back, so they fold into one `Dictionary`. `Torch 2D Tensor` is argument-only, which
is no obstacle: only scalars and a short index list leave the function. A clip is naturally 4-D,
but no 3-D or 4-D tensor argument type exists, so frames arrive flattened one per row — stated in the
Input Format and in step 1.)

**Reference Solution:**

```python
import numpy as np
import torch


def clip_redundancy_report(clip: torch.Tensor, n_sampled: int) -> dict:
    num_frames = clip.shape[0]

    diffs = [float(torch.mean(torch.abs(clip[i] - clip[i - 1])))
             for i in range(1, num_frames)]

    idx = np.linspace(0, num_frames - 1, n_sampled).round().astype(int)

    return {
        "num_frames": int(num_frames),
        "num_pairs": len(diffs),
        "mean_abs_change": round(float(np.mean(diffs)), 4),
        "max_change_pair": int(np.argmax(diffs)) + 1,
        "min_change_pair": int(np.argmin(diffs)) + 1,
        "sampled_indices": idx.tolist(),
        "reduction_factor": round(num_frames / n_sampled, 4),
    }
```

**Test Cases —** `in.txt`

```
2
6 4
10.0 10.0 10.0 10.0
10.0 11.0 12.0 10.0
10.0 40.0 12.0 10.0
12.0 41.0 12.0 11.0
90.0 41.0 12.0 11.0
90.0 44.0 13.0 11.0
3
10 3
0.0 2.0 4.0
1.0 2.0 4.0
7.0 9.0 12.0
7.0 9.0 13.0
20.0 22.0 25.0
20.0 23.0 25.0
40.0 44.0 48.0
41.0 44.0 48.0
42.0 46.0 51.0
80.0 88.0 96.0
4
```

**Test Cases —** `out.txt`

```
{'num_frames': 6, 'num_pairs': 5, 'mean_abs_change': 5.9, 'max_change_pair': 4, 'min_change_pair': 1, 'sampled_indices': [0, 2, 5], 'reduction_factor': 2.0}
{'num_frames': 10, 'num_pairs': 9, 'mean_abs_change': 9.5556, 'max_change_pair': 9, 'min_change_pair': 1, 'sampled_indices': [0, 3, 6, 9], 'reduction_factor': 2.5}
```

**Grader Notes:**

- **Environment:** `torch` 2.13.0 and `numpy` 2.5.2 on Python 3.12.13, CPU. Milliseconds per case.
- **The tensor work produces the graded value.** `mean_abs_change` and the two extreme-pair indices
  come out of real per-frame arithmetic over the supplied clip; nothing about them follows from the
  clip's shape. The sampling schedule and the reduction factor are the arithmetic half.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities_Video.md`:
  - *Why redundancy is the organising idea* — **lines 69 and 71**: "**Temporal redundancy** —
    adjacent frames are nearly identical… You're storing huge amounts of near-identical information",
    and its spatial counterpart; plus the recap at **line 351**: "Adjacent frames are nearly
    identical — change is the signal".
  - *The measurement* — **line 107**, verbatim:
    `diffs = [np.mean(np.abs(clip[i].astype(float) - clip[i-1].astype(float))) for i in range(1, len(clip))]`,
    under the heading "Demo — Measuring temporal redundancy" and described in the plot title as
    "Mean absolute pixel change per frame pair". Steps 1–3 are that line: the same index range, the
    same reduction, and the same one-fewer-pair-than-frames count.
  - *Uniform sampling* — **lines 185–186**, verbatim:
    `def uniform_sample(clip, n=8): idx = np.linspace(0, len(clip)-1, n).round().astype(int)`, whose
    printed output at **line 224** is `[0, 4, 8, 12, 17, 21, 25, 29]` for a 30-frame clip. Step 4 is
    that expression stated as a constraint.
  - *The reduction it buys* — **line 160**: "Most video models use **8–32 frames** sampled uniformly
    from the clip. A 10-second clip at 30 fps (300 frames) gets reduced to 8–32 representative
    frames — roughly a **10–40× reduction**." Step 5 is that ratio.
  - **Disclosed, not taught:**
    - Reporting *which* pair changed most or least. The material plots the per-pair curve and marks
      its mean but never names an extreme; step 3 defines the identification, the `+1` convention and
      the tie rule.
    - The flattened one-row-per-frame layout. The material's clip is `(T, H, W, 3)`; the descriptor
      tool has no 4-D argument type, so the frames arrive flattened. Nothing graded depends on the
      pixel layout inside a frame — every measurement is a whole-frame mean — so the flattening is
      lossless for this question, and step 1 says so.
    - **Not asked for:** motion-based sampling. The material shows it (lines 188–196) but it draws
      from `np.random.choice`, so it has no reproducible answer and is deliberately out of scope.
- **Determinism.** Float32 means over exactly representable values, plus one
  `np.linspace(...).round()`. Both cases re-run byte-identical.
- Compare the four integers exactly, `"sampled_indices"` element-wise, and the two floats with
  tolerance `1e-4`.
- **No rounding ties in the sampling, deliberately.** `np.round` breaks a `.5` tie to the nearest
  even integer, which would split `round()` solutions from `int(x + 0.5)` ones. Case 1 samples
  `{0, 2.5, 5}` — **which does contain a tie at 2.5**, and `np.round` resolves it **down** to 2.
  This is intentional: it is the one case that pins the convention, and a solution using
  `int(x + 0.5)` returns `[0, 3, 5]` and is caught. Case 2's positions are `{0, 3, 6, 9}`, all
  integral. If case 1 is ever edited, keep a `.5` position or the convention goes untested.
- **What each case is for:**
  - **Case 1** — six frames with a deliberately uneven change profile: the largest jump is pair 4
    (frame 3 → 4, where the first pixel goes 12 → 90) and the smallest is pair 1. It also carries the
    `.5` sampling tie described above.
  - **Case 2** — ten frames where the changes increase towards the end, so the largest pair is the
    **last** one (pair 9) rather than an interior one, and `n_sampled` divides the frame count
    unevenly (10 / 4 = 2.5). A solution reporting the reduction as an integer is caught here.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Pair indices reported by the earlier frame** (no `+1`): 3 / 0 and 8 / 0 against 4 / 1 and
    9 / 1 — caught on both.
  - **Signed mean difference instead of absolute** (`torch.mean(clip[i] - clip[i-1])`): case 1's
    `mean_abs_change` becomes 5.9 as well — the clip is monotonically increasing, so the two agree —
    but case 2 gives 8.4444 against 9.5556. **Caught by case 2 only; it must stay in any shipped
    subset.**
  - **Diffs taken over `range(0, num_frames)`** (an out-of-range first pair): raises `IndexError`
    on `clip[-1]`? No — `clip[-1]` wraps to the last frame, silently producing an extra huge pair;
    `num_pairs` becomes 6 / 10 and `mean_abs_change` 14.9167 / 20.4 — caught on both, and worth
    noting because Python's negative indexing makes this a *silent* error rather than a crash.
  - **Sampling `0…num_frames` instead of `0…num_frames − 1`**: `[0, 3, 6]` / `[0, 3, 7, 10]` — caught
    on both, and the second indexes one frame past the end.
  - **Truncating the sampled positions instead of rounding**: `[0, 2, 5]` on case 1 — identical, since
    2.5 rounds down anyway — and `[0, 3, 6, 9]` on case 2, also identical. So truncation is **not**
    caught by either shipped case; it is caught only where a position rounds *up*. Noted rather than
    claimed covered; add a third case if this matters.
  - **Reduction as `n_sampled / num_frames`**: 0.5 / 0.4 — caught on both.
- **Overlap check:** Q2 of this file never touches pixel values — it works from a clip
  *specification*. Nothing in the topic-organized bank
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`) touches
  video. No shared graded value.
- Both cases executed against the reference solution.

---

## Q2: Tubelet Tokens, the VideoMAE Mask, and What the Clip Costs

**Context:** A video transformer does not consume frames; it consumes tokens. The clip is cut into
small three-dimensional cubes — a few frames deep, a few pixels across — and each cube is flattened
into one token. That gives a token grid with a temporal axis as well as two spatial ones, and the
token count is what decides whether the clip fits: attention cost grows with its square. Self-
supervised pretraining then exploits the redundancy directly, hiding the overwhelming majority of
those tokens and asking the model to reconstruct them from the few that remain. Sizing all of this
before a run is a matter of dividing the clip up correctly and counting.

**Problem Statement:**

Write a function
`tubelet_budget(num_frames, height, width, channels, tubelet_frames, patch_size, keep_ratio, bytes_per_value)`.

1. The clip has shape `(num_frames, height, width, channels)`. Cut it into tubelets that span
   `tubelet_frames` frames and `patch_size × patch_size` pixels. Report the token grid as three
   separate counts — how many tubelets fit along time, along height, and along width — taking only
   whole tubelets along each axis and discarding any partial remainder.
2. Report the total number of tokens the grid holds, and the length of one token's flattened vector —
   every value inside one tubelet, across all channels.
3. Masked pretraining keeps only a fraction `keep_ratio` of the tokens visible. The number kept is
   that fraction of the token total, truncated to a whole number, but never fewer than one. Report
   how many tokens stay visible, how many are masked, and the masked share as a percentage of the
   total rounded to 2 decimal places.
4. Report what the raw clip costs in memory: every value occupies `bytes_per_value` bytes, and the
   total is expressed in megabytes of 10^6 bytes each, rounded to 2 decimal places.
5. Return a dictionary with exactly these nine keys: `"grid_t"`, `"grid_h"`, `"grid_w"`,
   `"num_tokens"`, `"token_dim"`, `"visible_tokens"` and `"masked_tokens"` as integers, and
   `"masked_pct"` and `"clip_mb"` as floats.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: num_frames (integer)
    Single line: one integer
  Argument 2: height (integer)
    Single line: one integer
  Argument 3: width (integer)
    Single line: one integer
  Argument 4: channels (integer)
    Single line: one integer
  Argument 5: tubelet_frames (integer)
    Single line: one integer
  Argument 6: patch_size (integer)
    Single line: one integer
  Argument 7: keep_ratio (float)
    Single line: one float
  Argument 8: bytes_per_value (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `tubelet_budget()` on a new line.

**Sample Input:**

```
num_frames      = 8
height          = 56
width           = 56
channels        = 3
tubelet_frames  = 2
patch_size      = 14
keep_ratio      = 0.10
bytes_per_value = 4
```

**Sample Output:**

```
{'grid_t': 4, 'grid_h': 4, 'grid_w': 4, 'num_tokens': 64, 'token_dim': 1176, 'visible_tokens': 6, 'masked_tokens': 58, 'masked_pct': 90.62, 'clip_mb': 0.3}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded and no clip is built: every figure follows from the eight numbers. The visible-token count
is truncated rather than rounded, so a ratio of one tenth on 64 tokens keeps 6 and not 7 — and the
masked share that follows is therefore not exactly the complement of `keep_ratio`.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: tubelet_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. num_frames      → Integer
2. height          → Integer
3. width           → Integer
4. channels        → Integer
5. tubelet_frames  → Integer
6. patch_size      → Integer
7. keep_ratio      → Float
8. bytes_per_value → Integer
```

(`keep_ratio` is the material's fixed 0.10 — required here and supplied in every test case, with two
other values exercised. Nine values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
def tubelet_budget(num_frames: int, height: int, width: int, channels: int,
                   tubelet_frames: int, patch_size: int, keep_ratio: float,
                   bytes_per_value: int) -> dict:
    grid_t = num_frames // tubelet_frames
    grid_h = height // patch_size
    grid_w = width // patch_size

    num_tokens = grid_t * grid_h * grid_w
    token_dim = tubelet_frames * patch_size * patch_size * channels

    visible = max(1, int(num_tokens * keep_ratio))
    masked = num_tokens - visible

    clip_bytes = num_frames * height * width * channels * bytes_per_value

    return {
        "grid_t": grid_t,
        "grid_h": grid_h,
        "grid_w": grid_w,
        "num_tokens": num_tokens,
        "token_dim": token_dim,
        "visible_tokens": visible,
        "masked_tokens": masked,
        "masked_pct": round(100.0 * masked / num_tokens, 2),
        "clip_mb": round(clip_bytes / 1e6, 2),
    }
```

**Test Cases —** `in.txt`

```
3
8
56
56
3
2
14
0.10
4
16
224
224
3
2
16
0.25
4
300
224
224
3
4
16
0.10
4
```

**Test Cases —** `out.txt`

```
{'grid_t': 4, 'grid_h': 4, 'grid_w': 4, 'num_tokens': 64, 'token_dim': 1176, 'visible_tokens': 6, 'masked_tokens': 58, 'masked_pct': 90.62, 'clip_mb': 0.3}
{'grid_t': 8, 'grid_h': 14, 'grid_w': 14, 'num_tokens': 1568, 'token_dim': 1536, 'visible_tokens': 392, 'masked_tokens': 1176, 'masked_pct': 75.0, 'clip_mb': 9.63}
{'grid_t': 75, 'grid_h': 14, 'grid_w': 14, 'num_tokens': 14700, 'token_dim': 3072, 'visible_tokens': 1470, 'masked_tokens': 13230, 'masked_pct': 90.0, 'clip_mb': 180.63}
```

**Grader Notes:**

- **Environment:** standard library only, Python 3.14 or 3.12. Microseconds per case.
- **This question is arithmetic, and that is what the material supports.** The video lecture's
  tokenisation cell is itself a counting exercise — it builds a synthetic clip only to draw a grid
  over it, and every number it prints comes from integer division. There is no library call to grade
  here, and inventing one (a strided `Conv3d` used as a patch embedder, say) would import machinery
  the material never shows. Q1 of this file carries the real tensor work for video.
- **Case 1 reproduces the material's printed demo exactly.** Its cell sets `T, H, W = 8, 56, 56` and
  `Pt, P = 2, 14`, then prints `Grid: 4 temporal × 4×4 spatial = 64 tokens`,
  `Each token: 1176 numbers  (flattened tubelet)` and
  `VideoMAE masking: keep 6/64 tokens (9%), mask 58 (91%)` — matching `grid_t/h/w`, `num_tokens`,
  `token_dim`, `visible_tokens` and `masked_tokens` on case 1. (The material prints the share to
  0 decimals as 91%; this question reports 90.62, which is the same quantity unrounded.)
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities_Video.md`:
  - *The clip's shape* — **line 46**, the `(T,  H,   W,   C)` diagram with its axis labels.
  - *The memory cost, and the 10^6 convention* — **lines 54–55**: "16 frames × 224 × 224 × 3 × 4
    bytes ≈ **9.7 MB per clip** (float32).  A training batch of 8 clips = **77 MB**" and
    "300 frames × 224 × 224 × 3 × 4 bytes ≈ **181 MB per clip**". Case 2 is the first of those and
    case 3 the second. **The batch figure is what fixes the convention:** 16×224×224×3×4 is
    9,633,792 bytes, which is 9.19 MiB but 9.63 MB — and 8 × 9.63 = 77.0, the material's own "77 MB".
    Case 3's 180.63 likewise rounds to the material's 181. Step 4 therefore pins 10^6, not 2^20; a
    solution using MiB returns 9.19 / 172.27 and is caught by cases 2 and 3.
  - *Tubelets as 3-D patch tokens* — **line 262**: "divide the clip into small **3-D patches
    (tubelets)** — tiny cubes that span a few pixels × a few frames — and treat each as a token", and
    the recap at **line 355**.
  - *The grid arithmetic and the token length* — **lines 290–298**, verbatim: `Pt, P = 2, 14`,
    `n_t = T // Pt`, `n_tokens = n_t * n_h * n_w`, and
    `print(f"Each token:  {Pt * P * P * 3} numbers  (flattened tubelet)")`. Steps 1 and 2 are those
    four lines; the `channels` argument is that literal `3` made explicit.
  - *The masking rule* — **line 319**, verbatim:
    `keep_n      = max(1, int(n_tokens * 0.10))   # keep only 10%`, and the 90% figure in prose at
    **line 270** ("mask out **90%** of tubelets"). Step 3 is that line, including both the truncation
    and the floor of one.
  - *Why the token count is the number to watch* — **line 264** on the O(T² H² W²) cost of undivided
    attention; motivation only, nothing graded depends on it.
  - **Disclosed, not taught:**
    - The masked *percentage* as a reported number. The material prints it to zero decimals inside an
      f-string; step 3 fixes 2 decimals.
    - Discarding a partial tubelet at an axis's end. The material's dimensions all divide exactly, so
      it never faces the question; step 1 states the rule, and case 3 is the case where it bites.
- **Determinism.** Integer arithmetic and two roundings. All three cases re-run byte-identical.
- Compare the seven integers exactly; `"masked_pct"` and `"clip_mb"` with tolerance `1e-2`.
- **What each case is for:**
  - **Case 1** — the material's own printed demo, and the only case where the truncation in step 3
    is observable: 64 × 0.10 is 6.4, so 6 tokens stay visible and the masked share is 90.62 rather
    than exactly 90. A solution that rounds returns 6 as well — `round(6.4)` is 6 — but one that
    uses `ceil` returns 7 and 89.06, and is caught here only.
  - **Case 2** — the material's 9.7 MB clip at a **different** keep ratio (0.25), where 1568 × 0.25
    is exactly 392 so the truncation is invisible, and `masked_pct` is exactly 75.0. It is the case
    that pins the MB convention.
  - **Case 3** — 300 frames at `tubelet_frames = 4`: 300 // 4 = 75 exactly, but **224 // 16 = 14 with
    no remainder either**, so the partial-tubelet rule is still not exercised. Noted honestly: none
    of the three shipped cases has a non-dividing axis. If that rule matters to you, add a case with,
    say, `height = 230`; as shipped, step 1's discard clause is a specification rather than a graded
    distinction.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **MiB instead of MB** (dividing by 1024²): `clip_mb` 0.29 / 9.19 / 172.27 against 0.3 / 9.63 /
    180.63 — caught by all three, and by cases 2 and 3 against the material's own printed figures.
  - **Rounding the visible count up** (`math.ceil`): case 1 gives 7 visible, 57 masked, 89.06% —
    caught by case 1 only.
  - **Dropping the floor of one**: no shipped case has a token count small enough for
    `int(n * ratio)` to reach 0, so this is **not** caught. It would need a case with fewer than 10
    tokens at a 0.10 ratio. Noted rather than claimed covered.
  - **`token_dim` without channels**: 392 / 512 / 1024 against 1176 / 1536 / 3072 — caught on all
    three.
  - **`token_dim` using the whole clip's frame count instead of the tubelet's**: 4704 / 12288 /
    230400 — caught on all three.
  - **Grid computed with rounding instead of floor division**: identical on all three, since every
    axis divides exactly — see the case note above.
  - **`masked_pct` computed against `keep_ratio` rather than the actual counts**
    (`100 * (1 - keep_ratio)`): 90.0 / 75.0 / 90.0 against 90.62 / 75.0 / 90.0 — **caught by case 1
    only**, which is the case that exists for exactly this reason.
- **Overlap check:** Q1 of this file measures a real clip and never counts tokens. The previous
  version of this question folded per-frame patchify and a tubelet *depth divisor* into one answer;
  the current material tokenises with a genuine 3-D grid, so the shape of the question changed with
  it. Nothing in the topic-organized bank touches video.
- All three cases executed against the reference solution.
