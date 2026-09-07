# Module 2, L9 — LLM Inference Optimization

Four coding questions across both halves of the material: **what a KV cache saves** (Q1) and
**what it costs against a memory allowance** (Q2), then **the output a single speculative step
commits** (Q3) and **the accounting of a speculative loop** (Q4).

Nothing here downloads a model. Q1, Q2 and Q4 are exact integer/rational arithmetic on a
generation schedule and need only the standard library. Q3 does real tensor work — the target
model's logits arrive as an argument and every graded value falls out of an `argmax` over the
correct slice of them — so it needs `torch` and nothing else. Q2 loads a tiny checkpoint and
measures a live `DynamicCache`. All four are fully deterministic;
every expected value in this file was produced by executing the reference solution.

---

## Q1: The Cost of Not Caching

**Context:** An autoregressive decoder emits one token at a time, and each step attends over every
token before it. The naive implementation re-runs the whole forward pass over the whole sequence at
every step, which recomputes key and value vectors that were already computed one step earlier —
those vectors never change once a token is fixed. Caching them collapses the total projection work
over a run from quadratic in the sequence length to linear, and the size of that gap is the number
you quote when someone asks why the cache is worth the memory it eats.

**Problem Statement:**

Write a function `kv_cache_recompute_saving(prompt_len, num_new_tokens, num_layers)`.

1. A run over a prompt of `prompt_len` tokens that emits `num_new_tokens` tokens consists of
   `num_new_tokens + 1` forward passes: one pass over the prompt, then one further pass for each
   token emitted.
2. Whenever a forward pass processes a token position, it computes one key vector and one value
   vector for that position at each of the model's `num_layers` layers.
3. A pass sees every position of the sequence as it stands when the pass runs: the first pass sees
   `prompt_len` positions, and the pass that runs once `i` tokens have already been emitted sees
   `prompt_len + i` positions.
4. **With a cache**, a position's key and value vectors are computed only by the first pass that
   sees that position; every later pass reads them back instead of recomputing them. Count the key
   and value vectors computed over the whole run in this mode.
5. **Without a cache**, every pass recomputes the key and value vectors for every position it sees.
   Count the key and value vectors computed over the whole run in this mode.
