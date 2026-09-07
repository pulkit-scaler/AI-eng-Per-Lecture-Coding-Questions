# Module 2, Lecture 8 — Advanced Fine-Tuning Techniques

Four coding questions covering the whole of the material: the **training-memory budget** and the
single-GPU gap it opens (Q1), the **five collective communication primitives** and what each rank
actually holds afterwards (Q2), **replicated versus sharded** per-GPU memory and per-step
communication volume across the three sharding strategies (Q3), and the **transient peak** when one
sharded unit is gathered for its forward pass (Q4).

Q4 builds and shards a real `FlatParameter` with `torch`; the other three are arithmetic and
semantics on a configuration — standard library only, no GPU, no
model download, no third-party import, milliseconds per case. The source material for this topic is
prose and diagrams with no runnable code, so every question grades a relationship the material
states explicitly; each one is traced line-by-line in its **Scope trace** grader-note bullet, and no
question depends on a coefficient the solver has to recall from memory.

---

## Q1: Sizing a Training Run Against a Single GPU

**Context:** Inference memory and training memory are different beasts. Serving a model needs little
more than its weights, but training it must also hold a gradient for every trainable parameter, the
optimizer's running statistics for every parameter, and the intermediate activations the forward pass
saves for backpropagation to consume. Teams routinely underestimate the requirement several-fold
because they budget only for the weights, then hit an out-of-memory failure minutes into the first
run. Costing the four components out beforehand is what tells you whether a job belongs on the GPU
you have — or whether it never fit on one device at all.

**Problem Statement:**

Write a function
`training_memory_budget(param_count, param_bytes, optimizer_states_per_param, activation_gb, gpu_memory_gb)`.

1. `param_count` is the model's parameter count, and `param_bytes` is the number of bytes one
   parameter occupies in the training precision (a common value is 2 for 16-bit training and 4 for
   32-bit). Compute the memory the parameters themselves occupy.
2. Backpropagation produces one gradient per trainable parameter, and a gradient has the same shape
   and the same precision as the parameter it belongs to. Compute the gradient memory.
3. The optimizer keeps `optimizer_states_per_param` running statistics for every parameter — for
   instance a momentum term, a variance term, and a full-precision master copy of the weights. Every
   one of these states is held at 32-bit precision, i.e. 4 bytes each, regardless of the precision
   the model itself trains in. Compute the optimizer-state memory.
4. `activation_gb` is a supplied estimate, already in GB, of the intermediate outputs the forward
   pass must keep for the backward pass.
5. Convert each component to GB using 1 GB = 10^9 bytes, and add the four together to get the run's
   total requirement.
