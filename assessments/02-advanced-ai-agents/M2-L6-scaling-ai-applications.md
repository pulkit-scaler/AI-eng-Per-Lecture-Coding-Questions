# Module 2, Lecture 6 — Scaling AI Applications

Four coding questions on the three parallelism strategies this material teaches. Two of them
**perform** the strategy on real tensors and check it against the single-device result — data
parallelism's gradient synchronisation (Q1) and tensor parallelism's column-then-row split of an MLP
block (Q2). The other two **simulate** a schedule with state rather than evaluating a formula — the
bucketed gradient all-reduce overlapped with the backward pass (Q3), and the GPipe and 1F1B pipeline
schedules (Q4).

Nothing is downloaded, no process group is started and no GPU is used: every strategy is reproduced
on one device, which is exactly what makes it checkable. Q1 and Q2 use `torch` autograd and matmuls;
Q3 and Q4 are discrete-event simulations in the standard library.

**Scope note.** This file replaces an earlier set of four questions for this class that were retired
for being too shallow: each reduced to evaluating one stated formula or definition over supplied
scalars — a serving-metric summary, tail-latency percentiles, the pipeline-bubble ratio, and a
parallelism-degree decision tree. The concepts they covered are still in scope, but they are now
reached through work that cannot be short-cut: Q4 *derives* the bubble ratio from a schedule it has
to build, and reports it alongside the formula as a cross-check rather than instead of one.

---

## Q1: Synchronising Gradients Across Data-Parallel Replicas

**Context:** Data parallelism is the default way to use more than one GPU. Every device holds a
complete copy of the model, the batch is split between them, and each device runs its own forward and
backward pass — which means each device ends up with a *different* gradient, computed from different
samples. What makes the scheme correct rather than merely parallel is the collective that follows:
the per-device gradients are averaged so every replica applies the identical update. The claim worth
verifying is that this is not an approximation — the averaged gradient is exactly the gradient the
whole batch would have produced on one device.

**Problem Statement:**

Using `torch`, write a function `ddp_gradient_sync(features, targets, weights, world_size)`.

1. `features` is the global batch, one row per sample; `targets` holds one value per sample; and
   `weights` is the single set of starting parameters every replica begins from. Split the batch into
   `world_size` equal contiguous shards — the first shard is the first rows, and so on — and report
   the number of samples in one shard.
2. On each replica independently, predict each of its own samples as the dot product of its feature
   row with the weights, and take that replica's loss to be the **mean over its own shard** of the
   squared difference between prediction and target. Obtain the gradient of that loss with respect to
   the weights by automatic differentiation, starting from the same `weights` every time.
3. Report the L2 norm of each replica's gradient, in rank order, rounded to 4 decimal places — these
   differ, because each replica saw different samples.
4. Synchronise: report the element-wise **mean** of the per-replica gradients, rounded to 4 decimal
   places.
5. Separately, compute the gradient of the same loss taken as the mean over the **whole** batch on a
   single device, and report it rounded the same way. Report also whether the two agree to within
   `1e-4` on every element.