6. Return a dictionary with keys `"with_cache"` (integer), `"without_cache"` (integer) and
   `"ratio"` (float) — the last being `without_cache / with_cache` rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: prompt_len (integer)
    Single line: one integer
  Argument 2: num_new_tokens (integer)
    Single line: one integer
  Argument 3: num_layers (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `kv_cache_recompute_saving()` on a new line.

**Sample Input:**

```
prompt_len = 9
num_new_tokens = 50
num_layers = 12
```

**Sample Output:**

```
{'with_cache': 1416, 'without_cache': 41616, 'ratio': 29.3898}
```

**Note:** The input handling is already in place — you only need to implement the function. This is
arithmetic on a generation schedule; nothing is loaded and no tensor work is involved. Keep both
counts as exact integers — they grow fast, which is the whole point of the comparison.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: kv_cache_recompute_saving
RETURN TYPE: Dictionary

ARGUMENTS:
1. prompt_len      → Integer
2. num_new_tokens  → Integer
3. num_layers      → Integer
```

(Three values must come back — two counts and their ratio — so they fold into one `Dictionary`.)

**Reference Solution:**

```python
def kv_cache_recompute_saving(prompt_len: int, num_new_tokens: int, num_layers: int) -> dict:
    with_cache_positions = prompt_len + num_new_tokens
    without_cache_positions = sum(prompt_len + i for i in range(num_new_tokens + 1))

    with_cache = 2 * num_layers * with_cache_positions
    without_cache = 2 * num_layers * without_cache_positions

    return {
        "with_cache": with_cache,
        "without_cache": without_cache,
        "ratio": round(without_cache / with_cache, 4),
    }
```

**Test Cases —** `in.txt`

```
2
9
50
12
1024
256
32
```

**Test Cases —** `out.txt`

```
{'with_cache': 1416, 'without_cache': 41616, 'ratio': 29.3898}
{'with_cache': 81920, 'without_cache': 18948096, 'ratio': 231.3}
```

**Scope trace** (`modules/02-advanced-ai-agents/markdown/L9_LLM_Inference_Optimization.md`):

- Redundant key/value recomputation without a cache — lines 47–49: "at every step, re-run the full
  forward pass over the entire sequence so far… for every token in the prompt, the Key and Value
  projections were already computed at the previous step. Recomputing them is a pure tax on
  latency."
- Each token's K and V stored "at every layer" → the `2 × num_layers` factor per position —
  line 49, and the per-token formula `2 (K and V) × L × H × d × b` at lines 162–166.
- The one-prompt-pass-then-one-pass-per-token schedule of steps 1 and 3 — lines 154–156
  ("Stage 1 — Prefill… processes the entire prompt in a single forward pass"; "Stage 2 — Decode…
  To produce the first new token, the model only runs a forward pass over the last token… To
  produce the second new token, only that token is processed").
- The quadratic-versus-linear framing the two counts quantify — line 49 ("The cost per generated
  token drops from O(seq_len) attention work to O(1)") and line 657 ("turns generation from O(n²)
  into O(n)").
- Constants: case 1's `num_new_tokens = 50` is `max_new_tokens=50` at line 127 and its
  `num_layers = 12` is gpt2's layer count at line 258; `prompt_len = 9` is the scale of the short
  prompt at line 110. Case 2's `1024 / 256 / 32` is a generic long-context configuration. All three
  arrive as arguments in every case — nothing is recalled.
- **Disclosed, not taught:** the material never prints these counts or their ratio — it states the
  asymptotics in prose. Steps 1–5 therefore spell out the pass schedule and the counting rule in
  full, so no convention has to be guessed.

**Grader Notes:**

- **Environment:** Python 3.12, standard library only. Runs instantly.
- Compare `"with_cache"` and `"without_cache"` exactly (they are integers) and `"ratio"` with
  tolerance `1e-3`. Dictionary key order is not significant.
- The ratio is `((N+1)·P + N(N+1)/2) / (P + N)`, an exact rational, so `round(..., 4)` is
  reproducible on any machine. Case 2's ratio is exactly `231.3` and prints with one decimal —
  that is Python's float repr, not a truncated value.
- **The `2 × num_layers` factor cancels out of the ratio.** Both counts scale with it, so a
  solution that drops it still gets `"ratio"` right and both counts wrong. That is why the counts
  are graded and why they are graded as vectors rather than positions.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Counting K and V once instead of twice per position:** `708 / 20808` and `40960 / 9474048`
    against the correct `1416 / 41616` and `81920 / 18948096` — caught on both cases, ratio
    unchanged.
  - **Dropping the layer factor:** `118 / 3468` and `2560 / 592128` — caught on both, ratio
    unchanged.
  - **Off-by-one in the schedule** (`num_new_tokens` passes instead of `num_new_tokens + 1`, i.e.
    the last emitted token never gets its own K/V): `1392 / 40200`, `ratio 28.8793` and
    `81856 / 18866176`, `ratio 230.4801` — caught on both, and the ratio moves too.
  - **Ratio inverted** (`with / without`): `0.034` and `0.0043` — caught on both.
  - **Assuming every pass sees the final sequence length** (`(N+1)·(P+N)` instead of the sum):
    `without_cache` becomes `72216` / `21053440` with ratios `51.0` / `257.0` — caught on both, and
    the giveaway is that the ratio lands on `num_new_tokens + 1` exactly.
  - **Counting only the prompt as cached** (forgetting that generated tokens also add K/V):
    `216 / 41616`, `ratio 192.6667` and `65536 / 18948096`, `ratio 289.125` — caught on both.
- The two cases differ in shape, not just in size: case 1 is prompt-light and generation-heavy
  (`N ≫ P`), case 2 is prompt-heavy (`P = 4 × N`). **Swapping `prompt_len` and `num_new_tokens`
  leaves `"with_cache"` untouched** — it is `P + N`, symmetric in the two — but was run and breaks
  the other two keys on both cases: `without_cache` becomes `13080` (`ratio 9.2373`) on case 1 and
  `50380800` (`ratio 615.0`) on case 2. Grade all three keys, not just the cached count.
- **Overlap check:** the topic-organized bank's `kv_cache_memory`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q3)
  sizes the cache in bytes for one sequence length. This question never converts to bytes and never
  takes a head count or a dtype width — it counts vector computations and the redundancy factor
  between the two decoding modes. No shared graded value.
- Both cases executed against the reference solution (Python 3.12).

---

## Q2: Measuring What the KV Cache Actually Costs

**Context:** The reason a decoder can emit a token without re-reading its whole context is that the
key and value vectors for everything already seen are kept in a per-request buffer. That buffer is
the price: it grows by a fixed amount for every token, at every layer, and on a long conversation it
is what runs the GPU out of memory rather than the weights. The per-token cost is predictable from
the model's shape — layer count, key/value head count, head width, and the size of the dtype — but a
prediction is not a measurement. The buffer is a real object you can inspect after a forward pass,
and reading its size directly is how you find out whether your arithmetic matched your model.

**Problem Statement:**

Using the `transformers` and `torch` libraries, write a function
`kv_cache_measured_growth(model_id, prompt_ids, num_new_tokens)`.

1. Load the causal language model `model_id` in 32-bit floating point and put it in evaluation mode.
2. Run one forward pass over the whole of `prompt_ids` with caching enabled — the prefill. Keep the
   cache it returns.
3. Then take `num_new_tokens` decode steps. Each step feeds **only the single most recently produced
   token**, together with the cache from the step before, and takes the next token to be the highest
   scoring entry of the last position's output scores.
4. From the cache as it stands at the end, report: how many layers it holds; the number of key/value
   heads and the width of one head, both read off a stored key tensor; and how many token positions
   are cached.
5. Report the cache's size in bytes twice — as it stood right after the prefill, and as it stands at
   the end. Size a cache by summing, over every layer, the bytes occupied by its stored keys and its
   stored values. Report also the final size divided by the number of cached positions, rounded to 4
   decimal places.
6. Return a dictionary with exactly these seven keys: `"num_layers"`, `"kv_heads"`, `"head_dim"`,
   `"cached_tokens"`, `"bytes_after_prefill"` and `"bytes_after_decode"` as integers, and
   `"bytes_per_token"` as a float.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: model_id (string)
    Single line: a string
  Argument 2: prompt_ids (list_int)
    Line 1: N (list length)
    Line 2: N space-separated integers
  Argument 3: num_new_tokens (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `kv_cache_measured_growth()` on a new line.

**Sample Input:**

```
model_id = "trl-internal-testing/tiny-Qwen2ForCausalLM-2.5"
prompt_ids = [11, 5, 2, 9, 14]
num_new_tokens = 3
```

**Sample Output:**

```
{'num_layers': 2, 'kv_heads': 2, 'head_dim': 2, 'cached_tokens': 8, 'bytes_after_prefill': 320, 'bytes_after_decode': 512, 'bytes_per_token': 64.0}
```

**Note:** The input handling is already in place — you only need to implement the function. The
models are tiny test checkpoints, so loading one inside the function is cheap and no GPU is
involved. Run the passes under no-gradient mode: gradients are never needed here and they cost
memory. A stored key tensor carries four axes — batch, heads, positions and head width — and which
is which is worth confirming on the prefill before you trust it after eight decode steps. Feeding
the whole sequence again at each step instead of the newest token would produce the same text and
defeat the entire point of the exercise.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: kv_cache_measured_growth
RETURN TYPE: Dictionary

ARGUMENTS:
1. model_id       → String
2. prompt_ids     → List of Ints
3. num_new_tokens → Integer
```

(Seven values must come back, so they fold into one `Dictionary`. Token ids stay a `List of Ints`
rather than a tensor argument — the tensor parser produces `float32`, which cannot index an
embedding table.)

**Reference Solution:**

```python
import torch
from transformers import AutoModelForCausalLM


def kv_cache_measured_growth(model_id: str, prompt_ids: list,
                             num_new_tokens: int) -> dict:
    model = AutoModelForCausalLM.from_pretrained(model_id, dtype=torch.float32)
    model.eval()

    def cache_bytes(cache):
        return sum(layer.keys.numel() * layer.keys.element_size()
                   + layer.values.numel() * layer.values.element_size()
                   for layer in cache.layers)

    with torch.no_grad():
        out = model(torch.tensor([prompt_ids]), use_cache=True)
        after_prefill = cache_bytes(out.past_key_values)

        for _ in range(num_new_tokens):
            next_id = int(out.logits[0, -1].argmax())
            out = model(torch.tensor([[next_id]]),
                        past_key_values=out.past_key_values, use_cache=True)

    cache = out.past_key_values
    keys = cache.layers[0].keys
    after_decode = cache_bytes(cache)
    cached_tokens = int(keys.shape[2])

    return {
        "num_layers": len(cache.layers),
        "kv_heads": int(keys.shape[1]),
        "head_dim": int(keys.shape[3]),
        "cached_tokens": cached_tokens,
        "bytes_after_prefill": after_prefill,
        "bytes_after_decode": after_decode,
        "bytes_per_token": round(after_decode / cached_tokens, 4),
    }
```

**Test Cases —** `in.txt`

```
3
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
5
11 5 2 9 14
3
trl-internal-testing/small-Qwen2ForCausalLM-2.5
2
4 7
2
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
9
1 2 3 4 5 6 7 8 9
1
```

**Test Cases —** `out.txt`

```
{'num_layers': 2, 'kv_heads': 2, 'head_dim': 2, 'cached_tokens': 8, 'bytes_after_prefill': 320, 'bytes_after_decode': 512, 'bytes_per_token': 64.0}
{'num_layers': 2, 'kv_heads': 2, 'head_dim': 32, 'cached_tokens': 4, 'bytes_after_prefill': 2048, 'bytes_after_decode': 4096, 'bytes_per_token': 1024.0}
{'num_layers': 2, 'kv_heads': 2, 'head_dim': 2, 'cached_tokens': 10, 'bytes_after_prefill': 576, 'bytes_after_decode': 640, 'bytes_per_token': 64.0}
```

**Grader Notes:**

- **Environment:** needs `transformers` 5.15.0, `torch` 2.13.0 and the HF Hub. One model load per
  case, a few hundred KB each; ~1.5 s per case on CPU. No GPU.
- **The library produces the graded value.** Every number is read off a real `DynamicCache` after
  real forward passes: the layer count, the head geometry and the byte totals all come from the
  checkpoint's own config and the cache's own tensors. This replaced an earlier version that
  computed `2 × L × H × d × b` per token from six supplied integers — the arithmetic the material
  states — and never ran a model. That formula is now the *check* rather than the answer: the
  measured `bytes_per_token` is 64.0 on the tiny checkpoint, which is exactly
  `2 × 2 layers × 2 heads × 2 wide × 4 bytes`, and 1024.0 on the wider one, exactly
  `2 × 2 × 2 × 32 × 4`.
- **Scope trace** (`modules/02-advanced-ai-agents/markdown/L9_LLM_Inference_Optimization.md`):
  - *Why the cache exists and what it stores* — **line 49**: "after each forward pass, **store**
    the K and V tensors for every token at every layer in a per-request buffer (the 'KV cache')",
    and the decode step that follows, which processes only the newest token.
  - *The prefill / decode split* — **lines 154 and 156**: "**Stage 1 — Prefill (the first pass).** The
    model processes the entire prompt in a single forward pass… writes them into the cache
    (`past_key_values`)" and "**Stage 2 — Decode**… the model only runs a forward pass over the
    *last* token". Steps 2 and 3 are those two paragraphs.
  - *The per-token cost formula* — **lines 162–165**, verbatim:
    `2 (K and V) × L × H × d × b   bytes per token`, with `L` layers, `H` KV heads, head dim `d` and
    dtype size `b`. Step 4's four quantities are that formula's four factors, and step 5 measures
    what it predicts.
  - *Measuring rather than predicting* — **lines 167–253**, the material's own memory-growth
    experiment: it generates runs of increasing length and records the peak after each, then reads
    the slope as the per-token cost ("Approx memory growth: 53.7 KB / token", line 253) and compares
    it against the theoretical figure at **line 258** ("for `gpt2`… the theoretical cost is
    about 36 KB per token — what you measure should be in that ballpark"). This question is that
    comparison made exact: because the cache is inspected directly rather than via peak allocator
    stats, the measurement matches the formula exactly instead of approximately.
  - *`use_cache=True` and `past_key_values` as the API* — **lines 120–130** and **line 154**.
  - *Greedy next-token selection* — **line 130** (`do_sample=False`), the material's own decoding
    mode throughout both demos.
  - **Disclosed, not taught:**
    - Walking the cache object to sum bytes. The material reads GPU allocator statistics
      (`torch.cuda.max_memory_allocated`, line 175) instead, which is unavailable on a CPU grader and
      would include scratch memory. Step 5 defines the sum in words.
    - `model.eval()` and `torch.no_grad()`. The material uses `with torch.no_grad()` (line 123) but
      calls `.eval()` at line 83 and on the speculative-decoding models at lines 310 and 314; neither affects the
      graded values here, and the Note asks for no-grad on cost grounds rather than correctness.
    - Constructing the decode loop by hand. The material calls `model.generate()`, which hides the
      loop; step 3 spells it out, because the point is to watch the cache between steps.
- **Determinism.** Shapes and byte counts do not depend on *which* tokens are produced, only on how
  many — so even the greedy argmax is incidental to the answer. Verified by running every case twice
  in separate processes: byte-identical. The `float32` load is pinned so `element_size()` is 4
  regardless of the checkpoint's stored dtype.
- **Version note.** The cache is a `DynamicCache`, iterated here as `cache.layers[i].keys` /
  `.values` — the `transformers` 5.x layout. On 4.x the same tensors are reached as
  `cache.key_cache[i]` / `cache.value_cache[i]`, and older code indexes the object as a tuple of
  pairs. Pin `transformers` 5.15.0, and accept any route that reaches the same tensors; the graded
  quantity is the byte total, not the access path.
- Compare all six integers exactly and `"bytes_per_token"` with tolerance `1e-4`. Dictionary key
  order is not significant.
- **What each case is for:**
  - **Case 1** — a 5-token prompt and 3 decode steps on the tiny checkpoint: 8 cached positions,
    with the prefill accounting for 320 of the final 512 bytes.
  - **Case 2** — the **wider** checkpoint, whose head width is 32 rather than 2, so `head_dim` and
    `bytes_per_token` both change (1024.0 against 64.0). This is the only case that catches a
    solution hardcoding the geometry, or reading `head_dim` off the wrong axis — on the tiny
    checkpoint the head count and head width are both 2 and the two axes are indistinguishable.
    **Case 2 must stay in any shipped subset.**
  - **Case 3** — a long prompt and a single decode step, so the prefill dominates (576 of 640
    bytes). It catches a solution that reports the prefill and final sizes the wrong way round,
    which cases 1 and 2 also catch, and one that assumes prompt and generation contribute equally.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Re-feeding the whole sequence each step** instead of the newest token: `cached_tokens` becomes
    11 / 5 / 19 on the three cases, since each pass appends its full input to the cache — caught on
    all three, and this is the reading the question exists to catch.
  - **Not passing `past_key_values` back in**: the cache restarts every step, giving
    `cached_tokens` 1 and `bytes_after_decode` 64 / 1024 / 64 — caught on all three.
  - **Reading `head_dim` from axis 1 and `kv_heads` from axis 3**: identical on cases 1 and 3
    (both are 2), and on **case 2** returns `kv_heads` 32, `head_dim` 2 — caught by case 2 only.
  - **Counting keys only, not keys and values**: exactly half of every byte figure — caught on all
    three.
  - **Loading in the checkpoint's stored dtype**: halves every byte figure on a 16-bit checkpoint;
    the `float32` requirement in step 1 exists to make this deterministic across checkpoints.
  - **`cached_tokens` taken as `len(prompt_ids) + num_new_tokens`**: correct here by construction —
    an accepted route for that one key, but it produces no cache and therefore cannot supply the
    other six.
- **Overlap check:** Q1 of this file counts key/value vector *computations* with and without a cache
  and never converts to bytes or loads a model; Q3 and Q4 are speculative decoding. The
  topic-organized bank's `kv_cache_memory`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q3) sizes
  a cache in bytes from supplied integers under a head-sharing scheme — it is the arithmetic version
  of what this question now measures, so the two are close in *subject* and opposite in *method*.
  Ship both only if you want the formula and the measurement tested separately.
- All three cases executed against the reference solution.

---

## Q3: Committing the Output of a Speculative Step

**Context:** In speculative decoding a small draft model proposes several tokens and a large target
model checks them all in a single forward pass. Because a transformer scores every position of its
input in parallel, that one pass yields the target's own preferred next token at each drafted
position, plus one extra prediction for the position beyond the last draft. What the step commits is
not the draft: it is the run of drafted tokens the target agrees with, cut off at the first
disagreement, plus exactly one token that the target itself supplies — a correction where the
disagreement happened, or a free bonus token when there was none. Getting that construction right is
what makes speculative decoding lossless; getting the position bookkeeping wrong silently corrupts
the output.

**Problem Statement:**

Using `torch`, write a function `speculative_step_sequence(context_ids, draft_ids, target_logits)`.

1. `context_ids` is the sequence generated so far and `draft_ids` is the run of `k` token ids the
   draft model proposed to continue it.
2. `target_logits` is the target model's output for one forward pass over `context_ids` followed by
   `draft_ids`: one row per position of that concatenated input, in the same order, each row holding
   one score per vocabulary entry. A row is the model's prediction for the position **immediately
   after** the position that row belongs to.
3. Read off the target's preferred token — the highest-scoring vocabulary entry — at each of the `k`
   drafted positions, and at the one position beyond the last drafted token.
4. Walk the drafted tokens left to right and accept a drafted token when its id equals the target's
   preferred token at that same position. Stop at the first drafted token that does not match;
   nothing after that point is accepted, even if it would have matched.
5. The tokens this step commits are the accepted drafted tokens followed by exactly one token taken
   from the target: its preferred token at the position where the walk stopped. When a mismatch
   stopped the walk that token is the correction replacing the rejected draft; when every drafted
   token was accepted it is the bonus token at the position beyond the drafts.
6. Return a dictionary with keys:
   - `"num_accepted"` (integer) — how many drafted tokens were accepted;
   - `"first_reject_index"` (integer) — the index within `draft_ids` of the first drafted token that
     was not accepted, or `-1` when every drafted token was accepted;
   - `"sequence"` (list of integers) — `context_ids` followed by the tokens this step commits.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: context_ids (list_int)
    Line 1: N (list length)
    Line 2: N space-separated integers
  Argument 2: draft_ids (list_int)
    Line 1: N (list length)
    Line 2: N space-separated integers
  Argument 3: target_logits (torch_tensor_2d)
    Line 1: R C
    Next R lines: C space-separated values each
```

**Output Format:**

For each test case, print the result of `speculative_step_sequence()` on a new line.

**Sample Input:**

```
context_ids = [5, 2, 0]
draft_ids = [4, 7, 1]
target_logits = torch.tensor([[0.1, 2.4, 0.3, 0.2, 1.1, 0.7, 0.5, 0.9],
                              [0.2, 0.4, 1.0, 0.1, 0.9, 2.7, 0.3, 0.6],
                              [0.5, 0.1, 0.8, 0.4, 3.1, 0.2, 0.9, 0.7],
                              [0.3, 0.6, 0.2, 1.4, 0.5, 0.1, 0.8, 2.9],
                              [0.4, 0.2, 0.7, 2.2, 0.1, 1.3, 0.5, 0.6],
                              [0.6, 0.3, 0.9, 0.5, 0.4, 1.2, 2.6, 0.1]])
```

**Sample Output:**

```
{'num_accepted': 2, 'first_reject_index': 2, 'sequence': [5, 2, 0, 4, 7, 3]}
```

**Note:** The input handling is already in place — you only need to implement the function. No model
is loaded: the target's scores arrive as the tensor argument. Take the preferred tokens with `torch`
over the vocabulary dimension and convert only the finished ids to Python integers for the returned
dictionary. Row indices and token positions do not line up one-to-one — the row that predicts a
position sits before it — so work out which rows you need before slicing.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: speculative_step_sequence
RETURN TYPE: Dictionary

ARGUMENTS:
1. context_ids    → List of Ints
2. draft_ids      → List of Ints
3. target_logits  → Torch 2D Tensor   (dtype float32)
```

(Three values must come back — two counters and the committed sequence — so they fold into one
`Dictionary`. `Torch 2D Tensor` is argument-only, which is fine: the tensor is an input and the
result is a dictionary of Python integers. The logits arrive as a plain 2-D matrix with no batch
dimension, so the descriptor needs no 3-D type.)

**Reference Solution:**

```python
import torch


def speculative_step_sequence(context_ids: list, draft_ids: list,
                              target_logits: torch.Tensor) -> dict:
    k = len(draft_ids)
    ctx_len = len(context_ids)

    start = ctx_len - 1
    end = ctx_len + k
    target_preferred = torch.argmax(target_logits[start:end, :], dim=-1)

    num_accepted = 0
    reject_index = -1
    for i in range(k):
        if int(target_preferred[i]) == draft_ids[i]:
            num_accepted += 1
        else:
            reject_index = i
            break

    committed = draft_ids[:num_accepted] + [int(target_preferred[num_accepted])]

    return {
        "num_accepted": num_accepted,
        "first_reject_index": reject_index,
        "sequence": list(context_ids) + committed,
    }
```

**Test Cases —** `in.txt`

```
3
4
3 11 5 2
5
7 1 9 4 12
9 24
0.2619 0.7989 2.6211 0.3283 0.5392 0.9369 -1.0767 0.5595 1.1494 1.9649 -1.5294 -0.483 -1.5466 2.0482 1.4672 -1.7906 2.911 2.8238 1.2696 1.0778 -1.2125 2.916 0.6419 -1.7022
2.9933 -0.7903 -1.8496 0.3197 0.2027 2.2121 0.5956 1.2015 0.4989 1.3122 0.2866 -0.6092 2.9883 2.9785 2.2011 1.539 -0.4236 -0.8517 -0.5548 -1.6489 1.8314 0.002 2.2329 -0.0674
2.7902 2.2365 -1.9973 -0.9514 2.5514 0.3499 2.9018 -0.0129 -1.6348 1.1473 1.8926 -0.6511 -1.5643 -0.3371 2.8204 1.7902 -1.41 -0.7681 -1.4948 -1.7005 2.9068 -1.1116 0.7965 0.2371
-1.0466 1.6595 -1.3452 1.2186 -1.4175 0.1038 -0.9357 2.9515 2.8546 2.0171 -0.4793 2.4243 -0.9464 -0.0286 2.2719 1.2092 -1.4983 2.9465 -0.9338 -0.7086 1.8634 -0.3552 -0.5184 -1.633
-1.5494 2.8007 -0.7849 1.0064 -0.1415 0.266 2.7957 0.4186 0.8729 2.3326 -1.0859 -1.2293 2.5421 2.089 -0.7525 -1.051 1.6971 2.702 -1.0171 2.7507 2.4109 1.0177 0.1073 -1.4808
-1.8065 2.8134 -0.808 1.5229 -0.7151 2.1186 0.9823 -0.5328 -1.1228 2.8184 -1.6561 -0.858 0.7968 2.262 1.0715 -0.5989 2.5868 -0.9801 -1.9171 -0.654 0.2285 -1.6977 -1.1187 -0.1561
0.8608 -1.3421 -0.1893 2.4547 3.0018 1.2847 1.4561 0.9222 -1.2983 -1.8246 -1.9105 2.5511 1.5049 2.8139 -1.8937 1.1809 0.4112 1.6525 -0.4055 2.9968 -1.6237 0.7305 1.685 2.501
1.6854 1.5185 1.9663 2.575 -0.2408 1.4257 2.9716 2.3555 0.0858 1.9527 2.3174 0.864 1.1248 -0.0883 0.9134 1.0443 -1.599 1.197 2.9666 2.399 1.641 -0.0578 1.6752 0.9048
0.2026 2.1919 -1.5811 1.7511 -1.8511 1.0064 0.4048 -0.8489 1.4917 0.4863 1.0725 2.6023 -0.7208 2.6073 -0.4948 1.3907 -0.9871 -1.152 2.5286 1.3 0.2097 2.4586 -0.3652 1.3295
3
8 0 15
3
2 6 6
6 24
2.791 -1.2982 -1.8819 2.9932 -1.0787 -1.397 1.2571 -0.2718 2.4478 -0.8413 2.7974 -0.4027 1.0057 2.6604 1.4263 2.6192 1.5406 2.9982 2.4068 0.9478 -0.4466 -1.0493 2.249 0.9141
2.6899 1.8698 2.806 0.8316 2.811 1.0616 -0.7079 2.7836 -0.4376 1.9055 2.7732 1.2544 -1.2889 2.1261 1.3375 -1.0749 -1.7544 0.6591 -1.8387 2.6254 0.5314 0.5866 0.0472 1.305
2.5823 -0.4635 2.9874 0.913 -0.5134 0.9782 0.7156 0.1674 1.3662 0.6412 -1.5595 2.9824 -0.2215 0.1588 0.014 2.6475 2.7608 0.56 0.0033 -1.5172 2.4775 -1.143 0.7331 -0.2543
-0.3586 -0.214 -1.0437 -1.8151 0.6773 1.9795 2.9614 -0.9925 1.4683 -1.7395 0.0537 2.1405 2.6051 0.3029 2.2327 0.4927 0.6198 0.9227 2.9564 1.7184 0.3652 1.6363 1.2163 -0.2311
1.9209 2.099 1.042 2.7136 -1.9091 0.5 2.8407 -0.2971 -1.1431 1.4604 0.172 -0.655 -1.7907 2.8357 -0.2386 -1.4095 -0.9183 -0.7253 2.331 -1.0967 -0.6182 -1.5132 0.3498 -0.9614
-0.2793 1.6745 2.6253 2.1708 -1.8086 -0.1112 2.2447 -1.8351 -0.984 0.45 2.6303 1.7514 1.5907 0.3223 -0.7549 -0.8463 -0.6686 -1.674 1.3288 -1.211 2.447 1.2298 -1.7161 0.4938
5
1 4 4 9 13
4
5 5 5 5
9 24
0.8516 1.1612 2.085 -0.6135 1.2593 2.4541 2.5441 2.836 1.2586 1.0856 0.517 2.831 0.6413 0.2263 2.7178 1.1781 -0.4935 -0.4537 0.4805 -1.737 1.0379 1.6793 0.1307 2.2329
2.6399 0.778 2.9051 -1.4137 -1.7199 2.9001 -0.5778 -0.9332 2.4833 1.7491 -1.3841 -0.3916 -0.7866 -0.6365 -1.9681 0.6234 -0.4783 -0.029 -1.0728 -1.4496 -1.8354 2.3638 1.7368 0.7983
-1.3808 -1.2553 -1.4017 -0.4172 -1.712 -0.623 -0.9855 -1.0358 1.2686 0.289 0.3674 -0.2097 0.6951 1.9258 -0.46 -1.6489 0.4059 -0.1042 1.9025 2.3686 2.3636 -1.9259 0.7112 0.218
-0.4233 2.4445 1.5105 -1.1839 0.4747 1.0613 -1.8325 -1.5627 1.0087 1.6475 0.3134 0.1103 0.5347 -0.6971 2.3825 2.8088 0.4095 -1.8973 -0.0145 2.0152 -0.3752 -1.4722 2.8138 1.5584
1.1101 -0.5692 1.1179 1.8033 2.8305 2.1565 0.1698 2.0478 2.6271 2.3447 1.7524 0.9332 2.8355 2.2513 1.1253 1.6061 -0.8604 -1.5391 -0.6482 0.9169 0.865 -1.0069 -1.057 2.7505
-1.6425 2.632 1.8602 0.8683 2.9779 2.9829 -1.9661 2.6955 0.0671 2.583 2.0691 -1.3095 -1.8016 -1.8959 1.9032 1.9572 -0.8599 -1.4363 -0.1675 1.9967 1.7038 2.3354 2.8402 1.7735
2.178 -1.9181 -1.9677 2.3125 1.0936 2.3175 -1.359 -0.3377 -0.3043 0.4786 0.2493 -0.989 -1.5897 -0.9845 -1.3588 -1.4988 0.0726 -1.3493 2.0001 0.7238 0.3004 1.1959 -0.8256 -1.8829
-1.6068 -0.3141 -0.1938 -0.7371 -0.4678 2.8967 -1.9568 0.2452 -0.0851 -0.5898 1.6242 -0.8777 -1.7886 -1.2026 2.8917 -0.2712 -1.4147 2.8543 1.225 2.7822 -0.3431 2.0498 -1.7931 -0.8123
1.9733 0.5799 1.947 -0.0707 2.3818 2.7593 1.1175 -1.0571 -1.0029 2.4156 0.1502 2.0628 -0.5802 1.6512 2.5373 1.1344 -0.8271 1.3413 2.7543 2.0059 0.2198 -0.0028 -1.507 1.8425
```

**Test Cases —** `out.txt`

```
{'num_accepted': 4, 'first_reject_index': 4, 'sequence': [3, 11, 5, 2, 7, 1, 9, 4, 6]}
{'num_accepted': 3, 'first_reject_index': -1, 'sequence': [8, 0, 15, 2, 6, 6, 10]}
{'num_accepted': 0, 'first_reject_index': 0, 'sequence': [1, 4, 4, 9, 13, 12]}
```

**Scope trace** (`modules/02-advanced-ai-agents/markdown/L9_LLM_Inference_Optimization.md`):

- One target pass over `context + k draft tokens` yielding a prediction at each drafted position
  **plus one for position `k+1`** — line 273, and the parallel-scoring justification at lines
  388–390.
- The row-to-position alignment of step 2 — line 399, verbatim: "logits at index t-1 predict the
  token at index t", with the slice bounds and `torch.argmax(..., dim=-1)` at lines 402–404.
- Greedy acceptance and stopping at the first mismatch — line 288 ("accept iff the draft's argmax
  matches the target's argmax") and the walk at lines 471–484.
- The committed output as "[all matched draft tokens] + [target's correction at the mismatch
  point]", and the all-accepted case yielding the bonus token for `K+1` tokens from one pass —
  lines 498–515, with the `"sequence"` key mirroring `new_context_ids` at line 515.
- `k = 5` in case 1 — `K_DRAFT_TOKENS = 5` at line 299; case 1's "4 of 5 accepted, then a
  correction" pattern is the outcome at lines 488–495. Case 2 (`k = 3`, all accepted) and case 3
  (`k = 4`, rejected at the first position) are the two other branches lines 500 and 507–513
  describe.
- **Disclosed, not taught:**
  - The extra `k+1`-th preferred token is stated in prose (lines 273 and 500) but the demonstration
    code slices only `k` of them (`end = verification_input_ids.shape[1] - 1`, line 403) and then
    clamps the index (line 574). Step 3 therefore states plainly that the extra position is needed,
    and step 5 states what it is for.
  - `"first_reject_index"` as a reported value appears nowhere in the material; step 6 defines it
    and fixes the `-1` sentinel.
  - Converting tensor ids to Python integers is portal plumbing (the return type is a
    `Dictionary`), which is why the Note mentions it rather than leaving the learner to guess.

**Grader Notes:**

- **Environment:** Python 3.12 with `torch` 2.13.0 (CPU). No model download, no network. All three
  cases run in well under a second.
- **Declare the tensor argument as `float32`.** The graded values are argmax indices, so the dtype
  cannot change them here: in every graded row the winning score sits exactly `0.005` above the
  runner-up over 24 vocabulary entries, which is four orders of magnitude above float32's resolution
  at that magnitude. Re-running the reference with the tensor cast to `float64` reproduced all three
  cases byte-for-byte.
- **The margins are deliberately narrow.** A `0.005` gap over 24 columns per row, across 4–6 graded
  rows per case, means the answer cannot be read off `in.txt` by eye — the argmax has to be
  computed. It is still far too wide for any floating-point ambiguity.
- Compare `"num_accepted"`, `"first_reject_index"` and every element of `"sequence"` exactly — all
  integers. Dictionary key order is not significant. `"sequence"` must be a list of Python ints, not
  a tensor.
- **What each case is for:**
  - **Case 1** — partial acceptance (4 of 5), the ordinary path: a correction token lands in the
    middle of the drafts.
  - **Case 2** — every draft accepted, so the bonus token at the extra position is committed and
    `"first_reject_index"` is `-1`. This is the only case that can catch a solution that never looks
    at the `k+1`-th position.
  - **Case 3** — rejected at the *first* drafted position, with the remaining drafts deliberately
    matching their positions. This is the only case that catches a solution counting all matches
    rather than the leading run.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Window shifted right** (using the drafted position's own row instead of the row before it,
    `logits[ctx_len : ctx_len + k]`): case 1 → `num_accepted 0`, sequence `[3, 11, 5, 2, 1]`;
    case 2 → `0`, `[8, 0, 15, 6]`; case 3 → `4`, `first_reject_index -1`,
    `[1, 4, 4, 9, 13, 5, 5, 5, 5, 5]`. Caught on all three, and case 3 shows it can silently
    *inflate* the accepted count.
  - **Window shifted left** (`logits[ctx_len - 2 : ctx_len + k - 1]`): `num_accepted 0` on all three
    with sequences ending `20`, `4` and `22` — caught on all three. The rows before the window were
    given argmaxes that appear nowhere in the drafts precisely so this fails loudly.
  - **Taking only `k` preferred tokens** (the demonstration's own slice, with the halt index
    clamped): passes cases 1 and 3, and on **case 2** commits `[8, 0, 15, 2, 6, 6, 6]` — the last
    accepted token duplicated — against the correct `[…, 6, 6, 10]`. **Case 2 must stay in any
    shipped subset.**
  - **Counting every match instead of the leading run:** passes cases 1 and 2, and on **case 3**
    returns `num_accepted 3`, sequence `[1, 4, 4, 9, 13, 5, 5, 5, 5]` against the correct
    `0` / `[1, 4, 4, 9, 13, 12]`. **Case 3 must stay in any shipped subset.**
  - **Dropping the correction/bonus token:** sequences `[…, 7, 1, 9, 4]`, `[…, 2, 6, 6]`,
    `[1, 4, 4, 9, 13]` — caught on all three.
  - **Omitting the context from `"sequence"`** (returning only the committed tokens): `[7, 1, 9, 4,
    6]`, `[2, 6, 6, 10]`, `[12]` — caught on all three.
  - **Reporting the accepted count as the reject index** (no `-1` sentinel): passes cases 1 and 3
    — where the two coincide by construction — and fails **case 2** with `3` instead of `-1`.
  - **Counting the correction as an accepted draft** (`num_accepted + 1`): `5`, `4`, `1` — caught on
    all three.
- **`"first_reject_index"` equals `"num_accepted"` whenever a rejection happens**, by construction:
  the walk stops at the first mismatch. Its informative value is entirely in the all-accepted case,
  hence the previous bullet. Do not drop case 2.
- **Accepted route — verified identical on all three cases:** taking `torch.argmax` over the whole
  logits matrix once and then indexing the needed `k+1` entries out of the result, instead of
  slicing first and then taking the argmax. Same values; accept it.
- **Overlap check:** the topic-organized bank's `verify_speculative_step`
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`, Q8) is
  handed the target's preferred token ids **already argmaxed**, `k + 1` of them, and grades the
  comparison walk. Here the preferred tokens do not exist until the learner derives them from a
  logits matrix over the whole verification input, which is where the alignment work lives; the
  committed output is returned as the continued sequence including the context, and the rejection
  index is new. The two questions share only the acceptance rule. Ship both only if you want the
  alignment step tested separately from the walk.
- All three cases executed against the reference solution (Python 3.12, torch 2.13.0).

---

## Q4: Accounting for a Speculative Decoding Loop

**Context:** A single speculative step is the unit; real generation wraps it in a loop that keeps
drafting and verifying until enough tokens exist. What matters operationally is the ratio the loop
achieves: each round spends exactly one expensive target forward pass and commits however many
tokens the target agreed with, plus one. Fewer target passes than tokens is the structural win, and
it is guaranteed. Whether it becomes a wall-clock win is not — the draft model's own passes have to
be paid for too, and when the draft is not much cheaper than the target they can eat the entire
saving.

**Problem Statement:**

Write a function
`speculative_loop_accounting(prompt_len, max_new_tokens, k, accepted_per_round, draft_cost_ratio)`.

1. Each round of the loop drafts `k` candidate tokens with `k` cheap serial draft-model passes,
   verifies them in exactly **one** target-model forward pass, and commits the accepted drafted
   tokens plus one token from the target — that is, `accepted + 1` tokens for a round in which
   `accepted` drafted tokens were accepted.
2. `accepted_per_round[i]` is the number of drafted tokens accepted in round `i`, in order. Before
   each round the loop checks whether it has already committed at least `max_new_tokens` tokens and
   stops if it has, so the last round it runs can push the committed total past `max_new_tokens`.
   `accepted_per_round` may hold more entries than the loop needs; ignore the extras.
3. Report the total number of tokens committed by the rounds that ran, and the number of target
   forward passes spent.
4. Report the context length once the loop stops: `prompt_len` plus every token committed, with no
   truncation.
5. Report the tokens committed per target forward pass, rounded to 4 decimal places.
6. Plain autoregressive decoding spends one target forward pass per token produced. Measure both
   schemes in target-pass-equivalents, where `draft_cost_ratio` is the cost of one draft-model pass
   as a fraction of one target-model pass: a speculative round costs
   `1 + k × draft_cost_ratio`, while producing the same tokens without drafting costs one pass per
   token. Report the resulting speedup — the plain scheme's cost divided by the speculative
   scheme's — rounded to 4 decimal places.
7. Return a dictionary with keys `"tokens_produced"` (integer), `"target_passes"` (integer),
   `"final_length"` (integer), `"tokens_per_pass"` (float) and `"speedup"` (float).

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: prompt_len (integer)
    Single line: one integer
  Argument 2: max_new_tokens (integer)
    Single line: one integer
  Argument 3: k (integer)
    Single line: one integer
  Argument 4: accepted_per_round (list_int)
    Line 1: N (list length)
    Line 2: N space-separated integers
  Argument 5: draft_cost_ratio (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `speculative_loop_accounting()` on a new line.

**Sample Input:**

```
prompt_len = 9
max_new_tokens = 60
k = 5
accepted_per_round = [4, 0, 1, 1, 4, 0, 1, 1, 4, 0, 1, 1, 4, 0, 1, 1, 4, 0, 1, 1,
                      4, 0, 1, 1, 4, 0, 1, 1, 2, 3]
draft_cost_ratio = 0.34
```

**Sample Output:**

```
{'tokens_produced': 60, 'target_passes': 24, 'final_length': 69, 'tokens_per_pass': 2.5, 'speedup': 0.9259}
```

**Note:** The input handling is already in place — you only need to implement the function. This is
arithmetic on a loop's schedule; nothing is loaded. Both schemes in step 6 are compared over the
same number of tokens — the ones the loop actually committed — and a speedup below 1 is a real
outcome, not an error: it is what a draft model that is not much cheaper than the target buys you.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: speculative_loop_accounting
RETURN TYPE: Dictionary

ARGUMENTS:
1. prompt_len         → Integer
2. max_new_tokens     → Integer
3. k                  → Integer
4. accepted_per_round → List of Ints
5. draft_cost_ratio   → Float
```

(`max_new_tokens` and `k` carry defaults in the loop this mirrors — required here and supplied in
every test case. Five values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
def speculative_loop_accounting(prompt_len: int, max_new_tokens: int, k: int,
                                accepted_per_round: list, draft_cost_ratio: float) -> dict:
    tokens_produced = 0
    target_passes = 0
    for accepted in accepted_per_round:
        if tokens_produced >= max_new_tokens:
            break
        tokens_produced += accepted + 1
        target_passes += 1

    cost_per_round = 1.0 + k * draft_cost_ratio
    return {
        "tokens_produced": tokens_produced,
        "target_passes": target_passes,
        "final_length": prompt_len + tokens_produced,
        "tokens_per_pass": round(tokens_produced / target_passes, 4),
        "speedup": round(tokens_produced / (target_passes * cost_per_round), 4),
    }
```

**Test Cases —** `in.txt`

```
2
9
60
5
30
4 0 1 1 4 0 1 1 4 0 1 1 4 0 1 1 4 0 1 1 4 0 1 1 4 0 1 1 2 3
0.34
512
25
8
10
8 3 0 8 8 1 5 8 0 2
0.05
```

**Test Cases —** `out.txt`

```
{'tokens_produced': 60, 'target_passes': 24, 'final_length': 69, 'tokens_per_pass': 2.5, 'speedup': 0.9259}
{'tokens_produced': 32, 'target_passes': 5, 'final_length': 544, 'tokens_per_pass': 6.4, 'speedup': 4.5714}
```

**Scope trace** (`modules/02-advanced-ai-agents/markdown/L9_LLM_Inference_Optimization.md`):

- The loop itself — lines 543–578: `while ids.shape[1] - start_len < max_new_tokens` (the
  check-before-each-round rule of step 2, line 549), `target_calls += 1` for one target pass per
  round (line 560), and `torch.cat([accepted, correction])` appending `accepted + 1` tokens per
  round (lines 573–576).
- The overshoot of step 2 and the untruncated length of step 4 — line 578, `return ids[0, :start_len
  + max_new_tokens], target_calls`: the loop appends whole rounds and only the *return* trims to
  `max_new_tokens`, so the context can be longer than `prompt_len + max_new_tokens` when the loop
  stops.
- One expensive target call per step — line 523 ("Expensive target-model calls : 1") and line 273.
- Tokens per target pass — lines 604 and 608, `tokens/call: {N/spec_calls:.2f}`, printed for both
  schemes; the baseline's "one target call per token" is stated at line 588.
- The draft's `k` cheap serial passes per round — line 272 ("The small model cheaply proposes `k`
  candidate tokens by running its own short autoregressive loop") and line 360; the target
  verification pass costing about one ordinary decode step — line 390.
- Case 1 reproduces the observed run at lines 611–625 exactly: 60 tokens, 24 target calls,
  `tokens/call 2.50`, with `k = 5` from line 595. Its `draft_cost_ratio = 0.34` reflects the "~3×
  bigger" target of line 632; the resulting speedup of `0.9259` is the "modest or even negative"
  wall-clock outcome of line 630. Case 2's near-free draft (`0.05`) is the other end line 632
  names.
- **Disclosed, not taught:** the cost model of step 6. The material states each ingredient — one
  target pass per round, `k` draft passes per round, a plain decoder's one pass per token, and that
  the draft overhead eats the saving when the models are close in size — but never writes the
  arithmetic down. Step 6 states it in full, so nothing has to be recalled. The structural quantity
  the material *does* print (`tokens/call`) is graded separately as `"tokens_per_pass"`.

**Grader Notes:**

- **Environment:** Python 3.12, standard library only. Runs instantly.
- Compare the three integers exactly and the two floats with tolerance `1e-3`. Dictionary key order
  is not significant. Both floats are exact rationals (`60/24`, `60/64.8`, `32/5`, `32/7`), so
  `round(..., 4)` is reproducible; case 1's `2.5` and case 2's `6.4` print with fewer than four
  decimals, which is Python's float repr, not a truncation.
- **`"tokens_per_pass"` and `"speedup"` are different numbers on both shipped cases** (`2.5` vs
  `0.9259`; `6.4` vs `4.5714`). They coincide only when `draft_cost_ratio` is `0`, and neither case
  uses `0`, so a solution that reports the same value for both keys fails both cases.
- **What each case is for:**
  - **Case 1** lands exactly on `max_new_tokens` (24 rounds × the repeating `4, 0, 1, 1` pattern =
    60 tokens) and carries 6 unused trailing entries. It is the case that reproduces the material's
    own observed figures, and its speedup is below 1.
  - **Case 2** overshoots: the fifth round pushes the total from 23 to 32 against a
    `max_new_tokens` of 25, and 5 of its 10 entries go unused. It is the only case that catches
    capping the token count.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Summing the whole `accepted_per_round` list** instead of stopping when the target is reached:
    `77` tokens over `30` passes (`tokens_per_pass 2.5667`, `speedup 0.9506`) and `53` over `10`
    (`5.3`, `3.7857`) — caught on both cases. Every shipped case supplies surplus entries so this
    can never pass.
  - **Capping the committed total at `max_new_tokens`:** passes **case 1** (which lands exactly on
    60) and fails **case 2** with `25 / 537 / 5.0 / 3.5714` against `32 / 544 / 6.4 / 4.5714`.
    **Case 2 must stay in any shipped subset.**
  - **Not counting the correction/bonus token** (`accepted` tokens per round, not `accepted + 1`):
    `47` tokens over `30` passes and `27` over `5` — caught on both.
  - **Counting the bonus twice** (`accepted + 2`): `62 / 17 / 3.6471 / 1.3508` and
    `27 / 4 / 6.75 / 4.8214` — caught on both. Note it also changes the pass count, because rounds
    reach the target sooner.
  - **Ignoring the draft cost in the speedup** (reporting `tokens / passes` for both keys): `2.5`
    and `6.4` against `0.9259` and `4.5714` — caught on both.
  - **Charging one draft pass per round instead of `k`** (`1 + draft_cost_ratio`): `1.8657` and
    `6.0952` — caught on both, and the two cases use different `k` (5 and 8) so no single fudge
    factor fits both.
  - **Including the prompt in the rate** (`(prompt_len + tokens) / passes`): `2.875` / `1.0648` and
    `108.8` / `77.7143` — caught on both, and case 2's 512-token prompt makes the error enormous
    rather than subtle. `"final_length"` is the only key the prompt belongs in.
- `"final_length"` is `prompt_len + tokens_produced` **untruncated** (`69` and `544`), per step 4.
  Reporting `prompt_len + max_new_tokens` instead was implemented and run: it gives `69` (passing
  case 1) and `537` (failing case 2) — the same case-2 dependency as the capping reading above.
- **Overlap check:** no question in the topic-organized bank
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`) does
  loop-level accounting; its Q8 covers a single verification step and returns per-step counters. Q3
  of this file constructs one step's output from logits, while this question never sees a token id
  — it consumes an acceptance schedule. No shared graded value.
- Both cases executed against the reference solution (Python 3.12).
