# Module 2, Lecture 7 — Model Quantization Techniques

Four coding questions spanning the material's four distinct threads: **granularity** (a scale per
group of weights instead of one per tensor), **the 16-bit float formats** (which numbers a bit
layout can actually hold), **calibration** (turning an observed activation range into frozen
quantization parameters, and paying for it when live data escapes that range), and the
**ternary / 1.58-bit regime**.

None of them loads a model, downloads anything, or needs a GPU — every one is `torch` tensor
arithmetic, which is the language the source material's own quantizer is written in. All four are
fully deterministic: each question's two-case run completes in **~0.4 s** wall clock (almost all of
it the `torch` import), and every reported float was re-checked in float64 as well as float32 with
byte-identical results.

Deliberately **not** another per-tensor / per-channel symmetric-or-asymmetric INT8 quantize →
dequantize → MSE question; that ground is already covered by the topic-organized bank's Q2 and Q5
(see each question's overlap check).

---

## Q1: Per-Group Quantization Against a Single Tensor-Wide Scale

**Context:** Granularity is the first dial you turn when INT8 weights cost you accuracy. One scale
for an entire weight matrix is the cheapest possible mapping — a single number of metadata, no
per-row bookkeeping — but it is set by the largest magnitude anywhere in the matrix, so one outlier
squeezes every ordinary weight into a handful of integer codes. Cutting the weights into
fixed-size groups and giving each group its own scale confines that damage to the group holding the
outlier, at the cost of storing one extra float per group. Whether that trade is worth making is an
empirical question: quantize both ways, dequantize both, and compare the reconstruction error and
the metadata each way demands.

**Problem Statement:**

Using the `torch` library, write a function `per_group_quantization_report(weights, group_size)`.

1. Both schemes below use **symmetric (absmax)** INT8 quantization: for a given set of values the
   scale is that set's largest absolute value divided by the largest positive INT8 code, and no
   zero-point/offset is used. Signed INT8 spans `[-128, 127]`. A code is rounded to the nearest
   integer and then held inside that range.
2. **Per-group:** read `weights` as a flat sequence of its elements in row-major order and cut that
   sequence into consecutive groups of exactly `group_size` elements. Every group gets its own
   independently computed scale. `group_size` always divides the number of columns.
3. Dequantize the per-group codes using the group scale that produced each of them, and compute the
   mean squared error against `weights`, averaged over all elements.
4. **Per-tensor:** quantize and dequantize the same tensor again using one scale computed from the
   whole tensor, and compute its mean squared error the same way.
5. Return a dictionary with exactly five keys:
   - `"num_groups"` — how many groups the tensor was cut into
   - `"num_scales"` — how many scale values the per-group scheme has to store alongside its codes
   - `"mse_per_group"` — the per-group reconstruction error, rounded to 6 decimal places
   - `"mse_per_tensor"` — the per-tensor reconstruction error, rounded to 6 decimal places
   - `"error_reduction_pct"` — the percentage of the per-tensor error that the per-group scheme
     removes, rounded to 2 decimal places

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: weights (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: group_size (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `per_group_quantization_report()` on a new line.

**Sample Input:**

```
weights = [[ 0.82, -1.34,  0.05,  2.10, -0.47,  0.93],
           [88.50, -0.62,  0.31, -1.75,  0.08,  1.42],
           [-0.24,  0.66, -2.98,  0.51, -0.13,  0.77],
           [ 1.05, -0.39,  0.22, -0.94,  3.61, -1.28]]
group_size = 3
```

**Sample Output:**

```
{'num_groups': 8, 'num_scales': 8, 'mse_per_group': 0.004257, 'mse_per_tensor': 0.035554, 'error_reduction_pct': 88.03}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded or trained. `weights` arrives as a `float32` tensor; leave it in that dtype. Do the
quantize/dequantize arithmetic at full precision and round only the numbers you return — rounding a
scale early can shift a code by a whole step and move the error you report. Note that groups are
cut from the flattened element sequence, so a group is not the same thing as a row unless
`group_size` happens to equal the row width.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: per_group_quantization_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. weights    → Torch 2D Tensor
2. group_size → Integer
```

(`group_size` carries a default in most quantizer APIs — required here and supplied in every test
case. Five values must come back, so they fold into one `Dictionary`; `Torch 2D Tensor` is an
argument-only type, which is fine because nothing tensor-shaped is returned.)

**Reference Solution:**

```python
import torch


def per_group_quantization_report(weights: torch.Tensor, group_size: int) -> dict:
    q_min, q_max = torch.iinfo(torch.int8).min, torch.iinfo(torch.int8).max
    original_shape = weights.shape

    def absmax_scale(t):
        return t.abs().max().item() / q_max

    def quantize(t, scale):
        return torch.round(t / scale).clamp(q_min, q_max).to(torch.int8)

    # ---- per-group ----
    grouped = weights.view(-1, group_size)
    num_groups = grouped.shape[0]
    group_scales = torch.zeros(num_groups)
    for i in range(num_groups):
        group_scales[i] = absmax_scale(grouped.select(0, i))
    group_scales = group_scales.view(-1, 1)

    q_group = quantize(grouped, group_scales)
    deq_group = (group_scales * q_group.float()).view(original_shape)
    mse_group = (weights - deq_group).square().mean().item()

    # ---- per-tensor ----
    tensor_scale = absmax_scale(weights)
    q_tensor = quantize(weights, tensor_scale)
    deq_tensor = tensor_scale * q_tensor.float()
    mse_tensor = (weights - deq_tensor).square().mean().item()

    return {
        "num_groups": int(num_groups),
        "num_scales": int(group_scales.numel()),
        "mse_per_group": round(mse_group, 6),
        "mse_per_tensor": round(mse_tensor, 6),
        "error_reduction_pct": round((1 - mse_group / mse_tensor) * 100, 2),
    }
```

**Test Cases —** `in.txt`

```
2
4 6
0.82 -1.34 0.05 2.10 -0.47 0.93
88.50 -0.62 0.31 -1.75 0.08 1.42
-0.24 0.66 -2.98 0.51 -0.13 0.77
1.05 -0.39 0.22 -0.94 3.61 -1.28
3
2 8
12.40 -0.85 0.44 -3.10 0.09 0.71 -0.28 1.63
-0.52 0.37 -46.20 0.95 2.08 -1.11 0.64 -0.19
4
```

**Test Cases —** `out.txt`

```
{'num_groups': 8, 'num_scales': 8, 'mse_per_group': 0.004257, 'mse_per_tensor': 0.035554, 'error_reduction_pct': 88.03}
{'num_groups': 4, 'num_scales': 4, 'mse_per_group': 0.003015, 'mse_per_tensor': 0.011954, 'error_reduction_pct': 74.78}
```

**Grader Notes:**

- **Environment:** `torch` only (verified on torch 2.13.0, Python 3.12.13). No network, no model
  download, no GPU. Both cases together run in ~0.4 s, essentially all of it the `torch` import.
- Compare the two integer keys exactly. Compare `mse_per_group` / `mse_per_tensor` with tolerance
  `1e-6` and `error_reduction_pct` with tolerance `1e-2`. Dictionary key order is not graded.
- **Determinism:** re-running both cases with the inputs promoted to `float64` produced
  **byte-identical** dictionaries, so nothing here sits on a float32 knife-edge. The closest any
  code lands to a `.5` rounding boundary is `0.0065` of a step (case 2, per-group), which is ~600×
  the worst-case float32 error at these magnitudes.
- Both cases are engineered so one group carries a large outlier (`88.50` in case 1, `-46.20` in
  case 2) — that is what makes the per-tensor scale coarse and gives the comparison a visible
  answer instead of two near-identical MSEs.
- **Each wrong reading below was implemented and run**, not reasoned about:
  - **Truncation instead of rounding** (`torch.trunc(t / scale)`): case 1 → `mse_per_group`
    `0.040307`, `mse_per_tensor` `0.139985`, `error_reduction_pct` `71.21`; case 2 → `0.0137` /
    `0.042621` / `67.86`. Caught on both.
  - **Scale from the full range instead of the half-range** (`(max − min) / 255`, the asymmetric
    formula applied without a zero-point): case 1 → `81.242027` / `76.833527` / `-5.74`; case 2 →
    `33.145374` / `17.611706` / `-88.2`. Caught on both, and the negative reduction makes it
    obvious.
  - **Dividing the absmax by 128 instead of 127**: case 1 → `0.024202` / `0.055247` / `56.19`;
    case 2 → `0.003461` / `0.01209` / `71.37`. Caught on both.
  - **Per-channel (one scale per row) instead of per-group**: case 1 → `num_groups` `4`,
    `num_scales` `4`, `mse_per_group` `0.009397`, `error_reduction_pct` `73.57`; case 2 →
    `num_groups` `2`, `num_scales` `2`, `0.006171`, `48.37`. Caught on both, on the counts *and*
    the error. Neither case has `group_size` equal to its row width, precisely so this cannot slip
    through.
  - **Grouping down the columns instead of along the flattened rows** (transposing before the
    regroup): the counts stay right but case 1 → `mse_per_group` `0.003049` /
    `error_reduction_pct` `91.42` and case 2 → `0.003653` / `69.44`. Caught on both.
  - **`num_groups` computed as columns ÷ `group_size`** (groups per row rather than groups in the
    tensor): `2` on both cases against `8` and `4`. Caught on both — and note it leaves
    `num_scales` correct, so the two keys are not redundant in practice: they diverge under exactly
    this misreading, which is why both are asked for.
  - **`error_reduction_pct` inverted** (`(mse_t / mse_g − 1) × 100`): `735.27` / `296.44`; and
    measured against the per-group error (`(1 − mse_t / mse_g) × 100`): `-735.27` / `-296.44`.
    Caught on both.
- **Clamping before rounding is NOT observable here and must not be claimed as caught.** Under
  absmax the largest ratio in any group is exactly `q_max` by construction, so a code can never
  leave `[-128, 127]` before clamping; `torch.round((t / s).clamp(...))` returned dictionaries
  identical to the reference on both cases. No test data can distinguish the two orders for this
  question — Q3 is where clamp-vs-round order is graded.
- **Accepted routes — run and confirmed value-identical on both cases:**
  1. Computing the group scales vectorised (`grouped.abs().amax(dim=1, keepdim=True) / 127`)
     instead of the per-group loop.
  2. Leaving the codes as floats instead of casting through `torch.int8`.
  3. Deriving `num_groups` / `num_scales` arithmetically (`weights.numel() // group_size`) rather
     than reading them off the reshaped tensor.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L7_Model_Quantization_Techniques.md`:
  - Per-group quantization by reshaping to `(-1, group_size)`, with the divisibility assertion:
    `linear_q_symmetric_per_group`, lines 833–847. The reference reproduces its
    reshape → per-group scales → reshape back structure.
  - One scale per group obtained by reusing the per-channel routine along dim 0, including
    `tensor.select(dim, i)` and the broadcast reshape of the scale vector:
    `linear_q_symmetric_per_channel`, lines 784–802.
  - Symmetric absmax scale `alpha / q_max` with `q_max = torch.iinfo(dtype).max`:
    `get_q_scale_symmetric`, lines 506–511; `zero_point=0` for the symmetric path, lines 514–519.
  - Round → clamp → cast order and `torch.iinfo(dtype).min/max`:
    `linear_q_with_scale_and_zero_point`, lines 291–300. Signed INT8 `[-128, 127]`: line 224.
  - Per-group dequantization through the same flattened view: `linear_dequantization_per_group`,
    lines 850–860; `scale * (q.float() - zero_point)`, lines 304–306.
  - MSE as `(original − dequantized).square().mean()`: lines 371 and 806–807.
  - Reporting the stored-scale count per scheme and the per-tensor-vs-per-group MSE comparison:
    lines 863–891 (`Scales stored for per-group: {s_g.numel()}` → `12`).
  - Percentage error reduction as `(1 - mse_finer / mse_coarser) * 100`: line 820.
  - The granularity definitions and the outlier argument that motivates the comparison:
    lines 756–779 and the summary table, lines 1501–1503.
  Nothing in this question is ungrounded.
- **Overlap check:** the topic-organized bank's `symmetric_quantization_error`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q2) also
  does symmetric absmax INT8 and returns an MSE, but it is **per-tensor vs per-channel**, takes a
  `2D List of Floats`, is implemented in numpy, and returns a single float. This question is
  **per-group vs per-tensor**, takes a `Torch 2D Tensor`, computes in torch (matching the source
  material's own quantizer), and returns the group/scale counts and the reduction percentage
  alongside both errors. Distinct, but they are the same family — prefer one of the two in a single
  paper.
- Both cases executed against the reference solution above, and the two-case `in.txt` re-run as a
  single `T = 2` batch reproduces `out.txt` line for line.

---

## Q2: Which 16-Bit Float Survives Your Numbers?

**Context:** Two 16-bit floating-point formats are in common use, and they spend their fifteen
non-sign bits differently: one hands more of them to the exponent, the other to the fraction. The
exponent decides how large or how small a number the format can hold at all; the fraction decides
how finely it resolves the numbers in between. That single design choice is why one of the two
needs loss scaling to survive backpropagation and the other does not. Before switching a training
run or an inference path to 16 bits, it is worth pushing your actual value ranges through the
format you picked and seeing which of them come back intact, which saturate to infinity, and which
collapse to zero.

**Problem Statement:**

Using the `torch` library, write a function
`float_format_limits(exponent_bits, mantissa_bits, values)`.

1. `exponent_bits` and `mantissa_bits` give the bit budget of a 16-bit floating-point layout: one
   sign bit plus these two fields. Select the `torch` floating-point dtype whose
   sign/exponent/fraction split matches that budget.
2. Report the largest finite magnitude and the smallest positive **normal** value the selected
   dtype can represent, read from that dtype's own numeric limits. Report them exactly, not as the
   rounded figures usually quoted for these formats.
3. Convert every entry of `values` into the selected dtype and label each one by what the
   conversion produced:
   - `"overflow"` — the converted value is infinite
   - `"underflow"` — the converted value is exactly zero although the input was not zero
   - `"ok"` — anything else

   The label follows what the conversion produced, not a comparison against the two limits you
   reported in step 2.
4. Return a dictionary with exactly three keys:
   - `"max_finite"` — the largest finite magnitude, as a float
   - `"smallest_normal"` — the smallest positive normal value, as a float
   - `"verdicts"` — a dictionary mapping each entry's 0-based index in `values` to its label

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: exponent_bits (integer)
    Single line: one integer
  Argument 2: mantissa_bits (integer)
    Single line: one integer
  Argument 3: values (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
```

**Output Format:**

For each test case, print the result of `float_format_limits()` on a new line.

**Sample Input:**

```
exponent_bits = 5
mantissa_bits = 10
values = [65504.0, 65510.0, 70000.0, 1e-05, 1e-08, 0.0, -80000.0, 0.001, -2e-08]
```

**Sample Output:**

```
{'max_finite': 65504.0, 'smallest_normal': 6.103515625e-05, 'verdicts': {0: 'ok', 1: 'ok', 2: 'overflow', 3: 'ok', 4: 'underflow', 5: 'ok', 6: 'overflow', 7: 'ok', 8: 'underflow'}}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded and no arithmetic beyond the conversion itself is required. The three labels are compared
exactly as the strings given above.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: float_format_limits
RETURN TYPE: Dictionary

ARGUMENTS:
1. exponent_bits → Integer
2. mantissa_bits → Integer
3. values        → List of Floats
```

(Three values must come back — two limits and one label per input — so they fold into one nested
`Dictionary`, with the per-value labels keyed by 0-based index since `List of Dicts` is an
argument-only type and only one value may be returned.)

**Reference Solution:**

```python
import torch

LAYOUTS = {(5, 10): torch.float16, (8, 7): torch.bfloat16}


def float_format_limits(exponent_bits: int, mantissa_bits: int, values: list) -> dict:
    dtype = LAYOUTS[(exponent_bits, mantissa_bits)]
    info = torch.finfo(dtype)

    verdicts = {}
    for i, v in enumerate(values):
        cast = torch.tensor(v, dtype=torch.float64).to(dtype)
        if torch.isinf(cast):
            verdicts[i] = "overflow"
        elif cast.item() == 0.0 and v != 0.0:
            verdicts[i] = "underflow"
        else:
            verdicts[i] = "ok"

    return {
        "max_finite": float(info.max),
        "smallest_normal": float(info.tiny),
        "verdicts": verdicts,
    }
```

**Test Cases —** `in.txt`

```
2
5
10
9
65504.0 65510.0 70000.0 1e-05 1e-08 0.0 -80000.0 0.001 -2e-08
8
7
8
70000.0 3.0e38 4.0e38 1e-40 1e-45 0.0 -1e39 65504.0
```

**Test Cases —** `out.txt`

```
{'max_finite': 65504.0, 'smallest_normal': 6.103515625e-05, 'verdicts': {0: 'ok', 1: 'ok', 2: 'overflow', 3: 'ok', 4: 'underflow', 5: 'ok', 6: 'overflow', 7: 'ok', 8: 'underflow'}}
{'max_finite': 3.3895313892515355e+38, 'smallest_normal': 1.1754943508222875e-38, 'verdicts': {0: 'ok', 1: 'ok', 2: 'overflow', 3: 'ok', 4: 'underflow', 5: 'ok', 6: 'overflow', 7: 'ok'}}
```

**Grader Notes:**

- **Environment:** `torch` only (verified on torch 2.13.0, Python 3.12.13). No network, no GPU.
  Both cases run in ~0.4 s.
- Compare the label strings exactly. Compare `max_finite` and `smallest_normal` with a **relative**
  tolerance of `1e-3` — an absolute tolerance is meaningless when one case's value is `3.39e38` and
  the other's is `6.1e-05`. `1e-3` relative is deliberately chosen so that a solution hardcoding
  the commonly quoted `3.4e38` still fails (its relative error is `3.1e-3`), which is what step 2's
  "report them exactly" sentence is there to warn about.
- **Determinism:** every value here is an exact IEEE-754 conversion result, so there is no
  machine-dependent drift; `values` are parsed as Python floats (float64) and the only float
  operation is a dtype conversion.
- **The two cases must both ship.** They are the two 16-bit layouts, and case 2 exists to prove the
  layout was actually selected rather than assumed: `70000.0` overflows in case 1 and survives in
  case 2, and `65504.0` — case 1's exact maximum — is unremarkable in case 2. A solution that hard
  codes one dtype passes at most one case.
- **Each wrong reading below was implemented and run:**
  - **Comparing against the limits instead of converting** (`abs(v) > max_finite → overflow`,
    `0 < abs(v) < smallest_normal → underflow`): case 1 index 1 (`65510.0`) becomes `overflow`
    where the conversion rounds it down to `65504.0` and it is `ok`; case 1 indices 3 and 4
    (`1e-05`, `1e-08`) both become `underflow` where the true answers are `ok` and `underflow`;
    case 2 index 3 (`1e-40`) becomes `underflow` against `ok`. Caught on both cases, in both
    directions. `65510.0` and `1e-05` are in the input for exactly this reason — the former is
    above the largest finite magnitude yet still converts finitely, the latter is below the
    smallest normal value yet still converts to a non-zero subnormal.
  - **Dropping the "although the input was not zero" guard**: index 5 is `0.0` in both cases and
    becomes `underflow` instead of `ok`. Caught on both.
  - **Selecting the wrong dtype for the budget** (the two layouts swapped): case 1 returns
    `max_finite` `3.3895313892515355e+38` with every label `ok`; case 2 returns `65504.0` with six
    labels changed. Caught on both.
- **Accepted routes — run and confirmed value-identical on both cases:**
  1. Converting via an intermediate `float32` (`torch.tensor(v, dtype=torch.float32).to(dtype)`)
     instead of from `float64`. Verified identical on all 17 values; none of them sits in the band
     between the bfloat16 and float32 maxima where the two routes could diverge.
  2. Converting the whole list in one tensor rather than value by value.
  3. Reading the smallest normal as `torch.finfo(dtype).smallest_normal` instead of `.tiny` (they
     are the same number).
- **Scope trace** — `modules/02-advanced-ai-agents/markdown/L7_Model_Quantization_Techniques.md`:
  - The bit budgets themselves, which is what makes step 1 answerable: the sign/exponent/fraction
    table giving FP16 as `1 / 5 / 10` and BF16 as `1 / 8 / 7`, lines 100–104.
  - "The exponent controls the dynamic range … the fraction controls the precision", line 106; the
    dynamic-range / precision definitions, line 46.
  - FP16's max of ~65,504, **overflow to infinity** above it, and **underflow to exactly zero**
    below ~`6e-8`: lines 108–110. Step 3's two failure labels and the exactly-zero criterion come
    straight from this sentence — note it is the ~`6e-8` figure (the smallest subnormal), not the
    smallest *normal* value at `6.1e-5`, which is why the labels are defined by the conversion
    result and the smallest normal value is only reported, never used as a threshold.
  - BF16 keeping FP32's `±3.4e38` range at lower per-value precision: lines 112–114; the
    side-by-side overflow/underflow/loss-scaling comparison, lines 124–130.
  - `.to(dtype)` as the conversion idiom: line 298 (`.clamp(...).to(dtype)`), line 306 (`.float()`).
  - **Disclosed, not taught:** `torch.finfo` and `torch.isinf` are never called in the source
    material. Step 2 therefore tells the solver *what* to report and that it must be the dtype's
    own exact limit rather than a quoted approximation, and step 3 states the infinite/zero
    criteria outright. Both are one-line library lookups; the graded skill is knowing which layout
    is which format and what each format does to a value at the edges.
- **Overlap check:** no question in the topic-organized bank touches float formats — its two
  quantization questions (Q2, Q5) are both INT8 mapping. This is the only question in either bank
  where the graded observable is a floating-point format's own behaviour.
- Both cases executed against the reference solution above, and the two-case `in.txt` re-run as a
  single `T = 2` batch reproduces `out.txt` line for line.

---

## Q3: Static Calibration — Observed Activations to Frozen Quantization Parameters

**Context:** Weights are static, so their quantization parameters can be computed the moment you
have the checkpoint. Activations cannot: they depend on the input, and no scale exists until you
have seen some data. The standard answer is a calibration pass — push a small, representative
sample through the model, record the range each activation tensor actually reaches, and convert
those ranges into a scale and a zero-point that are then **frozen** for every future inference.
The risk is baked in at that moment. Anything the calibration sample never reached will be clamped
at the ends of the integer range once real traffic arrives, so the number worth reporting alongside
the parameters is how much of that traffic the frozen range failed to cover.

**Problem Statement:**

Using the `torch` library, write a function
`calibrate_activation_quantizers(layer_names, calibration_acts, production_acts)`.

1. Row `i` of `calibration_acts` holds every activation value the layer named `layer_names[i]`
   produced during the calibration pass. Row `i` of `production_acts` holds the values that same
   layer produced later, on live input. Both tensors have one row per layer, but they need not have
   the same number of columns.
2. For each layer, take the minimum and the maximum observed over its **calibration** row and turn
   that range into **asymmetric (zero-point)** INT8 quantization parameters: a floating-point
   scale, and an integer zero-point that must itself be a valid INT8 code. Signed INT8 spans
   `[-128, 127]`.
3. Freeze those parameters and quantize the layer's **production** row with them: scale and shift
   each value, round to the nearest integer code, then hold the result inside the signed INT8 range.
4. A production value whose code had to be pulled back to an end of the INT8 range could not be
   represented by the frozen parameters. Report what fraction of the layer's production values that
   was.
5. Return a dictionary mapping each layer name to a dictionary with exactly three keys:
   - `"scale"` — that layer's scale, rounded to 6 decimal places
   - `"zero_point"` — that layer's zero-point, as an integer
   - `"clipped_fraction"` — the fraction of that layer's production values whose code had to be
     pulled back into range, rounded to 4 decimal places

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: layer_names (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 2: calibration_acts (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 3: production_acts (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
```

**Output Format:**

For each test case, print the result of `calibrate_activation_quantizers()` on a new line.

**Sample Input:**

```
layer_names = ["layer_0", "layer_1", "layer_2", "layer_3"]
calibration_acts = [[  -0.460,   0.498,  0.120, -0.310,   0.205, -0.077,   0.361, -0.152],
                    [   0.840,  -0.668,  0.214, -0.395,   0.502, -0.121,   0.733, -0.288],
                    [-140.672,  21.588, -3.415,  0.926, -18.204,  7.331, -55.470, 12.083],
                    [  21.602, -140.717, -2.884,  1.475, -21.660,  6.902, -49.318, 10.554]]
production_acts  = [[  0.310, -0.402,   0.495,  0.640, -0.512,  0.055, -0.221,  0.5024,  0.5005, -0.088],
                    [  0.512, -0.334,   0.905,  1.204, -0.590,  0.087, -0.701,  0.446,   0.760,  -0.155],
                    [-95.400, 15.820, -142.500,  3.640, -12.075, 22.980, -55.310, 8.902, -160.750, 1.204],
                    [-88.200, 19.440,  -3.115,  0.550, -21.330,  6.780, -49.100, 10.220, -1.902,  12.640]]
```

**Sample Output:**

```
{'layer_0': {'scale': 0.003757, 'zero_point': -6, 'clipped_fraction': 0.3}, 'layer_1': {'scale': 0.005914, 'zero_point': -15, 'clipped_fraction': 0.3}, 'layer_2': {'scale': 0.636314, 'zero_point': 93, 'clipped_fraction': 0.3}, 'layer_3': {'scale': 0.636545, 'zero_point': 93, 'clipped_fraction': 0.0}}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded or trained; both tensors arrive as `float32` and should be left in that dtype. The
statistics are gathered per layer, so a layer's parameters depend only on its own row, never on the
tensor as a whole.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: calibrate_activation_quantizers
RETURN TYPE: Dictionary

ARGUMENTS:
1. layer_names      → List of Strings
2. calibration_acts → Torch 2D Tensor
3. production_acts  → Torch 2D Tensor
```

(A real observer object would default its integer dtype to `int8` — pinned in the statement and not
an argument here. Three values per layer must come back, so the result is a `Dictionary` of
`Dictionary`; a list of per-layer records is impossible because `List of Dicts` is an argument-only
type.)

**Reference Solution:**

```python
import torch


def calibrate_activation_quantizers(layer_names: list, calibration_acts: torch.Tensor,
                                    production_acts: torch.Tensor) -> dict:
    q_min, q_max = torch.iinfo(torch.int8).min, torch.iinfo(torch.int8).max

    report = {}
    for i, name in enumerate(layer_names):
        observed = calibration_acts.select(0, i)
        r_min, r_max = observed.min().item(), observed.max().item()

        scale = (r_max - r_min) / (q_max - q_min)
        zero_point = int(round(q_min - r_min / scale))
        zero_point = max(q_min, min(q_max, zero_point))

        live = production_acts.select(0, i)
        codes = torch.round(live / scale + zero_point)
        clipped = ((codes < q_min) | (codes > q_max)).sum().item()

        report[name] = {
            "scale": round(scale, 6),
            "zero_point": zero_point,
            "clipped_fraction": round(clipped / live.numel(), 4),
        }

    return report
```

**Test Cases —** `in.txt`

```
2
4
layer_0
layer_1
layer_2
layer_3
4 8
-0.460 0.498 0.120 -0.310 0.205 -0.077 0.361 -0.152
0.840 -0.668 0.214 -0.395 0.502 -0.121 0.733 -0.288
-140.672 21.588 -3.415 0.926 -18.204 7.331 -55.470 12.083
21.602 -140.717 -2.884 1.475 -21.660 6.902 -49.318 10.554
4 10
0.310 -0.402 0.495 0.640 -0.512 0.055 -0.221 0.5024 0.5005 -0.088
0.512 -0.334 0.905 1.204 -0.590 0.087 -0.701 0.446 0.760 -0.155
-95.400 15.820 -142.500 3.640 -12.075 22.980 -55.310 8.902 -160.750 1.204
-88.200 19.440 -3.115 0.550 -21.330 6.780 -49.100 10.220 -1.902 12.640
3
block_0
block_1
block_2
3 6
0.050 6.450 1.204 3.318 0.877 5.012
-12.400 3.950 -0.884 1.207 -6.315 2.048
-2.480 2.510 0.005 -1.115 1.902 -0.337
3 5
0.120 6.380 7.200 2.455 0.049
-20.500 -14.200 8.900 -13.050 5.600
1.204 -2.310 0.008 2.480 -1.775
```

**Test Cases —** `out.txt`

```
{'layer_0': {'scale': 0.003757, 'zero_point': -6, 'clipped_fraction': 0.3}, 'layer_1': {'scale': 0.005914, 'zero_point': -15, 'clipped_fraction': 0.3}, 'layer_2': {'scale': 0.636314, 'zero_point': 93, 'clipped_fraction': 0.3}, 'layer_3': {'scale': 0.636545, 'zero_point': 93, 'clipped_fraction': 0.0}}
{'block_0': {'scale': 0.025098, 'zero_point': -128, 'clipped_fraction': 0.2}, 'block_1': {'scale': 0.064118, 'zero_point': 65, 'clipped_fraction': 1.0}, 'block_2': {'scale': 0.019569, 'zero_point': -1, 'clipped_fraction': 0.0}}
```

**Grader Notes:**

- **Environment:** `torch` only (verified on torch 2.13.0, Python 3.12.13). No network, no GPU.
  Both cases run in ~0.4 s.
- Compare `scale` with tolerance `1e-6`, `zero_point` exactly, `clipped_fraction` with tolerance
  `1e-4`. Neither level of dictionary key order is graded.
- **Case 1 is built on the source material's own calibration table.** Its four calibration rows
  were constructed so that each layer's minimum and maximum are the material's observed values
  (`-0.460 / 0.498`, `-0.668 / 0.840`, `-140.672 / 21.588`, `-140.717 / 21.602`), and all four
  zero-points come out exactly as the material prints them: `-6`, `-15`, `93`, `93`. The scales
  agree to five significant figures but **not** always in the sixth decimal — the material's table
  is `0.003756 / 0.005915 / 0.636314 / 0.636544` against this question's
  `0.003757 / 0.005914 / 0.636314 / 0.636545`, because that table displays its min/max rounded to
  three decimals while computing the scale from the unrounded observations. The expected values in
  `out.txt` are what the reference solution actually produces from the inputs in `in.txt`; do not
  "correct" them toward the printed table.
- **Case 2 must ship** — it is the only case that exercises two things case 1 cannot:
  - `block_0`'s calibration range is entirely positive (`0.050 … 6.450`), so the raw zero-point
    computes to `-129.992` and **has to be clipped** to `-128`. A solution that skips the clip
    returns `-130`, which is not a representable INT8 code (see the wrong readings).
  - `block_1`'s production row lies wholly outside its calibrated range, giving
    `clipped_fraction` `1.0` — the degenerate "calibration sample missed the distribution
    completely" outcome. `block_2` gives the opposite extreme, `0.0`.
- **Determinism:** re-running both cases with both tensors promoted to `float64` produced
  **byte-identical** dictionaries. The clipping decisions are what must not drift, and the closest
  any production code lands to a clip boundary is `0.23` of a step (case 1, `layer_0`) — five
  orders of magnitude above float32 error at these code magnitudes.
- **Each wrong reading below was implemented and run:**
  - **Calibrating on the production tensor** (computing min/max from `production_acts`): case 1
    returns scales `0.004518 / 0.007471 / 0.72051 / 0.422118`, zero-points `-15 / -34 / 95 / 81`,
    and **every** `clipped_fraction` `0.0` — nothing can fall outside a range derived from itself.
    Caught on both cases; case 1 catches it on all three keys at once.
  - **Not clipping the zero-point into the INT8 range**: case 1 is unaffected (all four raw
    zero-points are already valid), **case 2 catches it** — `block_0` returns `-130` instead of
    `-128`. Case 2 must stay in any shipped subset for this reason.
  - **Truncating the code instead of rounding it** (`torch.trunc`): **case 1 catches it** —
    `layer_0` returns `clipped_fraction` `0.2` instead of `0.3`, because the production value
    `0.5024` lands at raw code `127.73`, which rounds to `128` (clipped) but truncates to `127`
    (not clipped). Every other layer and all of case 2 are unaffected, so `layer_0`'s `0.5024`
    entry is load-bearing and must not be edited out.
  - **Clamping before rounding instead of after**: **case 1 catches it** — `layer_0` returns `0.4`
    instead of `0.3`. Two production values (`0.5005` and `0.5024`) land at raw codes `127.22` and
    `127.73`; clamping first calls both unrepresentable, while the required round-then-clamp order
    keeps `127.22 → 127` in range. Together with the previous bullet, all three orderings give
    three different answers (`0.2` truncate / `0.3` correct / `0.4` clamp-first) on the same layer.
  - **Scale from the half-range** (`max(|r_min|, |r_max|) / 127`, i.e. the symmetric absmax formula
    with a zero-point bolted on): case 1 → scales `0.003921 / 0.006614 / 1.107654 / 1.108008`,
    zero-points `-11 / -27 / -1 / -1`, fractions `0.2 / 0.2 / 0.2 / 0.0`; case 2 → fractions
    `0.0 / 0.6 / 0.0`. Caught on both, on all three keys.
- **Accepted routes — run and confirmed value-identical on both cases:**
  1. The `if / elif / else` form of the zero-point clip (return `q_min` or `q_max` unrounded when
     out of range, otherwise `int(round(...))`) instead of round-then-clamp. Identical, because a
     zero-point only leaves the range on the side it is then pinned to.
  2. Counting clipped values as `(codes.clamp(q_min, q_max) != codes).sum()` instead of an explicit
     out-of-range mask.
  3. Deriving the zero-point from the maximum (`q_max - r_max / scale`) instead of the minimum —
     algebraically the same expression once `scale = (r_max - r_min) / (q_max - q_min)`, and
     confirmed identical on all seven layers. Do not mark this down.
  4. Literal `-128 / 127` instead of `torch.iinfo(torch.int8)`.
- **Scope trace** — `modules/02-advanced-ai-agents/markdown/L7_Model_Quantization_Techniques.md`:
  - The four-step calibration procedure the question is built on — prepare a representative sample,
    run inference, **collect the min/max observed for each activation tensor**, compute scale and
    zero-point from the collected ranges: lines 596–604.
  - Collecting a running per-tensor minimum and maximum during the pass, keyed by layer name
    (`activation_stats[name]["min"]`/`["max"]`, names `layer_0 … layer_3`): lines 660–688. Row `i`
    of `calibration_acts` is exactly the value stream one such hook sees.
  - `scale = (r_max - r_min) / (q_max - q_min)`, `zero_point = int(round(q_min - r_min / scale))`,
    then clipped into `[q_min, q_max]`: lines 724–728, and the same computation as
    `get_q_scale_and_zero_point` at lines 397–412. The printed per-layer table at lines 743–749 is
    case 1's expected output.
  - Quantizing with fixed parameters — `q = clamp(round(x / s + z), -128, 127)`, in that order:
    line 240 and `linear_q_with_scale_and_zero_point`, lines 291–300. `q_min`/`q_max` from
    `torch.iinfo(dtype)`: lines 295–296; signed INT8 `[-128, 127]`: line 224.
  - Parameters are **frozen** after calibration and reused for all future inference: lines 606 and
    751.
  - The clipping consequence that `clipped_fraction` measures: outliers get clamped by a tighter
    range (lines 550–561), and "if the calibration data does not cover the range of values the
    model will encounter in production, the quantized model may clip or lose precision on unseen
    inputs" (lines 606 and 753) — the production-vs-calibration split in this question is that
    sentence made measurable.
  - Static PTQ pre-computing scale and zero-point from a calibration dataset: lines 908–914.
  Nothing in this question is ungrounded.
- **Why the collected statistics are inputs and the parameters are not.** Handing over
  pre-computed scales would make this a formula-transcription exercise. Here the graded values
  cannot be reached without actually reducing each calibration row to its range **and** running
  every production value through the frozen quantizer: `clipped_fraction` in particular depends on
  the interaction of two tensors and on the exact round-then-clamp order, and cannot be
  hand-computed from summary statistics.
- **Overlap check:** the topic-organized bank's `linear_quantize_asymmetric_error`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q5)
  also computes an asymmetric scale and zero-point, but from a single 1-D list, in pure Python, and
  returns one MSE float. This question never returns an error: it returns the frozen parameters
  themselves plus the coverage failure of a *second* tensor, which is the calibration idea rather
  than the roundtrip-error idea. Distinct, though both derive the same two parameters — avoid
  shipping them in one paper.
- Both cases executed against the reference solution above, and the two-case `in.txt` re-run as a
  single `T = 2` batch reproduces `out.txt` line for line.

---

## Q4: Ternary Weights and What 1.58 Bits Buys

**Context:** The most aggressive weight formats give up on integers-with-a-scale altogether and let
each weight take one of three values: -1, 0, or +1. Three levels per weight is under two bits, and
because the levels are exactly those three, a matrix multiply degenerates into additions and skips
— the zeros drop terms entirely, and nothing needs a multiplier. A ternary weight matrix is
produced by scaling the tensor by its mean absolute value and rounding onto the three levels, and
the interesting question is what the result costs: how the weights distribute across the three
levels, how much fidelity the reconstruction gives up, and how large the whole model becomes at
that width.

**Problem Statement:**

Using the `torch` library, write a function
`ternary_weight_report(weights, total_params, baseline_bits)`.

1. Quantize `weights` onto the ternary levels `{-1, 0, 1}` using **absmean** quantization: the
   scale is the mean absolute value of the whole tensor. Divide by that scale, round to the nearest
   integer, and hold the result within the three levels.
2. Count how many weights landed on each of the three levels.
3. Dequantize — the ternary levels rescaled by the same scale — and compute the mean squared error
   against `weights`, averaged over all elements.
4. A three-level code carries log₂3 bits per weight. At that width, compute the footprint of a
   whole model of `total_params` parameters in MB (1 MB = 1024 × 1024 bytes), and the compression
   ratio against the same model stored at `baseline_bits` bits per parameter.
5. Return a dictionary with exactly six keys:
   - `"scale"` — the absmean scale, rounded to 6 decimal places
   - `"counts"` — a dictionary mapping each of the three integer levels `-1`, `0` and `1` to how
     many weights landed on it
   - `"error_mse"` — the reconstruction error, rounded to 6 decimal places
   - `"bits_per_weight"` — the effective width in bits, rounded to 4 decimal places
   - `"footprint_mb"` — the ternary model's footprint in MB, rounded to 2 decimal places
   - `"compression_ratio"` — how many times smaller that is than the `baseline_bits` baseline,
     rounded to 2 decimal places

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: weights (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: total_params (integer)
    Single line: one integer
  Argument 3: baseline_bits (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `ternary_weight_report()` on a new line.

**Sample Input:**

```
weights = [[ 0.62, -1.35,  0.08,  2.10],
           [-0.41,  0.91, -0.05, -1.72],
           [ 1.28,  0.33, -0.79,  0.17],
           [-2.41,  0.56,  1.04, -0.28]]
total_params = 3000000000
baseline_bits = 16
```

**Sample Output:**

```
{'scale': 0.88125, 'counts': {-1: 4, 0: 6, 1: 6}, 'error_mse': 0.343979, 'bits_per_weight': 1.585, 'footprint_mb': 566.83, 'compression_ratio': 10.09}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded or trained. `weights` arrives as a `float32` tensor; leave it in that dtype.
`total_params` is the parameter count of the whole model being costed out, not of the tensor you
were handed — the tensor is there to be quantized, the count to be priced.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: ternary_weight_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. weights       → Torch 2D Tensor
2. total_params  → Integer
3. baseline_bits → Integer
```

(`baseline_bits` would default to 32 in any real sizing helper — required here and supplied in
every test case, and the two cases deliberately use different values. Six values must come back, so
they fold into one nested `Dictionary`.)

**Reference Solution:**

```python
import math

import torch


def ternary_weight_report(weights: torch.Tensor, total_params: int, baseline_bits: int) -> dict:
    scale = weights.abs().mean().item()
    ternary = torch.round(weights / scale).clamp(-1, 1)

    counts = {level: int((ternary == level).sum().item()) for level in (-1, 0, 1)}

    dequantized = scale * ternary
    mse = (weights - dequantized).square().mean().item()

    bits_per_weight = math.log2(3)
    footprint_mb = total_params * bits_per_weight / 8 / (1024 * 1024)

    return {
        "scale": round(scale, 6),
        "counts": counts,
        "error_mse": round(mse, 6),
        "bits_per_weight": round(bits_per_weight, 4),
        "footprint_mb": round(footprint_mb, 2),
        "compression_ratio": round(baseline_bits / bits_per_weight, 2),
    }
```

**Test Cases —** `in.txt`

```
2
4 4
0.62 -1.35 0.08 2.10
-0.41 0.91 -0.05 -1.72
1.28 0.33 -0.79 0.17
-2.41 0.56 1.04 -0.28
3000000000
16
4 5
1.85 -0.12 0.44 -2.63 0.07
-0.98 3.21 -0.35 0.16 -1.47
0.52 -0.71 2.08 -0.09 0.63
-1.19 0.28 -0.86 1.34 -0.03
70000000000
32
```

**Test Cases —** `out.txt`

```
{'scale': 0.88125, 'counts': {-1: 4, 0: 6, 1: 6}, 'error_mse': 0.343979, 'bits_per_weight': 1.585, 'footprint_mb': 566.83, 'compression_ratio': 10.09}
{'scale': 0.9505, 'counts': {-1: 6, 0: 8, 1: 6}, 'error_mse': 0.564662, 'bits_per_weight': 1.585, 'footprint_mb': 13225.96, 'compression_ratio': 20.19}
```

**Grader Notes:**

- **Environment:** `torch` only (verified on torch 2.13.0, Python 3.12.13). No network, no GPU.
  Both cases run in ~0.4 s.
- Compare `counts` exactly, `scale` and `error_mse` with tolerance `1e-6`, `bits_per_weight` with
  `1e-4`, `footprint_mb` and `compression_ratio` with `1e-2`. Neither level of key order is graded;
  `counts` keys are the integers `-1`, `0`, `1`.
- **Determinism:** re-running both cases with `weights` promoted to `float64` produced
  **byte-identical** dictionaries. The closest any ratio lands to a `.5` rounding boundary is
  `0.032` of a step, and that particular element (`-1.532`) rounds to `-2` and is then clamped to
  `-1`, so even a flip would not change the result.
- **The two cases are sized to two different real comparisons:** case 1 prices a 3B model against
  an FP16 baseline (`compression_ratio` `10.09`), case 2 a 70B model against FP32
  (`13225.96 MB ≈ 12.9 GB` against the ~280 GB the same model costs in FP32, `compression_ratio`
  `20.19`). Different `total_params` **and** different `baseline_bits`, so no constant passes both.
- **Each wrong reading below was implemented and run:**
  - **absmax instead of absmean for the scale**: case 1 → `scale` `2.41`,
    `counts` `{-1: 3, 0: 11, 1: 2}`, `error_mse` `0.412356`; case 2 → `3.21`,
    `{-1: 1, 0: 16, 1: 3}`, `0.607765`. Caught on both — dividing by the largest magnitude instead
    of the mean one collapses most weights to `0`.
  - **Truncation instead of rounding**: case 1 → `{-1: 2, 0: 9, 1: 3}`, `error_mse` `0.209795`;
    case 2 → `{-1: 3, 0: 12, 1: 2}`, `0.217016`. Caught on both.
  - **Rounding without clamping to the three levels**: case 1 → `{-1: 1, 0: 6, 1: 5}`, `error_mse`
    `0.068657`; case 2 → `{-1: 4, 0: 8, 1: 3}`, `0.07052`. Caught on both, and the counts no longer
    sum to the element count (12 of 16, 15 of 20) because codes of `±2` and `±3` escaped.
  - **Taking the sign instead of scaling and rounding** (the 1-bit rule rather than the ternary
    one): case 1 → `{-1: 7, 0: 0, 1: 9}`, `error_mse` `0.489798`; case 2 → `{-1: 10, 0: 0, 1: 10}`,
    `0.779665`. Caught on both — the zero level disappears entirely.
  - **`bits_per_weight` hardcoded to `1.58`** rather than computed as log₂3: `footprint_mb`
    `565.05` / `13184.55` and `compression_ratio` `10.13` / `20.25`, against `566.83` / `13225.96`
    and `10.09` / `20.19`. Caught on both, and the stated `1e-2` tolerance is what makes it fail —
    a looser one would let case 1's `10.13` through.
  - **`bits_per_weight` taken as 2** (a ternary level stored in two bits): `2.0`, `715.26` /
    `16689.3`, `8.0` / `16.0`. Caught on both.
  - **MB as 10⁶ bytes instead of 1024²**: `footprint_mb` `594.36` / `13868.42`. Caught on both.
  - **Compression ratio inverted** (`bits_per_weight / baseline_bits`): `0.1` / `0.05`. Caught on
    both.
- **Accepted routes — run and confirmed value-identical on both cases:** counting the levels by
  sign tests (`(t < 0).sum()`, `(t == 0).sum()`, `(t > 0).sum()`) instead of equality against each
  level; `math.log(3, 2)` instead of `math.log2(3)`; `2 ** 20` instead of `1024 * 1024`;
  `torch.clamp(..., min=-1, max=1)` instead of the method form.
- **Scope trace** — `modules/02-advanced-ai-agents/markdown/L7_Model_Quantization_Techniques.md`:
  - Ternary weights taking one of `{-1, 0, 1}`, and the name of the scheme that produces them:
    "BitNet 1.58b uses **absmean** quantization. Values are rounded to -1, 0, or 1", lines 1412–1428
    and the summary row at line 1510.
  - Why the zero level matters (ternary weights turn a multiply-accumulate into addition alone):
    lines 1416–1424.
  - Round-then-clamp as the quantization order: `linear_q_with_scale_and_zero_point`, lines
    291–300. Dequantizing as `scale × code` with no zero-point offset: lines 304–306 and 517–519.
  - Reconstruction error as `(original − dequantized).square().mean()`: lines 371 and 806.
  - Costing a model from its parameter count and a bit width — "since there are 8 bits in a byte of
    memory, we can estimate memory requirements", and 70 billion parameters in FP32 needing 280 GB:
    lines 50–54. Case 2 is that same 70B model, re-priced at 1.58 bits.
  - Model size measured by summing parameter bytes and dividing by `1024 * 1024`:
    `get_model_size_mb`, lines 944–946.
  - Compression expressed as a ratio of the two footprints (`fp32_size / int8_size`, and the "size
    should drop by roughly 4x for 32 → 8 bits" check): lines 1022 and 1079.
  - The two baseline widths used by the test cases: the format table at lines 100–104 (FP32 32
    bits, FP16 16 bits), and the FP16 comparison a 1.58-bit model is judged against at line 1432.
  - **Disclosed, not taught:** the source material names the regime "1.58 bits" (lines 1412, 1510)
    but never writes log₂3, so step 4 states the width as log₂3 outright rather than expecting it to
    be derived. Everything else — the absmean scale, the rounding onto three levels, the footprint
    arithmetic, the compression ratio — is grounded above.
- **Overlap check:** neither quantization question in the topic-organized bank (Q2 symmetric INT8,
  Q5 asymmetric INT8) leaves the 8-bit integer world, and neither computes a footprint or a
  compression ratio. The bank's Q1 (LoRA parameter budget) and this file's Q1 are also unrelated:
  those count parameters, this one prices a fixed count at a sub-2-bit width. No overlap.
- Both cases executed against the reference solution above, and the two-case `in.txt` re-run as a
  single `T = 2` batch reproduces `out.txt` line for line.