6. Return a dictionary with exactly these five keys: `"shard_size"` as an integer,
   `"rank_grad_norms"`, `"averaged_grad"` and `"single_device_grad"` as lists of floats, and
   `"equivalent"` as a boolean.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: features (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: targets (numpy_1d)
    Line 1: N (array length)
    Line 2: N space-separated values
  Argument 3: weights (numpy_1d)
    Line 1: N (array length)
    Line 2: N space-separated values
  Argument 4: world_size (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `ddp_gradient_sync()` on a new line.

**Sample Input:**

```
features = tensor([[1., 2.],
                   [2., 1.],
                   [3., 0.],
                   [0., 3.],
                   [1., 1.],
                   [2., 2.]])
targets    = array([3., 4., 5., 1., 2., 6.])
weights    = array([0.5, -0.25])
world_size = 3
```

**Sample Output:**

```
{'shard_size': 2, 'rank_grad_norms': [13.2594, 11.7394, 18.0312], 'averaged_grad': [-10.9167, -9.0833], 'single_device_grad': [-10.9167, -9.0833], 'equivalent': True}
```

**Note:** The input handling is already in place — you only need to implement the function. No process
group is created and no GPU is involved: the replicas are simulated one after another on one device,
which is the only way to compare them against the single-device answer. The batch size is always
divisible by `world_size`. Each replica must start from the supplied weights rather than from
whatever the previous replica left behind, so build a fresh differentiable parameter per replica —
gradients accumulate otherwise.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: ddp_gradient_sync
RETURN TYPE: Dictionary

ARGUMENTS:
1. features   → Torch 2D Tensor
2. targets    → Numpy 1D Array
3. weights    → Numpy 1D Array
4. world_size → Integer
```

(Five values must come back, so they fold into one `Dictionary`. `features` is a tensor because the
forward pass and autograd run on it; `targets` and `weights` are arrays because the tool has no
1-D tensor layout confirmed in this bank, and both are converted inside the function.)

**Reference Solution:**

```python
import numpy as np
import torch


def ddp_gradient_sync(features: torch.Tensor, targets: np.ndarray,
                      weights: np.ndarray, world_size: int) -> dict:
    y = torch.as_tensor(targets, dtype=torch.float32)
    shard = features.shape[0] // world_size

    def grad_of(X, t):
        w = torch.tensor(weights, dtype=torch.float32, requires_grad=True)
        loss = ((X @ w - t) ** 2).mean()
        loss.backward()
        return w.grad.detach().clone()

    rank_grads = [grad_of(features[r * shard:(r + 1) * shard],
                          y[r * shard:(r + 1) * shard])
                  for r in range(world_size)]

    averaged = torch.stack(rank_grads).mean(dim=0)
    single = grad_of(features, y)

    return {
        "shard_size": shard,
        "rank_grad_norms": [round(float(torch.linalg.vector_norm(g)), 4) for g in rank_grads],
        "averaged_grad": [round(float(v), 4) for v in averaged],
        "single_device_grad": [round(float(v), 4) for v in single],
        "equivalent": bool(float(torch.max(torch.abs(averaged - single))) < 1e-4),
    }
```

**Test Cases —** `in.txt`

```
2
6 2
1.0 2.0
2.0 1.0
3.0 0.0
0.0 3.0
1.0 1.0
2.0 2.0
6
3.0 4.0 5.0 1.0 2.0 6.0
2
0.5 -0.25
3
8 3
1.0 0.0 2.0
0.0 1.0 1.0
2.0 2.0 0.0
1.0 3.0 1.0
3.0 1.0 2.0
0.0 2.0 3.0
2.0 0.0 1.0
1.0 1.0 1.0
8
2.0 1.0 4.0 3.0 5.0 2.0 3.0 1.0
3
0.1 0.2 -0.3
4
```

**Test Cases —** `out.txt`

```
{'shard_size': 2, 'rank_grad_norms': [13.2594, 11.7394, 18.0312], 'averaged_grad': [-10.9167, -9.0833], 'single_device_grad': [-10.9167, -9.0833], 'equivalent': True}
{'shard_size': 2, 'rank_grad_norms': [6.6836, 17.5579, 25.4831, 8.3457], 'averaged_grad': [-8.6, -6.7, -7.625], 'single_device_grad': [-8.6, -6.7, -7.625], 'equivalent': True}
```

**Grader Notes:**

- **Environment:** `torch` 2.13.0 and `numpy` 2.5.2 on Python 3.12.13, CPU. Milliseconds per case.
  No `torch.distributed`, no process group, no GPU.
- **Autograd produces the graded value.** The per-replica gradients and their average come out of
  real backward passes; none of the five values can be written down from the inputs without running
  them. The question also *demonstrates* the material's central DDP claim rather than asserting it:
  `"equivalent"` is the claim, and `"rank_grad_norms"` is the evidence that the replicas genuinely
  disagreed before the collective.
- **Why the averaging is exact.** Averaging per-shard mean-gradients equals the whole-batch mean
  gradient **only because the shards are equal-sized** — which is what the material specifies. This
  is the substantive content of the question: a learner who splits unevenly, or who sums instead of
  averaging, breaks the equivalence.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L6_Scaling_AI_Applications.md`:
  - *The five steps of DDP* — **lines 196–200**: "**Replicate** — every GPU holds a complete copy",
    "**Partition the batch** — the global batch is divided into **equal-sized** micro-batches, one
    per GPU", "**Forward + Backward independently**", "**Synchronize gradients** — after backward, an
    **all-reduce** collective aggregates gradients across all GPUs so every replica sees the same
    **averaged** gradient", and the identical optimizer step. Steps 1, 2 and 4 are those four lines,
    and the word "averaged" on line 199 is why step 4 is a mean and not a sum.
  - *The claim being verified* — **line 202**, verbatim: "Because every GPU applies the same update
    to the same starting weights, DDP is **mathematically equivalent** to training on a single GPU
    with the full global batch — it only re-partitions the work." Step 5 is that sentence turned into
    a check.
  - *Every replica starting from the same weights* — **line 202** again ("the same starting weights")
    and **line 196**; this is why `weights` is a single argument rather than one set per rank, and why
    the Note warns about a fresh differentiable parameter per replica.
  - *What is and is not sharded* — **lines 206–207**: "**Sharded:** Data / batch — each GPU gets
    different samples" against "**Not sharded:** Model weights…". `"rank_grad_norms"` differing while
    `weights` is shared is exactly that split.
  - **Disclosed, not taught:**
    - The loss. The material never names one, because it is about the mechanism rather than the
      objective; step 2 specifies mean-squared-error over the shard so the gradient is well defined.
    - Reporting gradient **norms** rather than the vectors. Three full vectors per case would triple
      the payload for no extra signal; the norms establish that the replicas differed.
- **Determinism.** Every graded value was computed in `float32` **and** `float64` and is identical at
  4 decimal places in both cases; a 6-decimal rounding was tried first and did **not** survive that
  comparison (the single-device gradient's last element read `-9.083334` against the average's
  `-9.083333`), which is why the values are rounded to 4 and the equivalence uses a `1e-4` tolerance
  rather than exact equality. Do not tighten either.
- Compare `"shard_size"` and `"equivalent"` exactly, and every float element-wise with tolerance
  `1e-4`.
- **What each case is for:**
  - **Case 1** — three replicas of two samples each on a two-parameter model. The rank norms
    (13.2594 / 11.7394 / 18.0312) are spread widely, so any solution that accidentally gives all
    replicas the same data is obvious.
  - **Case 2** — four replicas, three parameters, and a starting weight vector that is not symmetric.
    Its averaged gradient has an element (`-7.625`) that no rank's gradient shares, so a solution
    reporting rank 0's gradient as the average is caught here.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Summing the per-rank gradients instead of averaging**: case 1 gives
    `[-32.75, -27.25]` and `"equivalent": False` — caught on both, and this is the reading the word
    "averaged" on line 199 exists to prevent.
  - **Not resetting the parameter between replicas** (reusing one `w` so `.grad` accumulates):
    rank norms become `[13.2594, 24.9865, 42.9169]` on case 1 — caught on both.
  - **Loss as a sum rather than a mean over the shard**: rank norms scale by the shard size
    (`[26.5189, 23.4787, 36.0624]`) and `"equivalent"` becomes `False`, because a per-shard sum
    averaged over ranks is the whole-batch sum divided by `world_size` — caught on both.
  - **Interleaved sharding** (`features[r::world_size]` instead of contiguous slices): the norms
    change (`[15.0333, 12.1966, 16.1477]` on case 1) while `"averaged_grad"` and `"equivalent"` stay
    correct — the average is invariant to *how* equal-sized shards are formed, which is a true and
    slightly surprising fact. Caught only by `"rank_grad_norms"`, which is why that key is graded.
  - **Reporting the single-device gradient in place of the average**: passes both cases by
    construction — they are equal. That is the point of the question, so it is not a wrong reading to
    catch; `"rank_grad_norms"` is what forces the per-replica work to actually happen.
- **Overlap check:** Q2 of this file shards *weights* rather than data and never differentiates
  anything. `M2-L8` Q2 implements NCCL collectives as list operations on supplied integers and never
  runs a model. No shared graded value.
- Both cases executed against the reference solution.

---

## Q2: Splitting an MLP Block Column-Then-Row Across GPUs

**Context:** Tensor parallelism splits work *inside* a single matrix multiplication. A weight matrix
can be cut along its output dimension, so each device produces a slice of the output; or along its
input dimension, so each device produces a partial sum of the whole output. Which cut you choose
decides which collective you need afterwards, and the two cuts compose: if the first matrix of a pair
is cut one way and the second the other way, each device can carry its own slice straight through
from one matrix into the next and the pair costs a single collective at the end instead of one after
each. That pairing is why tensor parallelism is affordable inside a transformer block at all.

**Problem Statement:**

Using `torch`, write a function `tensor_parallel_mlp(x, w1, w2, tp_degree)`.

1. The block computes, on one device, a first projection `x @ w1`, then a **ReLU**, then a second
   projection into the output: `relu(x @ w1) @ w2`. Compute that unsharded result; it is the answer
   the sharded version must reproduce.
2. Now shard across `tp_degree` devices. `w1` is split along its **output** dimension into
   `tp_degree` equal contiguous column blocks, and `w2` along its **input** dimension into the
   matching row blocks — device `s` gets column block `s` of `w1` and row block `s` of `w2`. Report
   how many hidden units one device owns, and the shape of each of its two weight shards as
   `[rows, columns]`.
3. Each device computes its own share of the block end to end: the full input against its `w1` shard,
   the activation applied to that, and the result against its `w2` shard. What each device holds is a
   partial sum of the whole output, not a slice of it.
4. Combine the devices' partials into the final output with the collective that partial sums require,
   and report how many collectives the whole block needed.
5. Report the sum of every element of device 0's partial, and the sum of every element of the combined
   output, each rounded to 4 decimal places; and whether the combined output agrees with step 1's
   unsharded result to within `1e-4` on every element.
6. Return a dictionary with exactly these seven keys: `"hidden_per_gpu"` and
   `"collectives_per_block"` as integers, `"w1_shard_shape"` and `"w2_shard_shape"` as two-element
   lists, `"gpu0_partial_sum"` and `"output_sum"` as floats, and `"matches"` as a boolean.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: x (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: w1 (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 3: w2 (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 4: tp_degree (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `tensor_parallel_mlp()` on a new line.

**Sample Input:**

```
x  = tensor([[ 1., -2.,  0.5],
             [ 0.5, 1., -1. ]])
w1 = tensor([[ 0.5, -1.,  0.25, 2. ],
             [ 1.,   0.5, -0.5, 0. ],
             [-2.,   1.,   1.5, 0.5]])
w2 = tensor([[ 1.,   0.5],
             [-0.5,  2. ],
             [ 0.25,-1. ],
             [ 2.,   1.5]])
tp_degree = 2
```

**Sample Output:**

```
{'hidden_per_gpu': 2, 'w1_shard_shape': [3, 2], 'w2_shard_shape': [2, 2], 'collectives_per_block': 1, 'gpu0_partial_sum': 4.875, 'output_sum': 13.0, 'matches': True}
```

**Note:** The input handling is already in place — you only need to implement the function. No
process group is created and no GPU is involved: every device's share is computed in turn on one
device, which is what lets you compare the result against the unsharded one. The hidden dimension is
always divisible by `tp_degree`. Every device sees the **whole** input `x` — it is the weights that
are split, not the batch. The activation is applied on each device to that device's own hidden slice.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: tensor_parallel_mlp
RETURN TYPE: Dictionary

ARGUMENTS:
1. x         → Torch 2D Tensor
2. w1        → Torch 2D Tensor
3. w2        → Torch 2D Tensor
4. tp_degree → Integer
```

(Seven values must come back, so they fold into one `Dictionary`. `Torch 2D Tensor` is argument-only,
which is no obstacle: only scalars and two short shape lists leave the function.)

**Reference Solution:**

```python
import torch


def tensor_parallel_mlp(x: torch.Tensor, w1: torch.Tensor, w2: torch.Tensor,
                        tp_degree: int) -> dict:
    hidden = w1.shape[1]
    per_gpu = hidden // tp_degree

    y_full = torch.relu(x @ w1) @ w2

    partials = []
    for s in range(tp_degree):
        w1_shard = w1[:, s * per_gpu:(s + 1) * per_gpu]   # column-parallel
        w2_shard = w2[s * per_gpu:(s + 1) * per_gpu, :]   # row-parallel
        partials.append(torch.relu(x @ w1_shard) @ w2_shard)

    y_tp = torch.stack(partials).sum(dim=0)               # all-reduce (sum)

    return {
        "hidden_per_gpu": per_gpu,
        "w1_shard_shape": [int(w1.shape[0]), per_gpu],
        "w2_shard_shape": [per_gpu, int(w2.shape[1])],
        "collectives_per_block": 1,
        "gpu0_partial_sum": round(float(partials[0].sum()), 4),
        "output_sum": round(float(y_tp.sum()), 4),
        "matches": bool(float(torch.max(torch.abs(y_tp - y_full))) < 1e-4),
    }
```

**Test Cases —** `in.txt`

```
2
2 3
1.0 -2.0 0.5
0.5 1.0 -1.0
3 4
0.5 -1.0 0.25 2.0
1.0 0.5 -0.5 0.0
-2.0 1.0 1.5 0.5
4 2
1.0 0.5
-0.5 2.0
0.25 -1.0
2.0 1.5
2
3 2
2.0 1.0
0.0 -1.0
1.0 3.0
2 6
1.0 -0.5 2.0 0.5 -1.0 1.5
0.5 2.0 -1.0 1.0 0.25 -0.5
6 2
1.0 0.0
0.5 -1.0
-2.0 1.5
1.0 1.0
0.25 2.0
-0.5 0.5
3
```

**Test Cases —** `out.txt`

```
{'hidden_per_gpu': 2, 'w1_shard_shape': [3, 2], 'w2_shard_shape': [2, 2], 'collectives_per_block': 1, 'gpu0_partial_sum': 4.875, 'output_sum': 13.0, 'matches': True}
{'hidden_per_gpu': 2, 'w1_shard_shape': [2, 2], 'w2_shard_shape': [2, 2], 'collectives_per_block': 1, 'gpu0_partial_sum': 1.75, 'output_sum': 10.75, 'matches': True}
```

**Grader Notes:**

- **Environment:** `torch` 2.13.0 on Python 3.12.13, CPU. Milliseconds per case. No process group,
  no GPU.
- **The matmuls produce the graded value.** `gpu0_partial_sum` and `output_sum` require actually
  performing the sharded computation; `matches` is the equivalence the strategy rests on. The
  question's real content is *which axis each matrix is cut along and which collective the second cut
  implies* — get either wrong and `matches` goes false.
- **Why the pairing needs only one collective.** Device `s` produces hidden columns `s`, and those
  are exactly the rows of `w2` it owns, so its slice flows from the first matmul into the second with
  no exchange in between; the activation is elementwise and so does not need the neighbours' columns
  either. Only the final partial sums have to be combined. That is the "minimizing the number of
  communication points" claim made concrete, and it is why `collectives_per_block` is 1 rather than 2.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L6_Scaling_AI_Applications.md`:
  - *The two split styles* — **lines 256–257**, verbatim: "**Column Parallelism** — split the weight
    matrix along the output dimension. Each GPU computes a slice of the output, then results are
    gathered (all-gather) to reconstruct the full output." and "**Row Parallelism** — split the weight
    matrix along the input dimension. Each GPU computes partial sums from its input slice, then
    results are combined (all-reduce or reduce-scatter) to produce the final output." Steps 2–4 are
    those two sentences: the axes come from them, and so does the choice of collective — partial sums
    are combined, slices are gathered.
  - *The pairing* — **line 259**, verbatim: "In a Transformer block, these two styles are typically
    paired: column-parallel for the first linear layer, row-parallel for the second, minimizing the
    number of communication points per block." This is the question's spine, and step 4's count is
    that clause.
  - *That TP splits weights, not data* — **lines 250 and 254**: "each GPU stores and computes on a
    **shard** of the layer's weights… the split happens *within* a single matrix multiplication".
    The Note's "every device sees the whole input" is that distinction, and it is what separates this
    question from Q1.
  - *Collectives live inside the layer* — **line 263**: "TP requires **collectives inside every
    layer** — all-reduce, reduce-scatter, or all-gather depending on the sharding style."
  - *What the split buys* — **line 269**: "per-GPU model state drops roughly by `1/TP_degree`", which
    is what `hidden_per_gpu` and the two shard shapes quantify.
  - **Disclosed, not taught:**
    - The **ReLU**. The material says "MLP layers" without naming an activation. It is specified in
      step 1 because it makes the equivalence non-trivial — without a nonlinearity a solution could
      collapse `w1 @ w2` into one matrix and never shard anything. A collapsing solution would still
      be numerically right on a linear pair; with the ReLU it is not.
    - `"gpu0_partial_sum"` and `"output_sum"` as reported scalars. The material never reduces a
      tensor to a number; these exist so the computation cannot be skipped in favour of returning
      shapes and `True`.
- **Determinism.** Every test value is a small dyadic rational, so both matmul chains are exact:
  computed in `float32` **and** `float64`, all seven values are byte-identical, and `max_abs_diff`
  is exactly 0.0 in both cases (which is why it is not itself reported — `matches` carries it).
- Compare the integers and `"matches"` exactly, the shape lists element-wise, and the two sums with
  tolerance `1e-4`.
- **What each case is for:**
  - **Case 1** — `tp_degree` 2 on a 4-wide hidden layer, and a non-square block (3 inputs, 2
    outputs), so a solution that transposes a shard is caught by the shape keys.
  - **Case 2** — `tp_degree` **3** on a 6-wide hidden layer, so the shard count is not a power of two
    and `gpu0_partial_sum` (1.75) is a small fraction of `output_sum` (10.75). A solution that shards
    only into two, or that hardcodes two devices, is caught here. It also has a *wider* hidden
    dimension than input or output, which is the realistic MLP shape.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Both matrices cut along the same axis** (`w2` also column-split): shapes disagree and the
    matmul raises `RuntimeError: mat1 and mat2 shapes cannot be multiplied` on case 1 — a loud
    failure.
  - **Combining the partials by concatenation instead of summing** (treating them as slices, i.e.
    the all-gather that column-parallel would need): the combined tensor has `tp_degree ×` the
    output columns, `output_sum` is unchanged at 13.0 / 10.75 — **the sum is invariant to this
    mistake** — but `matches` goes `False` on both cases. Worth knowing: `output_sum` alone does not
    catch it; `matches` does.
  - **Averaging the partials instead of summing**: `output_sum` 6.5 / 3.5833 and `matches` False —
    caught on both.
  - **Applying the activation after combining** (`relu` moved outside the per-device work): case 1
    gives `output_sum` 15.75 and `matches` False — caught on both, and this is the reading that shows
    why the activation has to be elementwise on the local slice.
  - **Sharding the input `x` as well** (confusing TP with DP): the second matmul's shapes still line
    up but the result is wrong; `output_sum` 6.75 on case 1, `matches` False — caught on both.
  - **Reporting 2 collectives per block** (one after each matrix): caught on both cases by
    `"collectives_per_block"` alone.
  - **Shard shapes reported transposed**: `[2, 3]` / `[2, 2]` on case 1 — caught by case 1, where the
    two shards have different shapes; case 2's shards are both `[2, 2]` and cannot catch it, so
    **case 1 must stay in any shipped subset.**
- **Overlap check:** Q1 of this file splits data and averages gradients; this one splits weights and
  sums partial outputs. `M2-L8` Q4 flattens and shards a parameter buffer but never multiplies
  anything. No shared graded value.
- Both cases executed against the reference solution.

---

## Q3: Hiding the Gradient All-Reduce Behind the Backward Pass

**Context:** Data parallelism costs one gradient exchange per step, and on a large model that
exchange moves as many bytes as the model has parameters. Paying for it serially, after the backward
pass finishes, would be ruinous — so frameworks do two things instead. They group gradients into
buckets and launch each bucket's exchange the moment that bucket fills, rather than waiting for the
whole backward; and they run those exchanges on a separate stream, so they proceed while the
remaining layers are still computing gradients. What matters in practice is how much of the
communication that arrangement actually hides, and how much is left exposed at the end, because only
the exposed part lengthens the step.

**Problem Statement:**

Write a function
`ddp_overlap_report(layer_backward_ms, layer_grad_mb, bucket_mb, bandwidth_mb_per_ms)`.

The two lists are aligned by index and given in **forward order**: entry `i` is layer `i`'s backward
duration in milliseconds and the size of its gradient in megabytes.

1. The backward pass runs the layers in **reverse** order, starting at time `0`. Each layer occupies
   the stream for its own duration, one after another with no gaps. Report the time the backward pass
   finishes.
2. As each layer's backward completes, its gradient joins the bucket currently being filled. When
   that bucket's contents reach or exceed `bucket_mb`, it is closed and handed to the communication
   stream at that moment. Once the backward pass has finished, any bucket still open and non-empty is
   closed and handed over at that time. Report how many buckets that produced, and the size of each
   in the order they were handed over, rounded to 4 decimal places.
3. The communication stream handles one bucket at a time, in the order handed over. A bucket's
   exchange starts when the stream is free and the bucket has been handed over — whichever is later —
   and takes its size divided by `bandwidth_mb_per_ms` milliseconds. Report when the last exchange
   finishes.
4. Report the **exposed** communication — how much of it extends past the end of the backward pass,
   never less than zero — and the share of total communication time that was successfully hidden, as
   a percentage rounded to 2 decimal places.
5. Return a dictionary with exactly these six keys: `"num_buckets"` as an integer,
   `"bucket_sizes_mb"` as a list of floats, and `"backward_end_ms"`, `"last_comm_end_ms"`,
   `"exposed_comm_ms"` and `"hidden_pct"` as floats.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: layer_backward_ms (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 2: layer_grad_mb (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 3: bucket_mb (float)
    Single line: one float
  Argument 4: bandwidth_mb_per_ms (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `ddp_overlap_report()` on a new line.

**Sample Input:**

```
layer_backward_ms   = [4.0, 6.0, 5.0, 8.0, 3.0]
layer_grad_mb       = [10.0, 30.0, 20.0, 40.0, 15.0]
bucket_mb           = 25.0
bandwidth_mb_per_ms = 5.0
```

**Sample Output:**

```
{'num_buckets': 3, 'bucket_sizes_mb': [55.0, 50.0, 10.0], 'backward_end_ms': 26.0, 'last_comm_end_ms': 34.0, 'exposed_comm_ms': 8.0, 'hidden_pct': 65.22}
```

**Note:** The input handling is already in place — you only need to implement the function. This is a
timeline, not a formula: work the two streams forward in time and read the answers off the schedule.
A bucket may overshoot `bucket_mb` — a single layer's gradient can exceed it on its own, and a bucket
is never split — so the sizes you report are the sizes that were actually sent. Note that the layer
whose gradient is ready *first* is the **last** layer, which is why the lists arrive in forward order
and are consumed backwards.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: ddp_overlap_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. layer_backward_ms   → List of Floats
2. layer_grad_mb       → List of Floats
3. bucket_mb           → Float
4. bandwidth_mb_per_ms → Float
```

(Six values must come back, so they fold into one `Dictionary`. Bandwidth is given in MB per
millisecond so the whole question stays in one pair of units and no conversion is hidden in it.)

**Reference Solution:**

```python
def ddp_overlap_report(layer_backward_ms: list, layer_grad_mb: list,
                       bucket_mb: float, bandwidth_mb_per_ms: float) -> dict:
    now = 0.0
    open_size = 0.0
    handovers = []

    for i in range(len(layer_backward_ms) - 1, -1, -1):
        now += layer_backward_ms[i]
        open_size += layer_grad_mb[i]
        if open_size >= bucket_mb:
            handovers.append((now, open_size))
            open_size = 0.0

    backward_end = now
    if open_size > 0:
        handovers.append((backward_end, open_size))

    stream_free = 0.0
    for ready, size in handovers:
        stream_free = max(ready, stream_free) + size / bandwidth_mb_per_ms

    comm_total = sum(size / bandwidth_mb_per_ms for _, size in handovers)
    exposed = max(0.0, stream_free - backward_end)

    return {
        "num_buckets": len(handovers),
        "bucket_sizes_mb": [round(size, 4) for _, size in handovers],
        "backward_end_ms": round(backward_end, 4),
        "last_comm_end_ms": round(stream_free, 4),
        "exposed_comm_ms": round(exposed, 4),
        "hidden_pct": round(100.0 * (comm_total - exposed) / comm_total, 2),
    }
```

**Test Cases —** `in.txt`

```
3
5
4.0 6.0 5.0 8.0 3.0
5
10.0 30.0 20.0 40.0 15.0
25.0
5.0
4
1.0 1.0 1.0 1.0
4
50.0 50.0 50.0 50.0
25.0
2.0
3
20.0 20.0 20.0
3
5.0 5.0 5.0
100.0
1.0
```

**Test Cases —** `out.txt`

```
{'num_buckets': 3, 'bucket_sizes_mb': [55.0, 50.0, 10.0], 'backward_end_ms': 26.0, 'last_comm_end_ms': 34.0, 'exposed_comm_ms': 8.0, 'hidden_pct': 65.22}
{'num_buckets': 4, 'bucket_sizes_mb': [50.0, 50.0, 50.0, 50.0], 'backward_end_ms': 4.0, 'last_comm_end_ms': 101.0, 'exposed_comm_ms': 97.0, 'hidden_pct': 3.0}
{'num_buckets': 1, 'bucket_sizes_mb': [15.0], 'backward_end_ms': 60.0, 'last_comm_end_ms': 75.0, 'exposed_comm_ms': 15.0, 'hidden_pct': 0.0}
```

**Grader Notes:**

- **Environment:** standard library only, Python 3.14 or 3.12. Microseconds per case.
- **This is a simulation, not a formula.** There is no closed form for `last_comm_end_ms`: it depends
  on the interleaving of two streams, and a bucket handed over while the stream is busy waits. The
  question replaced an arithmetic one that evaluated a stated definition over a supplied trace; here
  the timeline has to be constructed, and every one of the six values falls out of it.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L6_Scaling_AI_Applications.md`:
  - *One exchange per step, sized like the model* — **line 213**: "DDP introduces a single
    communication step per training iteration: the **gradient all-reduce**", and the same line's
    "modern frameworks overlap it with backward computation using hooks — as soon as a layer's
    gradients are ready, the all-reduce for that layer launches while the next layer's backward is
    still running." Step 2's launch-when-ready rule is that clause.
  - *Bucketing* — **line 231**, verbatim: "**Gradient bucketing** — frameworks like PyTorch group
    small gradient tensors into larger buckets before all-reduce, reducing the number of collective
    calls and improving bandwidth utilization." Step 2's accumulate-then-close rule is that sentence,
    and `num_buckets` is the "number of collective calls" it refers to.
  - *A separate stream, and what overlap buys* — **line 232**, verbatim: "**Overlap communication
    with compute** — using backward hooks, gradient all-reduce runs concurrently with the remaining
    backward pass on separate CUDA streams, hiding much of the communication cost." Steps 3 and 4 are
    that sentence made measurable: `hidden_pct` is "much of the communication cost" quantified.
  - *Why it matters* — **line 220**: "as GPU count grows, the gradient all-reduce takes longer
    relative to compute", the communication-bound regime that case 2 illustrates.
  - *Volume scales with parameters* — **line 215**: "Communication volume scales with the number of
    parameters", which is why the per-layer gradient sizes are an input.
  - **Disclosed, not taught:**
    - The single communication stream, and that a bucket handed over while it is busy queues behind
      the one in flight. The material says "separate CUDA streams" without saying how many; step 3
      fixes one, which is both the common case and the only choice with a determinate answer.
    - Reverse consumption of the layer lists. The material says gradients become ready as backward
      proceeds; step 1 and the Note make explicit that this means the last layer first.
    - `"hidden_pct"` as a reported figure. Defined in step 4 against total communication time.
- **Determinism.** All arithmetic on exactly representable decimals; every case re-runs
  byte-identical. `hidden_pct` on case 1 is `100 × (23 − 8) / 23 = 65.2173…` → 65.22.
- Compare `"num_buckets"` exactly, `"bucket_sizes_mb"` element-wise with tolerance `1e-4`, the three
  times with `1e-4`, and `"hidden_pct"` with `1e-2`.
- **What each case is for:**
  - **Case 1** — the ordinary regime, and the one that exercises every rule at once. Three buckets:
    the first closes at 11 ms holding **55 MB** (layers 4 and 3 in reverse order, 15 + 40, overshooting
    the 25 MB target because a bucket is never split), the second at 22 ms holding 50 MB, and the
    third is the tail flush of 10 MB at 26 ms. The stream is still busy with bucket 1 when bucket 2
    arrives, so the queueing rule bites here. 8 ms of the 23 ms of communication is left exposed.
  - **Case 2** — communication-bound: a 4 ms backward against 100 ms of exchanges, so 97 of them are
    exposed and only 3% is hidden. This is the case that catches a solution which assumes overlap
    hides everything, and the only one where the stream is the bottleneck throughout.
  - **Case 3** — the opposite extreme: gradients so small that **no** bucket ever fills, so the single
    bucket is the tail flush handed over at the very end of a long backward. Nothing can be hidden,
    `hidden_pct` is 0.0, and `num_buckets` is 1. This is the case that catches a solution which never
    flushes the open bucket — it would report 0 buckets and crash on the percentage.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Forgetting the tail flush** (dropping a non-full open bucket): case 1 loses its 10 MB bucket
    (2 buckets, `last_comm_end_ms` 32.0), and case 3 divides by zero. Caught by cases 1 and 3.
  - **Consuming layers in forward order**: case 1's buckets become `[40.0, 55.0, 15.0]` handed over
    at 10 / 23 / 26 ms, `last_comm_end_ms` 37.0 and `exposed_comm_ms` 11.0 — caught by case 1. Cases
    2 and 3 have uniform layers and cannot catch it, so **case 1 must stay in any shipped subset.**
  - **Splitting a bucket at exactly `bucket_mb`** (carrying the excess into the next bucket): case 1
    gives `[25.0, 25.0, 25.0, 25.0, 15.0]` — five buckets — caught on both cases 1 and 2.
  - **Closing only when strictly greater than `bucket_mb`**: case 2's layers are 50 MB against a
    25 MB target so it is unaffected, but a bucket landing exactly on the target would differ; no
    shipped case sits exactly on the boundary, so step 2's "reach or exceed" is a specification
    rather than a graded distinction. Noted rather than claimed covered.
  - **Ignoring the stream's occupancy** (each exchange starting the moment its bucket is handed
    over): case 1 gives `last_comm_end_ms` 28.0 and `exposed_comm_ms` 2.0; case 2 gives 29.0 and
    25.0 — caught on both.
  - **Exposed time as total communication minus backward time**: case 1 gives −3.0 clamped to 0.0
    and `hidden_pct` 100.0 — caught by cases 1 and 3.
  - **`hidden_pct` measured against wall-clock instead of communication time**: 76.47 / 3.96 / 20.0
    against 65.22 / 3.0 / 0.0 — caught on all three.
- **Overlap check:** Q1 of this file performs the gradient averaging this question only sizes and
  schedules; it computes no times. Q4 simulates a pipeline schedule with a different unit model.
  `M2-L8` Q3 reports DDP and FSDP communication *volumes* as byte totals and never places them in
  time. No shared graded value.
- All three cases executed against the reference solution.

---

## Q4: Building the GPipe and 1F1B Pipeline Schedules

**Context:** Splitting a model across devices by layer only pays off if the devices are kept busy,
and they are not busy at the start or the end of a batch — the first stage works alone until the
second has something to do, and the last stage finishes alone. That idle time is the pipeline bubble,
and the way to shrink it is to feed many small micro-batches through the stages at once. Two
schedules dominate. One runs every forward before any backward, which is simple but obliges each
stage to keep every micro-batch's activations alive until the backward sweep reaches it. The other
interleaves them, so a micro-batch's activations are released early. They cost the same time; they do
not cost the same memory.

**Problem Statement:**

Write a function `pipeline_schedule_report(num_stages, num_micro_batches)`.

The model is divided into `p = num_stages` stages, one per device, and the batch into
`m = num_micro_batches` micro-batches (`m` is never smaller than `p`). Time advances in whole steps.
In one step a stage performs at most one unit of work, where a unit is either the forward or the
backward of one micro-batch on that stage. Every unit takes exactly one step. The ordering rules are:

- a micro-batch's forward on a stage requires its forward on the previous stage to have completed;
- its backward on the **last** stage requires its forward on that stage to have completed;
- its backward on any other stage requires its backward on the next stage to have completed.

1. Simulate the **GPipe** schedule: every stage runs all `m` forwards in micro-batch order, and no
   stage may begin any backward until every forward on every stage has completed; then all `m`
   backwards in the same order.
2. Simulate the **1F1B** schedule: stage `s` (numbered from `0`) begins with `p − 1 − s` forwards,
   then alternates one forward and one backward for as long as forwards remain, then runs its
   remaining backwards. Micro-batches are taken in order within each of the forward and backward
   sequences.
3. For each schedule report the number of steps until all work is done, and the bubble as the
   percentage of stage-steps that were idle — count the stage-steps as steps × stages, subtract the
   units actually performed, and express the remainder as a percentage rounded to 2 decimal places.
4. For each schedule report the peak activation count: a micro-batch's activation is held on a stage
   from the moment its forward there completes until the moment its backward there completes, and the
   figure to report is the largest number of activations held on any single stage at any point,
   measured after each step.
5. Report also the bubble the material's rule of thumb predicts, `(p − 1) / (p − 1 + m)`, as a
   percentage rounded to 2 decimal places.
6. Return a dictionary with exactly these seven integer-or-float keys: `"gpipe_steps"`,
   `"gpipe_bubble_pct"`, `"gpipe_peak_activations"`, `"onefonebee_steps"`,
   `"onefonebee_bubble_pct"`, `"onefonebee_peak_activations"` and `"formula_bubble_pct"`.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: num_stages (integer)
    Single line: one integer
  Argument 2: num_micro_batches (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `pipeline_schedule_report()` on a new line.

**Sample Input:**

```
num_stages        = 4
num_micro_batches = 8
```

**Sample Output:**

```
{'gpipe_steps': 22, 'gpipe_bubble_pct': 27.27, 'gpipe_peak_activations': 8, 'onefonebee_steps': 22, 'onefonebee_bubble_pct': 27.27, 'onefonebee_peak_activations': 4, 'formula_bubble_pct': 27.27}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing is
loaded; both schedules are built from the two counts. Decide every stage's action for a step from the
state as it stood at the **start** of that step, then apply them together — a micro-batch cannot cross
two stages within one step. Each stage follows its own schedule strictly in order: if the next unit it
is due to perform is not yet permitted, that stage idles rather than skipping ahead. The two schedules
are expected to agree on two of the three quantities you report, which is a useful check that both
simulations are right.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: pipeline_schedule_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. num_stages        → Integer
2. num_micro_batches → Integer
```

(Seven values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
def pipeline_schedule_report(num_stages: int, num_micro_batches: int) -> dict:
    p, m = num_stages, num_micro_batches

    def run(schedule):
        plan = {}
        for s in range(p):
            if schedule == "gpipe":
                plan[s] = ["F"] * m + ["B"] * m
            else:
                warmup = p - 1 - s
                seq = ["F"] * warmup
                remaining_f, remaining_b = m - warmup, m
                while remaining_f > 0:
                    seq += ["F", "B"]
                    remaining_f -= 1
                    remaining_b -= 1
                plan[s] = seq + ["B"] * remaining_b

        ptr = {s: 0 for s in range(p)}
        next_f = {s: 0 for s in range(p)}
        next_b = {s: 0 for s in range(p)}
        f_done, b_done = set(), set()
        stored = {s: set() for s in range(p)}
        step = busy = peak = 0

        while len(b_done) < p * m:
            step += 1
            picks = []
            all_forwards_done = len(f_done) == p * m
            for s in range(p):
                if ptr[s] >= len(plan[s]):
                    continue
                if plan[s][ptr[s]] == "F":
                    i = next_f[s]
                    if s == 0 or (i, s - 1) in f_done:
                        picks.append((s, "F", i))
                else:
                    if schedule == "gpipe" and not all_forwards_done:
                        continue
                    i = next_b[s]
                    if (i, s) in f_done and (s == p - 1 or (i, s + 1) in b_done):
                        picks.append((s, "B", i))
            for s, kind, i in picks:
                busy += 1
                ptr[s] += 1
                if kind == "F":
                    f_done.add((i, s)); stored[s].add(i); next_f[s] += 1
                else:
                    b_done.add((i, s)); stored[s].discard(i); next_b[s] += 1
            peak = max(peak, max(len(v) for v in stored.values()))

        bubble = round(100.0 * (step * p - busy) / (step * p), 2)
        return step, bubble, peak

    gpipe_steps, gpipe_bubble, gpipe_peak = run("gpipe")
    onefonebee_steps, onefonebee_bubble, onefonebee_peak = run("1f1b")

    return {
        "gpipe_steps": gpipe_steps,
        "gpipe_bubble_pct": gpipe_bubble,
        "gpipe_peak_activations": gpipe_peak,
        "onefonebee_steps": onefonebee_steps,
        "onefonebee_bubble_pct": onefonebee_bubble,
        "onefonebee_peak_activations": onefonebee_peak,
        "formula_bubble_pct": round(100.0 * (p - 1) / (p - 1 + m), 2),
    }
```

**Test Cases —** `in.txt`

```
3
4
8
2
4
3
12
```

**Test Cases —** `out.txt`

```
{'gpipe_steps': 22, 'gpipe_bubble_pct': 27.27, 'gpipe_peak_activations': 8, 'onefonebee_steps': 22, 'onefonebee_bubble_pct': 27.27, 'onefonebee_peak_activations': 4, 'formula_bubble_pct': 27.27}
{'gpipe_steps': 10, 'gpipe_bubble_pct': 20.0, 'gpipe_peak_activations': 4, 'onefonebee_steps': 10, 'onefonebee_bubble_pct': 20.0, 'onefonebee_peak_activations': 2, 'formula_bubble_pct': 20.0}
{'gpipe_steps': 28, 'gpipe_bubble_pct': 14.29, 'gpipe_peak_activations': 12, 'onefonebee_steps': 28, 'onefonebee_bubble_pct': 14.29, 'onefonebee_peak_activations': 3, 'formula_bubble_pct': 14.29}
```

**Grader Notes:**

- **Environment:** standard library only, Python 3.14 or 3.12. Microseconds per case.
- **This is a simulation whose answer the formula corroborates.** The predecessor question for this
  class evaluated `(p − 1) / (p − 1 + m)` directly and returned it; here that expression is reported
  **alongside** a measured bubble that has to come out of a schedule the learner constructs. On all
  three cases the two agree exactly, which is the strongest available evidence that a submitted
  simulation is right — and a solution that simply returns the formula three times fails on the peak
  activation counts, which no formula in the material supplies.
- **Three independent cross-checks hold on every case**, and were used to validate the reference:
  - total steps equal `2 × (m + p − 1)` — 22, 10 and 28;
  - the measured bubble equals `(p − 1) / (p − 1 + m)` exactly, for **both** schedules;
  - GPipe's peak equals `m` and 1F1B's equals `p`.
  An earlier draft of the reference mutated stage state mid-step, letting a micro-batch cross several
  stages in one step; it reported 19 steps and a 15.79% bubble for case 1 against the formula's
  27.27%, which is how the bug was found. The Note's "state as it stood at the start of that step" is
  that lesson. A second draft used a greedy "prefer backward whenever one is ready" rule in place of
  1F1B's warmup; it produced the right step count and bubble but a peak of 7 instead of 4, because
  stage 0 kept running forwards. **The peak activation count is the only value that distinguishes a
  real 1F1B schedule from a merely work-conserving one** — do not drop it.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L6_Scaling_AI_Applications.md`:
  - *Stages, micro-batches and the overlap* — **lines 296–298**: "**Partition** — divide the model's
    layers into `p` stages", "**Micro-batch** — split the global batch into smaller micro-batches",
    and "**Pipeline** — feed micro-batches through the stages in sequence. While GPU-1 processes
    micro-batch-2's forward pass, GPU-2 is already working on micro-batch-1". The dependency rules in
    the statement are that third sentence made precise.
  - *The bubble and its rule of thumb* — **line 302**, verbatim: "The main overhead in PP is the
    **pipeline bubble** — idle time at the start and end of each batch where some GPUs have nothing to
    do. The bubble ratio is roughly `(p-1) / (p-1+m)` where `p` is the number of stages and `m` is the
    number of micro-batches. More micro-batches → smaller bubble → better utilization, but also more
    activation memory." Step 3 measures the first clause, step 5 reports the second, and step 4 is the
    trade-off the last clause names.
  - *GPipe* — **line 306**, verbatim: "**GPipe** — all forwards first, then all backwards. Simple but
    high activation memory." Step 1 is that sentence; `gpipe_peak_activations` equalling `m` is the
    "high activation memory".
  - *1F1B* — **line 307**, verbatim: "**1F1B (One Forward, One Backward)** — after a warmup, alternate
    one forward and one backward per step. More memory-efficient since activations are freed earlier."
    Step 2 is that sentence, with the warmup length supplied (see below).
  - *Why the schedule matters at all* — **line 317**: "The main challenge is minimizing the pipeline
    bubble through smart scheduling and choosing the right number of micro-batches."
  - **Disclosed, not taught:**
    - **The warmup length**, `p − 1 − s`. The material says "after a warmup" without saying how long,
      and the answer depends on it, so step 2 states it. This is the one number a learner could not
      derive from the material, and it is given rather than left to guess.
    - The unit-time model — every forward and backward costing one step, one unit per stage per step.
      The material describes the schedule qualitatively; a determinate answer needs a clock.
    - The peak-activation definition, including that it is measured after each step and taken over a
      single stage rather than the whole pipeline.
- **Determinism.** Pure integer simulation with two roundings; all three cases re-run byte-identical.
- Compare the four integers exactly and the three percentages with tolerance `1e-2`.
- **What each case is for:**
  - **Case 1** — `p = 4`, `m = 8`. The peaks separate cleanly (8 against 4), and 22 steps is long
    enough that an off-by-one in the drain phase shows.
  - **Case 2** — `p = 2`, the smallest pipeline that is still a pipeline. Its warmup is `1 − s`, so
    stage 1 has **no** warmup at all — the case that catches a solution assuming every stage warms up.
  - **Case 3** — `m = 4p`, the ratio the wider material recommends for efficiency. The bubble falls to
    14.29% and the peaks are furthest apart (12 against 3), so a solution that confuses the two
    schedules' memory behaviour is most visible here.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Mutating stage state within a step** (no start-of-step snapshot): 19 / 8 / 23 steps against
    22 / 10 / 28, and bubbles that disagree with the formula — caught on all three, and the formula
    key makes the disagreement self-evident.
  - **1F1B as greedy prefer-backward** (no warmup cap): correct steps and bubble on all three, peak
    7 / 3 / 11 against 4 / 2 / 3 — caught on all three by the peak alone.
  - **GPipe without the global forward barrier** (each stage starting backwards as soon as it can):
    GPipe collapses onto the 1F1B numbers, peak 4 / 2 / 3 — caught on all three.
  - **Bubble measured against useful work rather than stage-steps** (`idle / busy`): 37.5 / 25.0 /
    16.67 — caught on all three.
  - **Peak taken across the whole pipeline instead of one stage**: 32 / 8 / 36 — caught on all three.
  - **Peak measured before the step's units are applied**: 7 / 3 / 11 for GPipe — caught on all three.
  - **Returning the formula for both measured bubbles**: passes the three bubble keys by construction
    and fails both peak keys. This is why the peaks are graded and why a formula-only solution cannot
    pass.
- **Overlap check:** Q3 of this file simulates two streams in continuous time with sizes and
  bandwidths; this one simulates a discrete stage grid and never converts to bytes or milliseconds.
  `M2-L8` Q1/Q3 report memory totals and never schedule anything. No shared graded value.
- All three cases executed against the reference solution.