6. Return a dictionary with exactly these six keys: `"param_gb"`, `"grad_gb"`, `"optimizer_gb"`,
   `"activation_gb"` and `"total_gb"` — each a float rounded to 2 decimal places — plus `"fits"`, a
   boolean that is `True` when the total does not exceed `gpu_memory_gb`.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: param_count (integer)
    Single line: one integer
  Argument 2: param_bytes (float)
    Single line: one float
  Argument 3: optimizer_states_per_param (integer)
    Single line: one integer
  Argument 4: activation_gb (float)
    Single line: one float
  Argument 5: gpu_memory_gb (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `training_memory_budget()` on a new line.

**Sample Input:**

```
param_count = 7000000000
param_bytes = 2.0
optimizer_states_per_param = 3
activation_gb = 8.5
gpu_memory_gb = 80.0
```

**Sample Output:**

```
{'param_gb': 14.0, 'grad_gb': 14.0, 'optimizer_gb': 84.0, 'activation_gb': 8.5, 'total_gb': 120.5, 'fits': False}
```

**Note:** The input handling is already in place — you only need to implement the function. This is
arithmetic on a configuration: nothing needs to be loaded, trained or imported. `param_bytes` arrives
as a float because sub-byte precisions exist, so keep the arithmetic in floating point rather than
integer-dividing anywhere.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: training_memory_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. param_count                → Integer
2. param_bytes                → Float
3. optimizer_states_per_param → Integer
4. activation_gb              → Float
5. gpu_memory_gb              → Float
```

(`param_bytes` and `optimizer_states_per_param` would be implied by a trainer's precision/optimizer
settings — required here and supplied in every test case. Six values must come back, so they fold
into one `Dictionary`; the fit verdict rides along as a boolean value inside it, since the tool
returns exactly one object.)

**Reference Solution:**

```python
def training_memory_budget(param_count: int, param_bytes: float,
                           optimizer_states_per_param: int, activation_gb: float,
                           gpu_memory_gb: float) -> dict:
    GB = 1e9
    param_gb = param_count * param_bytes / GB
    grad_gb = param_count * param_bytes / GB
    optimizer_gb = param_count * 4 * optimizer_states_per_param / GB
    total_gb = param_gb + grad_gb + optimizer_gb + activation_gb
    return {
        "param_gb": round(param_gb, 2),
        "grad_gb": round(grad_gb, 2),
        "optimizer_gb": round(optimizer_gb, 2),
        "activation_gb": round(activation_gb, 2),
        "total_gb": round(total_gb, 2),
        "fits": round(total_gb, 2) <= gpu_memory_gb,
    }
```

**Test Cases —** `in.txt`

```
4
7000000000
2.0
3
8.5
80.0
1500000000
2.0
3
4.5
40.0
3000000000
4.0
2
6.25
80.0
4000000000
2.0
3
18.0
80.0
```

**Test Cases —** `out.txt`

```
{'param_gb': 14.0, 'grad_gb': 14.0, 'optimizer_gb': 84.0, 'activation_gb': 8.5, 'total_gb': 120.5, 'fits': False}
{'param_gb': 3.0, 'grad_gb': 3.0, 'optimizer_gb': 18.0, 'activation_gb': 4.5, 'total_gb': 28.5, 'fits': True}
{'param_gb': 12.0, 'grad_gb': 12.0, 'optimizer_gb': 24.0, 'activation_gb': 6.25, 'total_gb': 54.25, 'fits': True}
{'param_gb': 8.0, 'grad_gb': 8.0, 'optimizer_gb': 48.0, 'activation_gb': 18.0, 'total_gb': 82.0, 'fits': False}
```

**Grader Notes:**

- **Environment:** Python standard library only; no imports at all in the reference. All four cases
  executed in well under a second (Python 3.14.6). Compare the five floats with tolerance `1e-3` and
  `"fits"` exactly. Dictionary key order is not significant.
- **Scope trace** — every construct and every numeric coefficient, against
  `modules/02-advanced-ai-agents/markdown/L8_Advanced_Fine_Tuning_Techniques.md`:
  - Four competing components (parameters, gradients, optimizer states, activations) — line 15, with
    a section each at lines 21–32, 34–36, 38–52, 54–58.
  - `param_bytes` values 2 / 4 (and the 1 / 0.5 the question never uses) — the precision table at
    lines 25–30.
  - Gradients at the parameters' own precision and shape — line 36 verbatim ("Each gradient has the
    same shape and precision as the parameter it corresponds to").
  - Optimizer states: three per parameter for Adam, each at 32-bit — lines 42–44 name the three
    (momentum, variance, FP32 master copy) and line 52 states "4 bytes × 3 = **12 bytes per
    parameter**". The `4` coefficient is therefore the material's own; `optimizer_states_per_param`
    is an argument so nothing is recalled.
  - The assembled total `(2 + 2 + K) × Ψ` with `K = 12` for Adam — lines 75 and 77; the per-component
    table at lines 68–75 is exactly case 1's 14 / 14 / 84 breakdown and its ~112 GB subtotal.
  - Activations as a supplied estimate rather than a formula: the material states only what they
    depend on (line 56: batch size, sequence length, hidden dimension, layer count) and explicitly
    omits them from its own arithmetic (line 58). Passing the estimate in as `activation_gb` is the
    only faithful option — **there is no activation formula in the source material to grade**.
  - The fit verdict against a single device — the fits-on-one-A100-80GB column at lines 91–96 and
    line 98.
  - 1 GB = 10^9 bytes is the material's own convention, not an added one: `2 × 7e9 = 14e9` bytes is
    printed as "~14 GB" (line 28) and `16 × 7.5e9` as "approximately 120 GB" (line 79). It is stated
    in the problem text anyway.
  - **Nothing is "disclosed, not taught."** `optimizer_states_per_param = 2` in case 3 is a
    generalization the material supports directly: line 44 scopes the FP32 master copy to
    "when using mixed-precision training", so a pure-32-bit run keeps momentum and variance only.
- Case 1 reproduces the material's own worked example (7B, 16-bit, Adam → 14 / 14 / 84, ~112 GB,
  does not fit 80 GB). Case 2 is the only `fits: True` case with plenty of headroom. Case 3 flips two
  coefficients at once (32-bit training, two optimizer states). Case 4 is the one where activations
  decide the verdict.
- Verified on the shipped cases — every wrong reading below was implemented and run:
  - **Gradients stored in FP32 instead of the training precision** (`4` in place of `param_bytes`):
    `grad_gb` 28.0 / 6.0 / — / 16.0. Caught by cases 1, 2 and 4. **Not** caught by case 3, whose
    `param_bytes` is already 4.0 — so at least one 2-byte case must stay in any shipped subset.
  - **Optimizer states in the training precision instead of FP32**: `optimizer_gb` 42.0 / 9.0 / — /
    24.0. Caught by 1, 2, 4; invisible on case 3 (`param_bytes * 2 == 4 * 2`).
  - **`K` hardcoded to 12** (ignoring `optimizer_states_per_param`): `optimizer_gb` 36.0 instead of
    24.0 on case 3. **Caught by case 3 only** — it is the only case whose state count is not 3, so
    case 3 must stay in any shipped subset.
  - **`param_bytes` hardcoded to 2**: 6.0 / 6.0 on case 3 instead of 12.0 / 12.0. **Caught by case 3
    only**, for the same reason.
  - **Activations reported but left out of the total**: totals 112.0 / 24.0 / 48.0 / 64.0. Caught by
    all four on `total_gb`, and case 4 additionally flips `"fits"` from `False` to `True` — that is
    the case to keep if only the verdict is graded.
  - **GiB (2^30) instead of 10^9 bytes**: 13.04 / 13.04 / 78.23 / 112.81 on case 1. Caught by all
    four, and it also flips case 4's verdict.
- **Accepted variants — both were run and return identical values on all four cases:** comparing
  `"fits"` with strict `<` rather than `<=`, and comparing the unrounded total rather than the
  reported one. No shipped case sits within `0.005 GB` of its GPU capacity (margins are 40.5, 11.5,
  25.75 and 2.0 GB), so neither distinction can decide a mark. Do not add a boundary case without
  pinning the comparison in the statement first.
- **Overlap check:** the topic-organized bank's `kv_cache_memory`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q3) is
  also a bytes-per-element sizing question returning a memory dictionary, but it sizes the
  **inference-time KV cache** from layer/head/sequence geometry and has no gradient, optimizer or
  activation term. Distinct concept; safe to ship together. Q3 of *this* file shares Q1's
  per-parameter coefficients — see its own overlap bullet.
- All four cases executed against the reference solution (Python 3.14.6, standard library only).

---

## Q2: What Each Rank Holds After a Collective

**Context:** Multi-GPU training is built on a small set of collective communication operations. Each
takes a tensor that every participating rank holds and leaves behind a specific, different result:
some reduce, some replicate, some concatenate, and some hand each rank only its own slice of the
answer. Picking the wrong one is a silent bug — the program runs, the shapes may even line up, and
the model quietly trains on the wrong numbers. Being able to say exactly what sits on rank 2 after
the call is the difference between reading a distributed training loop and guessing at it.

**Problem Statement:**

Write a function `nccl_collective(rank_inputs, collective, root)`.

1. `rank_inputs` has one row per rank: row `r` is the tensor rank `r` contributes, and every row has
   the same length. The number of rows is the world size.
2. `collective` names the operation to apply — one of `"reduce"`, `"all_reduce"`, `"broadcast"`,
   `"all_gather"`, `"reduce_scatter"`. Wherever an operation reduces, the reduction is an
   element-wise **sum** across ranks.
3. `root` is the one rank that receives the result under `"reduce"`, and the one rank whose tensor is
   the source under `"broadcast"`. The other three operations do not use it.
4. Work out what each rank holds once the operation returns:
   - `"reduce"` — the element-wise sum lands on `root` only; every other rank comes away with
     nothing.
   - `"all_reduce"` — every rank holds the element-wise sum.
   - `"broadcast"` — every rank holds a copy of `root`'s tensor; nothing is reduced.
   - `"all_gather"` — every rank holds all the ranks' tensors concatenated in rank order, rank 0's
     block first.
   - `"reduce_scatter"` — the element-wise sum is computed, then cut into `world_size` equal
     contiguous blocks, and rank `r` keeps block `r` only.
5. Return a dictionary whose keys are the rank numbers `0` through `world_size - 1` — every rank
   present — and whose value for each rank is the list of integers that rank holds afterwards. A rank
   that comes away with nothing maps to an empty list.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: rank_inputs (2d_list_int)
    Line 1: R C (number of rows, number of columns)
    Next R lines: C space-separated integers each
      (row r is rank r's tensor, so R is the world size)
  Argument 2: collective (string)
    Single line: a string
  Argument 3: root (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `nccl_collective()` on a new line.

**Sample Input:**

```
rank_inputs = [[3, 1, 4, 1],
               [5, 9, 2, 6],
               [5, 3, 5, 8]]
collective = "reduce"
root = 1
```

**Sample Output:**

```
{0: [], 1: [13, 13, 11, 15], 2: []}
```

**Note:** The input handling is already in place — you only need to implement the function. No GPUs
and no distributed runtime are involved: `rank_inputs` already carries every rank's contribution, so
the whole operation is worked out locally with plain Python. `root` is supplied on every call,
including for the three operations that ignore it.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: nccl_collective
RETURN TYPE: Dictionary

ARGUMENTS:
1. rank_inputs → 2D List of Ints
2. collective  → String
3. root        → Integer
```

(`root` defaults to rank 0 in every real collective API — required here and supplied in every test
case, including the three operations that do not read it. The natural result is one tensor per rank,
i.e. a list of records, which is not a return type: it folds into a `Dictionary` keyed by rank
number. `2D List of Ints` is argument-only, which is fine — it is only an argument.)

**Reference Solution:**

```python
def nccl_collective(rank_inputs: list, collective: str, root: int) -> dict:
    world_size = len(rank_inputs)
    count = len(rank_inputs[0])
    reduced = [sum(rank_inputs[r][i] for r in range(world_size)) for i in range(count)]

    if collective == "reduce":
        return {r: (list(reduced) if r == root else []) for r in range(world_size)}
    if collective == "all_reduce":
        return {r: list(reduced) for r in range(world_size)}
    if collective == "broadcast":
        return {r: list(rank_inputs[root]) for r in range(world_size)}
    if collective == "all_gather":
        gathered = [v for row in rank_inputs for v in row]
        return {r: list(gathered) for r in range(world_size)}
    # "reduce_scatter"
    chunk = count // world_size
    return {r: reduced[r * chunk:(r + 1) * chunk] for r in range(world_size)}
```

**Test Cases —** `in.txt`

```
5
3 4
3 1 4 1
5 9 2 6
5 3 5 8
reduce
1
4 3
7 0 2
1 4 9
6 3 5
2 8 1
all_reduce
2
3 3
3 1 4
1 5 9
2 6 5
broadcast
2
3 2
30 31
10 11
20 21
all_gather
0
3 6
1 2 3 4 5 6
10 20 30 40 50 60
100 200 300 400 500 600
reduce_scatter
0
```

**Test Cases —** `out.txt`

```
{0: [], 1: [13, 13, 11, 15], 2: []}
{0: [16, 15, 17], 1: [16, 15, 17], 2: [16, 15, 17], 3: [16, 15, 17]}
{0: [2, 6, 5], 1: [2, 6, 5], 2: [2, 6, 5]}
{0: [30, 31, 10, 11, 20, 21], 1: [30, 31, 10, 11, 20, 21], 2: [30, 31, 10, 11, 20, 21]}
{0: [111, 222], 1: [333, 444], 2: [555, 666]}
```

**Grader Notes:**

- **Environment:** Python standard library only, no imports. Five cases, milliseconds total
  (Python 3.14.6). Compare the lists **exactly** — all values are integers, so no tolerance is
  needed. Dictionary key order is not significant, but **key presence is**: a rank that holds nothing
  must appear with an empty list (see the omission wrong-reading below).
- **Compare values, not reprs.** `2D List of Ints` is expected to arrive as a plain list of lists
  (which is how the existing `2D List of Ints` questions consume it), and the reference then returns
  plain Python ints. If the runner's parser ever hands rows over as a NumPy row instead, a solution
  that slices a row through (`list(rank_inputs[root])`) would return `np.int64` values whose repr is
  not `[2, 6, 5]`, while being numerically correct. Grade element values (or coerce with `int()`),
  not the printed string.
- **Scope trace** — against
  `modules/02-advanced-ai-agents/markdown/L8_Advanced_Fine_Tuning_Techniques.md`:
  - "There are five core operations you need to know" and their names — line 214 and the figure
    caption at line 216. The question's five `collective` strings are exactly that set; no sixth
    operation is asked for and no operation outside it exists in the material.
  - `"reduce"` — lines 218–222: every rank holds an input, sum is applied across ranks, the result
    lands on a single root, "**All other ranks get nothing**", `out[i] = sum(inX[i])` on the root
    only. The empty-list convention is the literal encoding of "get nothing".
  - `"all_reduce"` — lines 226–230: same reduction, result on **every** rank, `out[i] = sum(inX[i])`
    on every rank.
  - `"broadcast"` — lines 234–238: one root sends to all others, "**No reduction — pure
    replication**", `out[i] = in[i]` copied from root to everyone.
  - `"all_gather"` — lines 242–246: each rank holds a different shard, the shards are concatenated
    and **every** rank gets the full result. The rank-order requirement is the material's own index
    formula `out[Y*count+i] = inY[i]`.
  - `"reduce_scatter"` — lines 250–254: each rank holds a full-sized tensor, the op reduces across
    ranks **and** scatters so each rank receives only its own shard;
    `outY[i] = sum(inX[Y*count+i])` fixes the blocks as contiguous and rank-indexed, which is what
    step 4 states.
  - Sum as the reduction operator — line 220 ("A reduction operation (typically **sum**)"), plus the
    four index formulas above, all written with `sum`.
  - Nothing else is required: no ring algorithm, no bandwidth model, no `torch.distributed` API. The
    material shows no code for any of this, so **plain Python is the faithful implementation, not a
    substitution** — there is no library call in the source material to match.
  - **Nothing is "disclosed, not taught."**
- Each case isolates one collective, and the per-rank data is asymmetric in every case so a wrong
  collective is visibly wrong rather than coincidentally right. Case 2 deliberately passes
  `root = 2` on an `all_reduce` and case 4 passes `root = 0` on an `all_gather`, so a solution that
  lets `root` leak into an operation that ignores it fails.
- Verified on the shipped cases — every wrong reading below was implemented and run:
  - **`reduce` treated as `all_reduce`** (sum on every rank): case 1 returns the sum on all three
    ranks. Caught by case 1 only — it is the only `reduce` case.
  - **`all_reduce` treated as `reduce`** (root only): case 2 returns `{0: [], 1: [], 2: [16, 15, 17],
    3: []}`. Caught by case 2 only.
  - **`reduce` returns root's own input, unreduced** (i.e. reduce confused with broadcast): case 1
    returns `{0: [], 1: [5, 9, 2, 6], 2: []}`. Caught by case 1.
  - **`reduce` omits the non-root ranks from the dictionary**: case 1 returns
    `{1: [13, 13, 11, 15]}` — one key instead of three. Caught by case 1; this is why key presence
    is graded.
  - **`all_gather` treated as `all_reduce`** (element-wise sum instead of concatenation): case 4
    returns `{0: [60, 63], 1: [60, 63], 2: [60, 63]}` — visibly the wrong length. Caught by case 4.
  - **`all_gather` concatenated in sorted-value order instead of rank order**: case 4 returns
    `[10, 11, 20, 21, 30, 31]` against the correct `[30, 31, 10, 11, 20, 21]`. **Caught by case 4
    only, and only because its rows are deliberately out of ascending order** — an earlier draft used
    ascending rows (`[[10,11],[20,21],[30,31]]`) and this bypass passed every case. Do not "tidy" case
    4's rows into ascending order.
  - **`all_gather` delivered to root only** (plain gather): case 4 returns the concatenation on rank
    0 and empty lists elsewhere. Caught by case 4.
  - **`broadcast` sourced from rank 0 instead of `root`**: case 3 returns `[3, 1, 4]` everywhere
    against the correct `[2, 6, 5]`. Caught by case 3, whose `root` is deliberately 2.
  - **`broadcast` reduces instead of replicating**: case 3 returns `[6, 12, 18]`. Caught by case 3.
  - **`reduce_scatter` treated as `all_reduce`** (full sum on every rank): case 5 returns the whole
    six-element sum on all three ranks. Caught by case 5.
  - **`reduce_scatter` with strided/interleaved blocks** (`reduced[r::world_size]`): case 5 returns
    `{0: [111, 444], 1: [222, 555], 2: [333, 666]}` against the correct
    `{0: [111, 222], 1: [333, 444], 2: [555, 666]}`. Caught by case 5 — this is the single most
    valuable case in the set and must not be dropped.
  - **`reduce_scatter` scatters each rank's own row without reducing**: case 5 returns
    `{0: [1, 2], 1: [30, 40], 2: [500, 600]}`. Caught by case 5.
  - **Averaging instead of summing**: cases 1, 2 and 5 return floats
    (`[4.333333333333333, …]`, `[4.0, 3.75, 4.25]`, `[37.0, 74.0]`). Caught by 1, 2, 5; cases 3 and 4
    do not reduce, so they cannot catch it.
  - **`collective` ignored, always `all_reduce`** (the laziest plausible solution): caught by cases
    1, 3, 4 and 5 — every case except the one that genuinely is an all-reduce.
- **Deliberately not tested, and no case may depend on it:** a `collective` string outside the five,
  an empty `rank_inputs`, ragged rows, a `root` out of range, or a `reduce_scatter` whose row length
  is not divisible by the world size. The statement promises equal-length rows and case 5's length
  (6) divides its world size (3). The reference's final branch is an unguarded fall-through to
  `reduce_scatter` for exactly this reason; a solution that raises on an unknown name is equally
  acceptable.
- All five cases executed against the reference solution (Python 3.14.6, standard library only).

---

## Q3: Replicated vs Sharded Placement — Per-GPU Memory and Per-Step Traffic

**Context:** Two data-parallel placements dominate large-model training. The replicated one hands
every GPU a complete copy of the training state and synchronizes gradients once per step; adding GPUs
buys throughput but not one byte of headroom, so a model that does not fit on one device still does
not fit on sixty-four. The sharded one splits the training state across the devices, so per-GPU
memory falls with the device count — but it has to move parameters around to compute with them, and
pays more network traffic per step for the privilege. There is also a middle setting that shards only
the gradients and the optimizer states and leaves the parameters replicated. Costing all three out,
against the traffic each implies, is how a training job gets matched to a cluster.

**Problem Statement:**

Write a function
`sharding_memory_and_comm(param_count, param_bytes, optimizer_states_per_param, world_size)`.

1. The full training state consists of three things: the parameters at `param_bytes` bytes each, one
   gradient per parameter stored at that same `param_bytes`, and `optimizer_states_per_param`
   optimizer statistics per parameter, each held at 32-bit precision (4 bytes each). Convert to GB
   using 1 GB = 10^9 bytes.
2. Compute the per-GPU memory under three placements across `world_size` devices:
   - `no_shard` — nothing is split; every GPU holds the entire training state.
   - `shard_grad_op` — the gradients and the optimizer states are split evenly across the devices,
     while the parameters stay replicated on every GPU.
   - `full_shard` — all three are split evenly across the devices.
3. Compute the per-step, per-device communication volume for two of them. Under `no_shard` the only
   cross-device traffic is a single all-reduce of the gradient tensor, so the volume is that tensor's
   size. Under `full_shard` the forward pass adds all-gathers of the parameters and the backward pass
   replaces the all-reduce with an all-gather plus a reduce-scatter; the resulting volume is commonly
   quoted as 1.5x the `no_shard` figure.
4. Compute how much per-GPU memory is saved by moving from `no_shard` to `full_shard`.
5. Return a dictionary with exactly these six keys, every value a float in GB rounded to 3 decimal
   places: `"no_shard_gb"`, `"shard_grad_op_gb"`, `"full_shard_gb"`, `"no_shard_comm_gb"`,
   `"full_shard_comm_gb"`, `"memory_saving_gb"`.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: param_count (integer)
    Single line: one integer
  Argument 2: param_bytes (float)
    Single line: one float
  Argument 3: optimizer_states_per_param (integer)
    Single line: one integer
  Argument 4: world_size (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `sharding_memory_and_comm()` on a new line.

**Sample Input:**

```
param_count = 7000000000
param_bytes = 2.0
optimizer_states_per_param = 3
world_size = 64
```

**Sample Output:**

```
{'no_shard_gb': 112.0, 'shard_grad_op_gb': 15.531, 'full_shard_gb': 1.75, 'no_shard_comm_gb': 14.0, 'full_shard_comm_gb': 21.0, 'memory_saving_gb': 110.25}
```

**Note:** The input handling is already in place — you only need to implement the function. This is
arithmetic on a configuration; activations are outside this budget. Both communication figures are
per training step and per device, and neither is divided by the device count — sharding changes how
much traffic a step generates, not how the same traffic is split up.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: sharding_memory_and_comm
RETURN TYPE: Dictionary

ARGUMENTS:
1. param_count                → Integer
2. param_bytes                → Float
3. optimizer_states_per_param → Integer
4. world_size                 → Integer
```

(`param_bytes` and `optimizer_states_per_param` follow from a trainer's precision/optimizer settings
and `world_size` from the launcher — all three required here and supplied in every test case. Six
values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
def sharding_memory_and_comm(param_count: int, param_bytes: float,
                             optimizer_states_per_param: int, world_size: int) -> dict:
    GB = 1e9
    params_gb = param_count * param_bytes / GB
    grads_gb = params_gb
    optimizer_gb = param_count * 4 * optimizer_states_per_param / GB

    no_shard = params_gb + grads_gb + optimizer_gb
    shard_grad_op = params_gb + (grads_gb + optimizer_gb) / world_size
    full_shard = no_shard / world_size

    return {
        "no_shard_gb": round(no_shard, 3),
        "shard_grad_op_gb": round(shard_grad_op, 3),
        "full_shard_gb": round(full_shard, 3),
        "no_shard_comm_gb": round(grads_gb, 3),
        "full_shard_comm_gb": round(1.5 * grads_gb, 3),
        "memory_saving_gb": round(no_shard - full_shard, 3),
    }
```

**Test Cases —** `in.txt`

```
3
7000000000
2.0
3
64
1500000000
4.0
2
8
13000000000
2.0
3
16
```

**Test Cases —** `out.txt`

```
{'no_shard_gb': 112.0, 'shard_grad_op_gb': 15.531, 'full_shard_gb': 1.75, 'no_shard_comm_gb': 14.0, 'full_shard_comm_gb': 21.0, 'memory_saving_gb': 110.25}
{'no_shard_gb': 24.0, 'shard_grad_op_gb': 8.25, 'full_shard_gb': 3.0, 'no_shard_comm_gb': 6.0, 'full_shard_comm_gb': 9.0, 'memory_saving_gb': 21.0}
{'no_shard_gb': 208.0, 'shard_grad_op_gb': 37.375, 'full_shard_gb': 13.0, 'no_shard_comm_gb': 26.0, 'full_shard_comm_gb': 39.0, 'memory_saving_gb': 195.0}
```

**Grader Notes:**

- **Environment:** Python standard library only, no imports. Three cases, milliseconds total
  (Python 3.14.6). Compare with tolerance `1e-3`. Dictionary key order is not significant.
- **Rounding was deliberately set to 3 decimals, not 4.** Case 1's `shard_grad_op_gb` is exactly
  `15.53125`, which sits precisely on a 4-decimal half-way point: `round(x, 4)` and `"%.4f"` both
  give `15.5312` (round-half-to-even on the exact binary value) while a `Decimal` ROUND_HALF_UP
  route gives `15.5313`. At 3 decimals the value is `15.531` under every rounding convention. Do not
  reinstate 4 decimals without re-checking this.
- **Padding cannot bite here, by construction.** This question splits in GB and never mentions the
  per-element padding that Q4 does, so exact division is the only reading of "split evenly". As a
  belt-and-braces measure, all three cases divide exactly anyway (`7e9 / 64 = 109,375,000`,
  `1.5e9 / 8 = 187,500,000`, `13e9 / 16 = 812,500,000`), so a solver who carried a round-up habit
  over from Q4 still lands on the shipped values. Keep that property if `world_size` is changed.
- **Scope trace** — against
  `modules/02-advanced-ai-agents/markdown/L8_Advanced_Fine_Tuning_Techniques.md`:
  - The three-component training state and its per-parameter byte coefficients — the same
    lines Q1 traces to: 36 (gradients at the parameters' precision), 42–44 and 52 (optimizer states,
    4 bytes each), 75 and 77 (`(2 + 2 + K) × Ψ`, `K = 12` for Adam).
  - `no_shard` per-GPU memory, and that adding GPUs does not reduce it — the DDP memory table at
    lines 295–300 (2Ψ / 2Ψ / 12Ψ / **16Ψ** = ~112 GB for 7B) and line 302.
  - The three placements, their names, and what each one shards — the sharding-strategy table at
    lines 383–387 verbatim: `NO_SHARD` → nothing → `(2 + 2 + K) × Ψ`; `SHARD_GRAD_OP` → "Optimizer
    states + Gradients" → `2Ψ + (2+K)×Ψ / N`; `FULL_SHARD` → "Everything" → `(2 + 2 + K) × Ψ / N`.
    The question's three key names are that table's own strategy names. Step 2 states *what* each
    splits (the table's "What's Sharded" column) and leaves the formula to be assembled.
  - `full_shard` reducing memory proportionally to the device count — lines 342 and 463, and line 389
    which works case 1 out exactly: "`FULL_SHARD` on 64 GPUs and a 7B model: ~112 GB / 64 = **~1.75
    GB per GPU**".
  - `no_shard` communication volume = the gradient tensor's size — line 308 ("one AllReduce per
    training step, transferring the full gradient tensor (same size as model parameters)"), line 310
    ("For a 7B model in FP16, that's ~14 GB of data per AllReduce" — case 1's
    `no_shard_comm_gb` exactly), and line 312 ("Communication cost: **2Ψ bytes per step**").
  - `full_shard` volume = 1.5x that — line 314 ("increases total communication by ~50% because it
    adds AllGather operations in the forward pass"), the comm-cost table at lines 469–473 (Total
    volume **2Ψ** vs **3Ψ**, "~50% more"; per-unit AllGather in forward, AllGather + ReduceScatter in
    backward), and line 476 ("FSDP trades **1.5× communication** for N× memory reduction").
  - The memory saving — the same table's memory row, lines 474 and 476.
  - **Disclosed, not taught:** the material quotes the 1.5x / 3Ψ figure as a result and never derives
    it from a per-collective bandwidth model, so step 3 states the 1.5x rather than expecting it to be
    reconstructed. This is required by the no-recalled-constants rule; it does make
    `"full_shard_comm_gb"` the easiest of the six keys, which is why the other five carry the
    question.
- Case 1 is the material's own 7B / 64-GPU example and reproduces three of its printed figures
  (112 GB, 1.75 GB, 14 GB). Case 2 changes both the precision (32-bit) and the state count (2) so no
  hardcoded coefficient survives. Case 3 is the 13B row of the same rule-of-thumb table (208 GB,
  lines 91–96) at a 16-device world size, with all six values mutually distinct so a
  copied-into-the-wrong-key bug shows up.
- Verified on the shipped cases — every wrong reading below was implemented and run:
  - **`shard_grad_op` shards the parameters too** (i.e. computes `full_shard` twice): 1.75 / 3.0 /
    13.0 in place of 15.531 / 8.25 / 37.375. Caught by all three. This is the "sharded the wrong
    components" failure and it is why the middle placement is in the question at all.
  - **`shard_grad_op` shards only the optimizer states** (leaving gradients replicated): 29.312 /
    13.5 / 61.75. Caught by all three.
  - **`shard_grad_op` shards only the gradients**: 98.219 / 18.75 / 183.625. Caught by all three.
  - **`full_shard` traffic taken as 2x the gradient tensor** (charging an all-reduce as two passes
    and then confusing it with the sharded figure): 28.0 / 12.0 / 52.0 against 21.0 / 9.0 / 39.0.
    Caught by all three.
  - **Either communication figure divided by `world_size`**: 0.328 / 1.125 / 2.438. Caught by all
    three — the Note pre-empts this reading because the material never divides its 2Ψ / 3Ψ volumes by
    the device count.
  - **Communication volume taken as the whole training state rather than the gradient tensor**:
    112.0 / 168.0 on case 1. Caught by all three.
  - **Saving reported as a factor instead of GB**: 64.0 / 8.0 / 16.0 (i.e. `world_size`). Caught by
    all three.
  - **Saving measured from `shard_grad_op` instead of `no_shard`**: 13.781 / 5.25 / 24.375. Caught by
    all three.
  - **Optimizer states in the training precision instead of FP32**: 70.0 / — / 130.0 for
    `no_shard_gb`. Caught by cases 1 and 3. **Not caught by case 2**, where `param_bytes = 4.0`
    coincides with the FP32 width — so a 2-byte case must stay in any shipped subset.
- **Overlap check:** Q1 of this file shares the per-parameter coefficients (`param_bytes` twice plus
  `4 × optimizer_states_per_param`) with this question's step 1, so a solver who has done one has
  step 1 of the other. The graded observables are otherwise disjoint — Q1 adds activations and
  returns a fit verdict against one device; this returns three sharded placements, two traffic
  volumes and a saving, and never touches activations. They are complementary rather than duplicated,
  but if a paper only has room for one memory question, this is the stronger of the two.
- All three cases executed against the reference solution (Python 3.14.6, standard library only).

---

## Q4: Flattening and Sharding One FSDP Unit

**Context:** Sharding a model is not a matter of handing each device a different layer. Inside one
FSDP unit every parameter tensor — weights and biases alike, whatever their shapes — is first
flattened and concatenated into a single one-dimensional buffer, and it is *that* buffer which is
cut into equal pieces, one per device. Equal pieces means the buffer has to divide evenly, so it is
padded up first, and a device can easily end up holding a slice that straddles what used to be two
different tensors, or nothing but padding. Peak memory follows from the same picture: a device holds
its own slice at all times, plus one whole unit for as long as it is being computed on.

**Problem Statement:**

Using `torch`, write a function `fsdp_shard_unit(unit_weight, unit_bias, world_size)`.

1. The unit holds two parameters: `unit_weight`, a 2-D tensor, and `unit_bias`, a 1-D array. Flatten
   each to one dimension and concatenate them **in that order** into a single buffer. Report how
   many elements it holds.
2. The buffer is split into `world_size` equal shards, so it must first be padded with zeros up to
   the next multiple of `world_size`. Report how many padding elements were added — zero when it
   already divides evenly — and how many elements each shard holds.
3. Report the contents of the shard held by rank 0 and the shard held by the last rank, each as a
   list of values rounded to 4 decimal places.
4. While a unit is being computed on, its device holds its own shard **and** the whole unflattened
   unit gathered from every rank. Report that peak as a number of elements: one shard plus the
   unpadded buffer.
5. Return a dictionary with exactly these six keys: `"flat_numel"`, `"pad_elements"`,
   `"shard_numel"` and `"peak_numel"` as integers, and `"rank0_shard"` and `"last_shard"` as lists
   of floats.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: unit_weight (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: unit_bias (numpy_1d)
    Line 1: N (array length)
    Line 2: N space-separated values
  Argument 3: world_size (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `fsdp_shard_unit()` on a new line.

**Sample Input:**

```
unit_weight = tensor([[ 1.,  2.,  3.,  4.],
                      [ 5.,  6.,  7.,  8.],
                      [ 9., 10., 11., 12.]])
unit_bias   = array([13., 14., 15.])
world_size  = 16
```

**Sample Output:**

```
{'flat_numel': 15, 'pad_elements': 1, 'shard_numel': 1, 'rank0_shard': [1.0], 'last_shard': [0.0], 'peak_numel': 16}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded and no distributed process group is started: this is the layout one unit would have, worked
out on a single device. The weight arrives as a `float32` tensor and the bias as a floating-point
array, so bring them into the same buffer before splitting. `world_size` may exceed the number of
elements in the unit, which is a real configuration and not an error.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: fsdp_shard_unit
RETURN TYPE: Dictionary

ARGUMENTS:
1. unit_weight → Torch 2D Tensor
2. unit_bias   → Numpy 1D Array
3. world_size  → Integer
```

(Six values must come back, so they fold into one `Dictionary`. The two parameters arrive as
different array types on purpose — the flattening step has to cope with both, which is exactly what
a real unit contains. `Torch 2D Tensor` is argument-only, which is no obstacle: only scalars and
short lists leave the function.)

**Reference Solution:**

```python
import numpy as np
import torch


def fsdp_shard_unit(unit_weight: torch.Tensor, unit_bias: np.ndarray,
                    world_size: int) -> dict:
    flat = torch.cat([unit_weight.reshape(-1),
                      torch.as_tensor(unit_bias, dtype=torch.float32)])

    pad = (-flat.numel()) % world_size
    padded = torch.cat([flat, torch.zeros(pad)])
    shards = padded.chunk(world_size)

    return {
        "flat_numel": int(flat.numel()),
        "pad_elements": int(pad),
        "shard_numel": int(shards[0].numel()),
        "rank0_shard": [round(float(v), 4) for v in shards[0]],
        "last_shard": [round(float(v), 4) for v in shards[-1]],
        "peak_numel": int(shards[0].numel() + flat.numel()),
    }
```

**Test Cases —** `in.txt`

```
3
3 4
1.0 2.0 3.0 4.0
5.0 6.0 7.0 8.0
9.0 10.0 11.0 12.0
3
13.0 14.0 15.0
16
4 5
-1.0 -0.895 -0.789 -0.684 -0.579
-0.474 -0.368 -0.263 -0.158 -0.053
0.053 0.158 0.263 0.368 0.474
0.579 0.684 0.789 0.895 1.0
4
0.5 -0.25 0.125 2.0
4
2 3
1.5 -2.5 3.5
0.5 -0.5 4.5
2
9.0 -9.0
3
```

**Test Cases —** `out.txt`

```
{'flat_numel': 15, 'pad_elements': 1, 'shard_numel': 1, 'rank0_shard': [1.0], 'last_shard': [0.0], 'peak_numel': 16}
{'flat_numel': 24, 'pad_elements': 0, 'shard_numel': 6, 'rank0_shard': [-1.0, -0.895, -0.789, -0.684, -0.579, -0.474], 'last_shard': [0.895, 1.0, 0.5, -0.25, 0.125, 2.0], 'peak_numel': 30}
{'flat_numel': 8, 'pad_elements': 1, 'shard_numel': 3, 'rank0_shard': [1.5, -2.5, 3.5], 'last_shard': [9.0, -9.0, 0.0], 'peak_numel': 11}
```

**Grader Notes:**

- **Environment:** `torch` 2.13.0 and `numpy` 2.5.2 on Python 3.12.13, CPU. Milliseconds per case.
  No process group, no NCCL, no GPU — the sharding layout is computed, not executed distributedly.
- **The tensor work produces the graded value.** `rank0_shard` and `last_shard` are slices of a real
  concatenated buffer; they cannot be written down from the shapes alone, and case 2's last shard
  proves it — it straddles the weight/bias boundary. This replaced an earlier version of this
  question that took a list of per-unit parameter *counts* and returned byte totals from
  `ceil(u / world_size)` arithmetic; that version never built a buffer and, in particular, sharded
  each tensor separately, which is not what FSDP does.
- **Scope trace** — against
  `modules/02-advanced-ai-agents/markdown/L8_Advanced_Fine_Tuning_Techniques.md`:
  - *Flattening the whole unit into one buffer* — **lines 373–379** (§2 Sharding), verbatim: "Within
    each FSDP unit, all parameters (weights, biases) are **flattened into a single 1D tensor** called
    `FlatParameter`. This FlatParameter is then evenly divided across all GPUs in the sharding
    group." Step 1 is that sentence.
  - *The worked example* — **line 379**: "a layer's weight matrix (12 values) and bias (3 values) are
    concatenated into a FlatParameter of 15 elements. With 16 GPUs (full sharding), each GPU stores
    only 1 element plus padding." **Case 1 is that example**, numerically: 12 + 3 = 15, world 16,
    one element per rank, one padding element. Its `last_shard` of `[0.0]` is the "plus padding".
  - *Padding as part of the split* — same line; step 2 states the rounding-up rule the word
    "padding" implies.
  - *Each rank holding only its local shard* — **line 379** ("Each GPU holds just its **local
    shard**") and **lines 401–404**, the gather → compute → free cycle.
  - *The peak* — **line 406**, verbatim: "The peak memory at any moment is the **sharded model**
    plus the **one fully-materialized FSDP unit** currently being computed — not the entire model."
    Step 4 is that sentence with "sharded model" read as this unit's own shard.
  - *What an FSDP unit is* — **lines 359–369**, including "smaller units mean less memory needed
    when the full parameters are temporarily materialized", which is why the peak is worth
    reporting.
  - **Disclosed, not taught:**
    - Concatenation **order** (weight then bias). The material says "weights, biases" and its
      example implies it, but never states it as a rule; step 1 pins it, because the shard contents
      depend on it.
    - Reporting the peak in **elements** rather than bytes. The material works in bytes throughout;
      elements keep this question free of a dtype argument, and Q1 and Q3 of this file already carry
      the bytes conversion.
    - `torch.chunk` as the splitting call. The material describes an even division and never names
      an API; any route producing equal contiguous slices is accepted.
- **Determinism.** Exact float32 values throughout — every test value is representable, so the
  rounding to 4 decimals is cosmetic. All three cases re-run byte-identical.
- Compare the four integers exactly and the two shard lists element-wise with tolerance `1e-4`.
  Dictionary key order is not significant.
- **What each case is for:**
  - **Case 1** — the material's own 12+3/16-GPU example. `world_size` **exceeds** the element count
    per rank in the sense that only 1 element lands on each, and the last rank holds pure padding.
  - **Case 2** — divides evenly (`pad_elements` 0), and its last shard `[0.895, 1.0, 0.5, -0.25,
    0.125, 2.0]` **spans the weight/bias boundary** — the two final weight values followed by all
    four bias values. This is the only case that catches a solution sharding each tensor separately,
    and the only one that catches a wrong concatenation order. **Case 2 must stay in any shipped
    subset.**
  - **Case 3** — 8 elements over 3 ranks: an uneven split needing 1 pad element, where the last
    shard is part real values and part padding.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Sharding each tensor independently** (the earlier version's model): case 2 gives
    `rank0_shard` `[-1.0, -0.895, -0.789, -0.684, -0.579]` (5 elements, the weight's own fifth) and
    a `shard_numel` of 5 rather than 6 — caught by case 2, and by case 3.
  - **Bias before weight**: case 2's `rank0_shard` becomes `[0.5, -0.25, 0.125, 2.0, -1.0, -0.895]`
    — caught by cases 2 and 3; case 1 also shifts (`[13.0]`).
  - **Padding to a multiple of the shard size computed as `ceil(n / world)` and then re-multiplying**:
    identical here on all three cases, so it is an **accepted** route — both reach the same padded
    length.
  - **Truncating instead of padding** (dropping the remainder): case 1 gives `shard_numel` 0 and an
    empty `rank0_shard`; case 3 gives `shard_numel` 2 and loses the final bias value — caught by
    cases 1 and 3.
  - **Peak taken as one shard plus the *padded* buffer**: 17 / 30 / 12 against 16 / 30 / 11 — caught
    by cases 1 and 3 but **not** case 2, which pads to zero; keep case 1 or 3.
  - **Peak taken as the whole model without the shard** (`flat_numel` alone): 15 / 24 / 8 — caught
    on all three.
- **Overlap check:** Q3 of this file compares replicated against sharded memory in bytes for a whole
  model and never builds a buffer; Q1 sizes a training run. This is the only question in the file
  that operates on real tensors, and the only one whose answer includes parameter values rather than
  counts. No shared graded value.
- All three cases executed against the reference solution.

---

