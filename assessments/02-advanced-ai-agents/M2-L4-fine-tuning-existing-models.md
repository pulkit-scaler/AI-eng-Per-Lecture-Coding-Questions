# Module 2, Lecture 4 — Fine-Tuning Existing Models

Five coding questions spanning both halves of the material. **Adaptation:** attaching LoRA adapters
to a real base model and reading back what was injected (Q1), costing two target-module presets
against each other (Q2), and folding a trained adapter into the frozen weights (Q3). **The training
objective and its data:** the SFT loss on the response tokens only (Q4), and the step before it —
turning an Alpaca record into a rendered chat template and counting what the model will actually see
(Q5).

Nothing is trained and no GPU is needed. Q1, Q2 and Q3 load tiny `qwen2` test checkpoints from the
HF Hub (a few hundred KB each, ~1.5 s per case); Q5 needs only that checkpoint's tokenizer files, no
weights at all; Q4 works on a supplied score matrix. All five are fully deterministic — the
model-loading questions grade structure, counts and merged weights, never randomly-initialised
adapter values.

---

## Q1: Attaching LoRA Adapters to a Base Model with PEFT

**Context:** Turning a frozen base model into a LoRA-trainable one is a three-step move: load the
pretrained model, describe the adaptation in a config (which rank, which scaling factor, which
weight matrices to adapt), and wrap the model so the adapters are injected in place. What comes
back is the same network with a pair of small trainable matrices bolted alongside each targeted
projection — the original weights untouched and frozen. Reading the injected adapters back off the
wrapped model is how you confirm the config did what you intended: the right layers were hit, and
each adapter has the rank you asked for.

**Problem Statement:**

Using the `transformers` and `peft` libraries, write a function
`lora_adapter_shapes(model_id, r, lora_alpha, target_modules)`.

1. Load the base causal language model with `AutoModelForCausalLM.from_pretrained(model_id)`.
2. Build a `LoraConfig` for a decoder-only language model (`task_type="CAUSAL_LM"`) using `r` as
   the rank, `lora_alpha` as the scaling factor, `0.05` dropout, no bias training
   (`bias="none"`), and `target_modules` as the list of module names to adapt.
3. Wrap the base model with `get_peft_model` so the adapters are injected.
4. For each adapted module, read the shapes of its **two low-rank matrices** off the wrapped
   model — the down-projection and the up-projection that were injected next to the frozen
   weights. The same set of modules is adapted inside every transformer block and the shapes are
   identical in each, so report every adapted module name exactly once.
5. Return a dictionary with exactly two keys:
   - `"scaling"` — the effective scaling factor the adapter applies, as a float
   - `"adapters"` — a dictionary mapping each adapted module's name to a list of four integers:
     the down-projection's row count, its column count, then the up-projection's row count and
     its column count

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: model_id (string)
    Single line: a string
  Argument 2: r (integer)
    Single line: one integer
  Argument 3: lora_alpha (integer)
    Single line: one integer
  Argument 4: target_modules (list_string)
    Line 1: N (list length)
    Next N lines: one string each
```

**Output Format:**

For each test case, print the result of `lora_adapter_shapes()` on a new line.

**Sample Input:**

```
model_id = "trl-internal-testing/tiny-Qwen2ForCausalLM-2.5"
r = 4
lora_alpha = 8
target_modules = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]
```

**Sample Output:**

```
{'scaling': 2.0, 'adapters': {'q_proj': [4, 8, 8, 4], 'k_proj': [4, 8, 4, 4], 'v_proj': [4, 8, 4, 4], 'o_proj': [4, 8, 8, 4], 'gate_proj': [4, 8, 32, 4], 'up_proj': [4, 8, 32, 4], 'down_proj': [4, 32, 8, 4]}}
```

**Note:** The input handling is already in place — you only need to implement the function. The
models used here are tiny test checkpoints, so loading one inside the function is cheap. Take the
shapes from the wrapped model itself rather than reasoning them out from the config — that is the
point of inspecting what was injected. Adapt only the modules named in `target_modules`: a module
the list doesn't name must not appear in the result, even if it is a linear layer. Note also that
one of the two matrices has the incoming feature count on one side and the other has the outgoing
feature count — a module whose input and output widths differ will make that visible, so don't
assume the two shapes are transposes of a square.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: lora_adapter_shapes
RETURN TYPE: Dictionary

ARGUMENTS:
1. model_id       → String
2. r              → Integer
3. lora_alpha     → Integer
4. target_modules → List of Strings
```

(`r`, `lora_alpha` and `target_modules` all carry defaults on `LoraConfig` — required here and
supplied in every test case. Two values must come back (the scaling and the per-module shapes), so
they fold into one nested `Dictionary`.)

**Reference Solution:**

```python
from transformers import AutoModelForCausalLM
from peft import LoraConfig, get_peft_model


def lora_adapter_shapes(model_id: str, r: int, lora_alpha: int, target_modules: list) -> dict:
    base_model = AutoModelForCausalLM.from_pretrained(model_id)

    lora_config = LoraConfig(
        task_type="CAUSAL_LM",
        r=r,
        lora_alpha=lora_alpha,
        lora_dropout=0.05,
        bias="none",
        target_modules=target_modules,
    )
    peft_model = get_peft_model(base_model, lora_config)

    sample_layer = peft_model.model.model.layers[0]

    adapters = {}
    for name in target_modules:
        if "proj" in name and ("q_" in name or "k_" in name or "v_" in name or "o_" in name):
            module = getattr(sample_layer.self_attn, name)
        else:
            module = getattr(sample_layer.mlp, name)

        if hasattr(module, "lora_A"):
            A_shape = module.lora_A["default"].weight.shape   # (r, in_features)
            B_shape = module.lora_B["default"].weight.shape   # (out_features, r)
            adapters[name] = [A_shape[0], A_shape[1], B_shape[0], B_shape[1]]

    return {"scaling": lora_alpha / r, "adapters": adapters}
```

**Test Cases —** `in.txt`

```
2
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
4
8
7
q_proj
k_proj
v_proj
o_proj
gate_proj
up_proj
down_proj
trl-internal-testing/small-Qwen2ForCausalLM-2.5
8
24
2
q_proj
v_proj
```

**Test Cases —** `out.txt`

```
{'scaling': 2.0, 'adapters': {'q_proj': [4, 8, 8, 4], 'k_proj': [4, 8, 4, 4], 'v_proj': [4, 8, 4, 4], 'o_proj': [4, 8, 8, 4], 'gate_proj': [4, 8, 32, 4], 'up_proj': [4, 8, 32, 4], 'down_proj': [4, 32, 8, 4]}}
{'scaling': 3.0, 'adapters': {'q_proj': [8, 128, 128, 8], 'v_proj': [8, 128, 64, 8]}}
```

**Grader Notes:**

- **Environment:** needs `transformers`, `peft` and outbound access to the HF Hub. Both checkpoints
  are tiny test models (2 transformer blocks, a few hundred KB), so a cold run downloads almost
  nothing and each test case completed in **~1.0–1.5 s** in verification (transformers 5.14.1,
  peft 0.20.0, torch 2.13.0). No GPU.
- **Why these models and not the source material's own.** The source material fine-tunes
  `Qwen/Qwen2.5-1.5B` — a ~3 GB download, not viable in a grader. Both test checkpoints are the
  **same architecture family** (`qwen2`), which is what keeps the taught module names
  (`q_proj`/`k_proj`/`v_proj`/`o_proj`/`gate_proj`/`up_proj`/`down_proj`) valid. Do **not**
  substitute a GPT-2-class model: its attention is a single fused `c_attn`, so the learner would
  have to pass a module name this material never teaches.
- **Only structure is gradeable — never weight values.** `lora_A` is initialised randomly and
  `lora_B` to zeros, so any observable touching the actual numbers is non-deterministic. Shapes,
  names and `alpha / r` are fully determined by `(model_id, r, lora_alpha, target_modules)`; both
  cases were re-run and are byte-identical.
- Compare `"scaling"` with tolerance `1e-6` (it is an exact ratio of small integers) and the
  `"adapters"` shape lists exactly. Dictionary key order is not significant in either level.
- Case 1's shapes are a faithful miniature of the source material's own printed table: hidden
  width 8 (vs 1536), narrower key/value width 4 (vs 256), MLP width 32 (vs 8960), and a
  `down_proj` whose down-projection reads `[4, 32]` — exactly mirroring the source's
  `down_proj: A=[16, 8960], B=[1536, 16]`.
- Verified on the shipped cases — each wrong reading below was run:
  - **Reporting the two shapes in the wrong order / transposed** (up-projection first, or each
    shape reversed): case 1 becomes `q_proj: [8, 4, 4, 8]`, `down_proj: [8, 4, 4, 32]` — caught.
  - **Reading the frozen base layer instead of the adapters** (`module.base_layer.weight.shape`):
    yields two-element lists (`q_proj: [8, 8]`, `k_proj: [4, 8]`) — caught.
  - **Ignoring `target_modules`** and adapting every linear layer (e.g. passing
    `target_modules="all-linear"`): **case 2 catches this** — 7 keys instead of the 2 asked for.
    Case 1 does not, because its list already names all seven adapted projections, so case 2 must
    stay in any shipped subset.
  - **Scaling read wrong:** `alpha` alone gives `8.0` / `24.0` and `r / alpha` gives `0.5` /
    `0.333…`, against the correct `2.0` / `3.0`. Both cases catch both, and the two cases use
    different `alpha` **and** different `r`, so no single constant passes.
  - **Including the output head:** `lm_head` is a linear layer in both checkpoints and is named in
    neither `target_modules` list, so a solution that sweeps all `Linear` modules by type rather
    than by name picks it up. (Note `peft`'s own `"all-linear"` shorthand excludes it, which is why
    the previous bullet shows 7 keys rather than 8.)
- `lora_dropout=0.05` and `bias="none"` do not affect the return value — they are specified for
  fidelity to the taught config. Don't be surprised that changing them changes nothing.
- **Accepted routes — all verified to return identical values on both cases:**
  1. Navigating to `peft_model.model.model.layers[0]` and pulling each module with
     `getattr(sample_layer.self_attn, name)` / `getattr(sample_layer.mlp, name)`, guarded by
     `hasattr(module, 'lora_A')` — the reference, and a line-for-line match with the source
     material's own inspection cell.
  2. Walking `peft_model.named_modules()` and matching the last dotted component of each name
     against `target_modules`. Architecture-independent, but `named_modules()` is **not** used
     anywhere in the source material, so it must never be the *required* route — only an accepted
     one.
  3. `scaling` computed as `lora_alpha / r` (the reference, mirroring the source's printed
     `"Effective scaling"`) **or** read off the module as `module.scaling["default"]`. The latter
     gives the same float but, again, does not appear in the source material.
  4. Deriving the shapes analytically from the model config instead of reading them off the wrapped
     model. Numerically identical; accept it, though the statement asks for inspection because that
     is the taught operation.
- The reference **loads the model fresh on every call** rather than caching it in a module-level
  dict. `get_peft_model` injects adapters into the base model **in place**, so a cached base model
  is a wrapped model by the second call. Re-wrapping the same object was tested and did *not*
  change the trainable count in peft 0.20.0, so a cached solution is not automatically wrong — but
  the shipped test cases deliberately use two **different** `model_id`s, so the situation never
  arises for the grader.
- **Curriculum alignment.** Every API the reference solution calls appears in the source material,
  in the same order:
  - `AutoModelForCausalLM.from_pretrained(...)` — the base-model load.
  - `LoraConfig(r=…, lora_alpha=…, lora_dropout=…, bias="none", task_type="CAUSAL_LM",
    target_modules=…)` — verbatim, every keyword included.
  - `get_peft_model(model, peft_config)` — verbatim.
  - `lora_model.model.model.layers[0]` → `getattr(sample_layer.self_attn, name)` /
    `getattr(sample_layer.mlp, name)` → `if hasattr(module, 'lora_A'):` →
    `lora_A['default'].weight.shape  # (r, in_features)` and
    `lora_B['default'].weight.shape  # (out_features, r)` — the reference reproduces this loop,
    including the branch that decides whether a target name lives under `self_attn` or `mlp` and
    the `hasattr` guard.
  - `lora_alpha / r` for the scaling — the material prints exactly
    `Effective scaling: {peft_config.lora_alpha / peft_config.r}`.
  - Case 1's seven-name `target_modules` list is the material's own all-linear preset; case 2's
    `["q_proj", "v_proj"]` is its "minimal (original paper)" preset.
  An **earlier draft of this answer key used `named_modules()` and `module.scaling["default"]`.
  Neither appears anywhere in the source material**, so the key was rewritten to the taught route;
  both remain accepted alternatives (see the routes bullet above) because they return identical
  values, but the reference no longer depends on an API the material never calls.
- **Overlap check:** the topic-organized bank's `prepare_model_for_lora`
  (`../advanced-ai-agents-coding-ques.md`, Q6) also loads a model and calls `get_peft_model`, but
  returns the **trainable-parameter percentage** — the same number Q2 of this file computes from a
  config. This question returns **structure** (which modules were adapted, in what shape, at what
  scaling) and never a count, so all three stay distinct. Still, Q6 and this question are the same
  wiring exercise; prefer one or the other in a single paper.
- Both cases executed against the reference solution (transformers 5.14.1, peft 0.20.0,
  torch 2.13.0).

---

## Q2: What Two Target-Module Presets Cost in Trainable Parameters

**Context:** Choosing which weight matrices receive an adapter is the hyperparameter that moves the
trainable-parameter count most. The original paper adapted only the attention query and value
projections; current practice adapts every linear layer in the block, attention and MLP alike, and
pays for it in trainable parameters. The only honest way to compare two presets is to build both
adapted models and ask each one what it is actually training — the count depends on the widths
inside the checkpoint, not on the length of the preset list. A rank-8 adapter on a narrow key
projection and on a wide MLP projection cost very different amounts.

**Problem Statement:**

Using the `transformers` and `peft` libraries, write a function
`lora_budget_comparison(model_id, r, preset_a, preset_b)`.

1. `preset_a` and `preset_b` are two lists of module names to adapt. Adapt the base model
   `model_id` twice, once under each preset, both at rank `r`. Build each `LoraConfig` the way the
   material does — decoder-only task type, `0.05` dropout, no bias training, and a scaling factor
   of twice the rank — then wrap the base model so the adapters are injected.
2. Ask each wrapped model for its own trainable and total parameter counts rather than deriving
   them from the config. Note that injecting adapters modifies the base model **in place**, so the
   second preset must be applied to a base model that has not already been adapted.
3. Report, for each preset, the number of trainable parameters and that number as a percentage of
   the wrapped model's total parameters, rounded to 4 decimal places.
4. Report the ratio of the two trainable counts, `preset_a` over `preset_b`, rounded to 4 decimal
   places.
5. Return a dictionary with exactly these five keys: `"trainable_a"`, `"pct_a"`, `"trainable_b"`,
   `"pct_b"` and `"ratio"`.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: model_id (string)
    Single line: a string
  Argument 2: r (integer)
    Single line: one integer
  Argument 3: preset_a (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 4: preset_b (list_string)
    Line 1: N (list length)
    Next N lines: one string each
```

**Output Format:**

For each test case, print the result of `lora_budget_comparison()` on a new line.

**Sample Input:**

```
model_id = "trl-internal-testing/tiny-Qwen2ForCausalLM-2.5"
r = 8
preset_a = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"]
preset_b = ["q_proj", "v_proj"]
```

**Sample Output:**

```
{'trainable_a': 2816, 'pct_a': 0.1158, 'trainable_b': 448, 'pct_b': 0.0184, 'ratio': 6.2857}
```

**Note:** The input handling is already in place — you only need to implement the function. The
models used here are tiny test checkpoints, so loading one inside the function is cheap. The two
percentages have different denominators, because a wrapped model's total includes the adapters it
just gained. The scaling factor plays no part in any number you report — it is specified so the
config matches the one the material builds, nothing more.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: lora_budget_comparison
RETURN TYPE: Dictionary

ARGUMENTS:
1. model_id → String
2. r        → Integer
3. preset_a → List of Strings
4. preset_b → List of Strings
```

(`r` and both preset lists carry defaults on `LoraConfig` — required here and supplied in every test
case. Five values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
from transformers import AutoModelForCausalLM
from peft import LoraConfig, get_peft_model


def lora_budget_comparison(model_id: str, r: int, preset_a: list, preset_b: list) -> dict:
    def budget(target_modules):
        model = AutoModelForCausalLM.from_pretrained(model_id)
        config = LoraConfig(task_type="CAUSAL_LM", r=r, lora_alpha=2 * r,
                            lora_dropout=0.05, bias="none",
                            target_modules=target_modules)
        wrapped = get_peft_model(model, config)
        return wrapped.get_nb_trainable_parameters()

    trainable_a, total_a = budget(preset_a)
    trainable_b, total_b = budget(preset_b)

    return {
        "trainable_a": int(trainable_a),
        "pct_a": round(100.0 * trainable_a / total_a, 4),
        "trainable_b": int(trainable_b),
        "pct_b": round(100.0 * trainable_b / total_b, 4),
        "ratio": round(trainable_a / trainable_b, 4),
    }
```

**Test Cases —** `in.txt`

```
2
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
8
7
q_proj
k_proj
v_proj
o_proj
gate_proj
up_proj
down_proj
2
q_proj
v_proj
trl-internal-testing/small-Qwen2ForCausalLM-2.5
4
4
q_proj
k_proj
v_proj
o_proj
2
q_proj
v_proj
```

**Test Cases —** `out.txt`

```
{'trainable_a': 2816, 'pct_a': 0.1158, 'trainable_b': 448, 'pct_b': 0.0184, 'ratio': 6.2857}
{'trainable_a': 7168, 'pct_a': 0.0184, 'trainable_b': 3584, 'pct_b': 0.0092, 'ratio': 2.0}
```

**Grader Notes:**

- **Environment:** needs `transformers`, `peft` and outbound access to the HF Hub. Four model loads
  per run across the two cases, each a few hundred KB; verified in ~4 s total (transformers 5.15.0,
  peft 0.20.0, torch 2.13.0, Python 3.12.13, CPU).
- **The library produces the graded value.** `get_nb_trainable_parameters()` reports what `peft`
  actually marked trainable after injection. The counts depend on the checkpoint's per-module widths
  — `k_proj`/`v_proj` are narrower than `q_proj` in this architecture — so they cannot be recovered
  from `(r, len(preset))` alone. This replaced an earlier arithmetic-only version of this question
  that computed `r × (d_in + d_out) × num_layers` from a supplied width table; that version never
  loaded a model.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L4_Fine_Tuning_Existing_Models.md`:
  - The two presets are the material's own named options — **lines 455 and 457**: "**Minimal**
    (original paper): `["q_proj", "v_proj"]`" and "**All linear (recommended)**", with
    "**Attention only**" at line 456 supplying case 2's `preset_a`.
  - The config keywords — **lines 848–855**, verbatim including `lora_dropout`, `bias="none"` and
    `task_type="CAUSAL_LM"`; the alpha-is-twice-the-rank rule at **line 445** and as built at
    **line 506** (`LORA_ALPHA = 32` against `LORA_R = 16`).
  - `get_peft_model(model, peft_config)` — **line 878**.
  - Trainable-and-total reporting with the percentage to 4 decimals — **lines 141–146**
    (`print_trainable_params`, `{100 * trainable / total:.4f}%`) and its printed output at
    **lines 895–896** (`18,464,768  (1.1820%)` against `1,562,179,072`). Step 3 is that helper's two
    numbers, per preset.
  - Re-wrapping in place being unsafe — **lines 978–989**: the material deletes the wrapper and
    **reloads the base model fresh** before handing it to `SFTTrainer`, with the comment explaining
    why. Step 2's warning is that cell.
  - **Disclosed, not taught:** `get_nb_trainable_parameters()` as a called method. The material
    computes the same two numbers by summing `p.numel()` over `model.parameters()` with a
    `requires_grad` filter (lines 143–144). Both routes were run and agree exactly on both cases, so
    either is accepted; step 2 asks for the model's own report without naming the method.
- **Determinism.** Counts are integers fixed by the checkpoint and the config; adapter *values* are
  random-initialised and are never touched. Both cases re-run byte-identical.
- Compare the two counts and the ratio exactly; the two percentages with tolerance `1e-4`.
  Dictionary key order is not significant.
- **What each case is for:**
  - **Case 1** — all-linear against minimal on the tiny checkpoint. The 7-name preset costs
    6.2857× the 2-name one, *not* 3.5× as the list lengths would suggest, because the MLP
    projections are wider than the attention ones. This is the case that catches any solution
    reasoning from list length.
  - **Case 2** — attention-only against minimal on the wider checkpoint, where all four attention
    projections happen to be square and equal, so the ratio *is* exactly 2.0. A solution that
    always scales by list length passes case 2 and fails case 1; a solution that reads real widths
    passes both. Case 1 must stay in any shipped subset.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Wrapping the same base model twice** (hoisting the load out of the helper): case 1 returns
    `trainable_b` 3264 instead of 448 — the second wrap adds its adapters on top of the first
    preset's — and `ratio` 0.8627. Caught by both cases.
  - **Percentage against the base count instead of the wrapped total**: `pct_a` 0.116 vs 0.1158 on
    case 1 — within `1e-3` but outside the `1e-4` tolerance, so keep the tolerance tight.
  - **Reporting `all_param` as the trainable count** (tuple order reversed): 2429080 / 2428632 —
    caught on both.
  - **Deriving the count as `r × (d_in + d_out) × layers` from the config**: matches only if the
    widths are looked up per module; a uniform-width assumption gives 3584 for case 1's `preset_a`.
- **Overlap check:** Q1 of this file wraps a model with the same two calls but returns adapter
  **shapes** and the scaling — structure, not budget. The material presents these as two separate
  cells (the inspection loop at lines 933–954, `print_trainable_params` at line 883), and neither
  question's answer can be derived from the other's. Ship both only if you want structure and cost
  tested separately; they do share the wrapping call.
- Both cases executed against the reference solution.

---

## Q3: Merging a LoRA Adapter Into the Base Weights with PEFT

**Context:** A LoRA-adapted layer keeps its pretrained matrix frozen and evaluates a second, low-rank
branch beside it on every forward pass. That branch is pure overhead once training is over, which is
why an adapter is *merged* before deployment: the scaled low-rank product is folded into the frozen
matrix and the two branches collapse into one. What comes out is an ordinary layer again — same
shape, same inference cost, no adapter machinery left anywhere in the model. The fold is a single
library call, and confirming it worked means looking at three things: a weight that moved, an
adapter that is gone, and a parameter count back at the base model's.

**Problem Statement:**

Using the `transformers` and `peft` libraries, write a function
`merge_lora_adapter(model_id, r, lora_alpha, target_modules, a_fill, b_fill, probe_row, probe_col)`.

1. Load the base causal language model `model_id` in 32-bit floating point, build a `LoraConfig`
   for a decoder-only model at rank `r` with scaling factor `lora_alpha`, `0.05` dropout, no bias
   training and `target_modules` as the modules to adapt, then wrap the model so the adapters are
   injected.
2. The probe throughout is the **query projection of the first transformer block**. Before anything
   is merged, read the frozen weight sitting at row `probe_row`, column `probe_col` of that
   projection.
3. A freshly injected adapter contributes nothing — one of its two matrices is initialised to zeros,
   so merging it would change no weight at all. Stand in for a trained adapter by filling that
   projection's down-projection matrix entirely with `a_fill` and its up-projection matrix entirely
   with `b_fill`.
4. Merge the adapters into the base weights and unload the adapter machinery, using the library call
   that does both. Then read the same (`probe_row`, `probe_col`) entry off the merged model.
5. Report how many modules in the merged model still carry an injected down-projection matrix, and
   the merged model's total parameter count.
6. Return a dictionary with exactly these five keys: `"base_entry"`, `"merged_entry"` and `"delta"`
   — the entry before, the entry after, and the difference, each rounded to 6 decimal places —
   plus `"adapters_left"` and `"merged_params"` as integers.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: model_id (string)
    Single line: a string
  Argument 2: r (integer)
    Single line: one integer
  Argument 3: lora_alpha (integer)
    Single line: one integer
  Argument 4: target_modules (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 5: a_fill (float)
    Single line: one float
  Argument 6: b_fill (float)
    Single line: one float
  Argument 7: probe_row (integer)
    Single line: one integer
  Argument 8: probe_col (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `merge_lora_adapter()` on a new line.

**Sample Input:**

```
model_id = "trl-internal-testing/tiny-Qwen2ForCausalLM-2.5"
r = 4
lora_alpha = 8
target_modules = ["q_proj", "v_proj"]
a_fill = 0.01
b_fill = 0.02
probe_row = 2
probe_col = 3
```

**Sample Output:**

```
{'base_entry': 0.128906, 'merged_entry': 0.130506, 'delta': 0.0016, 'adapters_left': 0, 'merged_params': 2428632}
```

**Note:** The input handling is already in place — you only need to implement the function. The
models are tiny test checkpoints, so loading one inside the function is cheap. Read both entries off
the model rather than reconstructing either: the frozen weight is a property of the checkpoint, and
the merged one is whatever the library wrote back. Note that merging returns a model whose module
layout is the plain base architecture again, not the wrapped one — the path to the query projection
is not the same before and after.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: merge_lora_adapter
RETURN TYPE: Dictionary

ARGUMENTS:
1. model_id       → String
2. r              → Integer
3. lora_alpha     → Integer
4. target_modules → List of Strings
5. a_fill         → Float
6. b_fill         → Float
7. probe_row      → Integer
8. probe_col      → Integer
```

(`r`, `lora_alpha` and `target_modules` carry defaults on `LoraConfig` — required here and supplied
in every test case. Five values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
import torch
from transformers import AutoModelForCausalLM
from peft import LoraConfig, get_peft_model


def merge_lora_adapter(model_id: str, r: int, lora_alpha: int, target_modules: list,
                       a_fill: float, b_fill: float, probe_row: int,
                       probe_col: int) -> dict:
    base = AutoModelForCausalLM.from_pretrained(model_id, dtype=torch.float32)
    config = LoraConfig(task_type="CAUSAL_LM", r=r, lora_alpha=lora_alpha,
                        lora_dropout=0.05, bias="none", target_modules=target_modules)
    peft_model = get_peft_model(base, config)

    layer = peft_model.base_model.model.model.layers[0].self_attn.q_proj
    base_entry = float(layer.base_layer.weight[probe_row, probe_col])

    with torch.no_grad():
        layer.lora_A["default"].weight.fill_(a_fill)
        layer.lora_B["default"].weight.fill_(b_fill)

    merged_model = peft_model.merge_and_unload()
    merged_layer = merged_model.model.layers[0].self_attn.q_proj
    merged_entry = float(merged_layer.weight[probe_row, probe_col])

    adapters_left = sum(1 for _, m in merged_model.named_modules() if hasattr(m, "lora_A"))

    return {
        "base_entry": round(base_entry, 6),
        "merged_entry": round(merged_entry, 6),
        "delta": round(merged_entry - base_entry, 6),
        "adapters_left": adapters_left,
        "merged_params": sum(p.numel() for p in merged_model.parameters()),
    }
```

**Test Cases —** `in.txt`

```
2
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
4
8
2
q_proj
v_proj
0.01
0.02
2
3
trl-internal-testing/small-Qwen2ForCausalLM-2.5
8
24
1
q_proj
0.05
-0.02
5
11
```

**Test Cases —** `out.txt`

```
{'base_entry': 0.128906, 'merged_entry': 0.130506, 'delta': 0.0016, 'adapters_left': 0, 'merged_params': 2428632}
{'base_entry': -0.004089, 'merged_entry': -0.028089, 'delta': -0.024, 'adapters_left': 0, 'merged_params': 38950272}
```

**Grader Notes:**

- **Environment:** needs `transformers`, `peft` and the HF Hub. One model load per case, a few
  hundred KB each, ~1.5 s per case (transformers 5.15.0, peft 0.20.0, torch 2.13.0, Python 3.12.13,
  CPU).
- **The library performs the merge.** `merge_and_unload()` writes the folded weight and strips the
  adapter modules; `base_entry` and `merged_entry` are both read out of the checkpoint's own
  weights, so neither is computable without loading the model. This replaced an earlier version that
  received three tensors as arguments and folded them by hand with `(alpha / r) * (B @ A)` — that
  version exercised `torch` but never `peft`, and never touched a real adapter.
- **Why the fills.** `lora_B` is initialised to zeros, so a freshly wrapped model merges to a no-op
  and every observable would be dtype noise around zero. Filling both matrices with constants makes
  the update exact and reproducible without training anything. `delta` then equals
  `(lora_alpha / r) × r × a_fill × b_fill` — `0.0016` on case 1, `-0.024` on case 2 — which is a
  useful cross-check on the taught formula, but it is only *half* the answer: `base_entry`,
  `merged_entry`, `adapters_left` and `merged_params` all still require the real model.
- **`float32` is specified deliberately.** The checkpoints ship in a 16-bit dtype; merging in that
  dtype quantises the update (case 1's `delta` becomes `0.001953`, a multiple of the bfloat16 step
  at that magnitude, rather than `0.0016`). Step 1 pins 32-bit so the graded values do not depend on
  the checkpoint's storage dtype. Do not relax this.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L4_Fine_Tuning_Existing_Models.md`:
  - Merging as the deployment step, and what it buys — **line 466**: "**Zero inference latency**:
    After training, merge $BA$ back into $W_0$: $W' = W_0 + \frac{\alpha}{r} BA$. The resulting
    model has the exact same architecture and inference speed as the original."
  - The call itself — **line 1508**, verbatim: `merged_model = model_with_adapter.merge_and_unload()`,
    under the comment "After merging, the model is a standard transformer with no adapter overhead"
    (line 1507).
  - Reporting the merged model's type and parameter count — **lines 1510–1511** and their output at
    **lines 1524–1525** (`Merged model type: Qwen2ForCausalLM`, `Total parameters: 1,543,714,304`).
    `"merged_params"` is that second line; it equals the base checkpoint's own count, which is the
    point — the adapters are gone, not absorbed as extra parameters.
  - `AutoModelForCausalLM.from_pretrained` and the `LoraConfig` keywords — **lines 578–583** and
    **848–855**.
  - `lora_A` / `lora_B` as the two injected matrices, reached through
    `layers[0].self_attn.q_proj` — **lines 933–946**, the material's own inspection loop, and the
    printed module dump at **lines 900–914** showing `lora_A`/`lora_B` as `ModuleDict`s keyed
    `default`.
  - **Disclosed, not taught:**
    - Writing values into the adapter matrices. The material trains them; a grader cannot. Step 3
      states the fill plainly and says why.
    - `named_modules()` and `hasattr(m, "lora_A")` as a way to count what survived. The material
      uses `hasattr(module, 'lora_A')` (line 943) but never sweeps `named_modules()`; step 5 asks
      for the count in words. Any route that arrives at 0 is accepted.
    - The post-merge module path. The material never indexes into a merged model, so the Note warns
      that the wrapper prefix is gone rather than leaving it as a silent trap.
- **Determinism.** Every graded value is fixed by the checkpoint, the config and the two fills. Both
  cases re-run byte-identical.
- Compare `"adapters_left"` and `"merged_params"` exactly; the three floats with tolerance `1e-6`.
  Dictionary key order is not significant.
- **What each case is for:**
  - **Case 1** — two adapted modules, a positive update, and the probe inside an adapted projection.
  - **Case 2** — a single adapted module on the wider checkpoint, a **negative** `b_fill`, and a
    different rank and alpha, so no constant scaling passes both.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Skipping the fills** (merging a freshly wrapped model): `delta` 0.0 on both cases,
    `merged_entry` equal to `base_entry` — caught on both.
  - **Dropping the `alpha / r` scaling** (folding `B @ A` unscaled): `delta` 0.0008 / -0.008 against
    0.0016 / -0.024 — caught on both, and the two cases use different `alpha / r` so no single
    factor rescues it.
  - **Reading the probe off the wrapped model after merging** (`base_layer.weight`): raises
    `AttributeError`, since `merge_and_unload` replaced the `lora.Linear` with a plain `Linear`.
    A loud failure, not a silent one.
  - **Reading both entries before the merge**: `delta` 0.0 — caught on both.
  - **Counting adapters on the wrapped model instead of the merged one**: `adapters_left` 2 / 1
    instead of 0 — caught on both, and the two cases differ so a hardcoded 0 is the only thing that
    survives, which `merged_params` then catches.
  - **Loading in the checkpoint's native dtype**: `delta` 0.001953 on case 1 — outside the `1e-6`
    tolerance. This is the reading the `float32` requirement exists to prevent.
- **Overlap check:** Q1 of this file inspects adapters *before* any merge and returns their shapes;
  this question is the other end of the lifecycle and returns weights. The topic-organized bank's
  `prepare_model_for_lora` (`../advanced-ai-agents-coding-ques.md`, Q6) never merges. No shared
  graded value.
- Both cases executed against the reference solution.

---

## Q4: Supervised Fine-Tuning Loss on the Response Tokens Only

**Context:** A supervised fine-tuning example is a single sequence holding a prompt and the response
the model should have produced, and it is trained with the very objective used in pretraining: at
each position the model predicts the following token, and the penalty is the negative log of the
probability it gave the token that actually came next. The one thing that changes is what counts.
The prompt is context, not a target — it flows through the forward pass so the model can condition
on it, but it contributes nothing to the loss. Only the response is scored, which is what teaches a
model to *answer* an instruction rather than to *reproduce* it. Getting that accounting right is the
difference between fine-tuning an assistant and fine-tuning a parrot.

**Problem Statement:**

Using `torch`, write a function `sft_response_loss(logits, prompt_ids, response_ids)`.

1. The training sequence is `prompt_ids` followed by `response_ids`, one token id per element.
2. `logits` holds the model's raw scores for that sequence: one row per position in the sequence,
   one column per vocabulary entry. Row `t` scores the candidates for the token that comes *after*
   position `t`, so the last row's prediction has no target inside the sequence.
3. Score a single prediction with the usual next-token cross-entropy: the negative natural
   logarithm of the softmax probability that row assigned to the token which actually followed.
4. Only the response is scored. The loss has exactly one term per token in `response_ids` — each of
   those tokens, scored at the position that predicts it. Prompt tokens contribute no term of their
   own.
5. Return the mean of those terms, rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: logits (torch_tensor_2d)
    Line 1: R C (rows cols)
    Next R lines: C space-separated values each
  Argument 2: prompt_ids (list_int)
    Line 1: P (list length)
    Line 2: P space-separated integers
  Argument 3: response_ids (list_int)
    Line 1: N (list length)
    Line 2: N space-separated integers
```

**Output Format:**

For each test case, print the result of `sft_response_loss()` on a new line.

**Sample Input:**

```
logits = tensor([[-1.1,  0.0,  1.5, -1.0,  0.3,  0.6,  4.7, -1.1],
                 [ 0.2,  6.3, -0.7,  0.8, -0.7, -0.1,  0.8,  0.0],
                 [-1.2,  0.8,  0.9,  0.8,  1.1,  0.7,  1.0,  4.4],
                 [ 1.0, -1.3,  4.6, -0.2, -0.7,  0.4,  1.1, -1.0],
                 [-0.8, -0.5,  1.2, -1.3,  1.5,  0.9, -0.2, -0.2],
                 [ 0.0,  1.0, -0.1, -0.9, -0.8,  0.2,  0.3, -0.8],
                 [ 0.3, -0.9,  0.0,  0.7,  2.3, -0.4, -0.1,  0.5],
                 [-0.7,  0.1,  1.0,  0.0,  1.0, -1.4, -1.3,  0.4],
                 [ 0.8,  0.9, -1.1,  0.6, -0.3,  0.4,  1.4, -1.5]])
prompt_ids   = [3, 6, 1, 7, 2]
response_ids = [5, 0, 4, 7]
```

**Sample Output:**

```
1.5796
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded and nothing is downloaded: the score matrix stands in for a forward pass that has already
run, and it arrives as a `float32` tensor, so keep the computation in `torch`. How you keep the
prompt positions out of the average is entirely your choice — any approach is fine as long as the
terms that end up counted are the ones step 4 describes. Reading the sample is a useful sanity
check on the accounting: the prompt's own tokens are predicted very confidently here, so a figure
noticeably below the sample's is a sign that positions which should not count are counting.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: sft_response_loss
RETURN TYPE: Float

ARGUMENTS:
1. logits       → Torch 2D Tensor
2. prompt_ids   → List of Ints
3. response_ids → List of Ints
```

(The prompt and the response arrive as two separate lists rather than one sequence plus a boundary
index, which removes any question about where the boundary sits. Token ids must stay integers, so
they come in as `List of Ints` and not as a torch tensor argument — the tensor parser produces
`float32`, which cannot index a vocabulary dimension.)

**Reference Solution:**

```python
import torch


def sft_response_loss(logits: torch.Tensor, prompt_ids: list, response_ids: list) -> float:
    token_ids = prompt_ids + response_ids
    log_probs = torch.log_softmax(logits, dim=-1)
    first = len(prompt_ids) - 1
    terms = [-log_probs[t, token_ids[t + 1]] for t in range(first, len(token_ids) - 1)]
    return round(float(sum(terms) / len(terms)), 4)
```

**Test Cases —** `in.txt`

```
2
9 8
-1.1 0.0 1.5 -1.0 0.3 0.6 4.7 -1.1
0.2 6.3 -0.7 0.8 -0.7 -0.1 0.8 0.0
-1.2 0.8 0.9 0.8 1.1 0.7 1.0 4.4
1.0 -1.3 4.6 -0.2 -0.7 0.4 1.1 -1.0
-0.8 -0.5 1.2 -1.3 1.5 0.9 -0.2 -0.2
0.0 1.0 -0.1 -0.9 -0.8 0.2 0.3 -0.8
0.3 -0.9 0.0 0.7 2.3 -0.4 -0.1 0.5
-0.7 0.1 1.0 0.0 1.0 -1.4 -1.3 0.4
0.8 0.9 -1.1 0.6 -0.3 0.4 1.4 -1.5
5
3 6 1 7 2
4
5 0 4 7
12 10
-0.2 -0.6 5.0 -0.4 1.4 -1.2 -0.6 1.3 0.3 -1.1
0.5 -1.2 0.9 0.2 -0.1 -0.8 -0.8 -0.5 -0.1 3.9
0.4 -1.0 -0.6 -0.9 0.1 4.1 1.2 1.0 1.3 -0.6
-0.1 2.1 -0.5 0.5 0.5 -0.9 -0.1 -1.2 0.6 0.8
0.2 -1.3 -0.6 0.9 -0.7 0.2 -0.2 -0.2 -0.9 -1.3
-0.8 -0.6 1.3 2.9 0.6 0.8 0.5 -0.7 0.7 -0.1
-1.0 -0.2 0.8 -0.2 0.1 0.4 3.5 -1.1 -0.8 0.8
1.4 -0.5 0.9 0.4 1.1 0.6 -0.1 1.2 -0.7 -0.2
0.5 0.8 -1.4 -0.1 1.2 1.4 0.8 3.4 0.4 -1.0
0.3 -0.6 0.1 -1.2 1.5 -0.2 0.5 -1.1 0.5 0.5
0.9 1.1 -0.1 -0.5 -1.2 -0.2 1.2 1.4 -0.5 2.3
-0.8 -0.2 -0.8 -0.5 -1.4 0.2 0.8 0.3 -0.9 0.7
4
8 2 9 5
8
1 6 3 6 0 7 4 9
```

**Test Cases —** `out.txt`

```
1.5796
1.0083
```

**Grader Notes:**

- **Environment:** `torch` only — no model, no download, no GPU, no network. Both cases run in well
  under a second (verified on torch 2.13.0, Python 3.12.13).
- **Confirm the input-format block against the tool's own generated descriptor before publishing.**
  Two layouts need checking. `Torch 2D Tensor` has no prior instance in either bank (see the same
  note on Q3). For `List of Ints` the two banks disagree — one file documents "Line 1: N, Line 2: N
  space-separated integers" and another "Line 1: N, next N lines one value each" — and `in.txt`
  above uses the space-separated form. Either way the parsed lists, and so every expected value,
  are unchanged; only the whitespace in `in.txt` would need reflowing.
- **Compare numerically with tolerance `1e-3`; do not string-match.** The tolerance must stay well
  under `0.026`: the nearest wrong reading (the off-by-one that drops the first response term)
  misses by only `0.0342` on case 1 and `0.0262` on case 2, and a looser tolerance would let it
  through. `1e-3` sits comfortably between that and the float noise.
- **Determinism / dtype.** The parser builds `logits` as `float32`. A `float64` variant was run and
  returns **`1.5796` / `1.0083`, identical**; both values sit ~4.6e-5 from a 4-decimal rounding
  boundary (`1.5796015906` and `1.0082964388`) against a float32-vs-float64 spread of ~6e-8, so the
  4th decimal cannot flip on another machine. Three fresh-process runs and an `OMP_NUM_THREADS=1`
  run all reproduced `out.txt` exactly.
- **The masking mechanism is deliberately left open** — the statement fixes only *which* terms are
  counted, never how they are selected. The following were each implemented and run, and **all six
  return `1.5796` / `1.0083`, byte-identical to the reference**:
  1. Slicing the rows and gathering the targets, then averaging (the reference, written as a
     comprehension; a vectorised `gather` + `.mean()` form was also run).
  2. **The `-100` / `ignore_index` route:** copy the ids into a labels tensor, set
     `labels[:len(prompt_ids)] = -100`, shift (`logits[:-1]` against `labels[1:]`), and call
     `torch.nn.functional.cross_entropy(..., ignore_index=-100)`. Its internal mean over
     non-ignored targets counts exactly `len(response_ids)` terms, which is why it agrees to the
     digit. **This route must be accepted; it must never be required.**
  3. `cross_entropy` on the already-sliced rows and targets, with no sentinel at all.
  4. `torch.softmax` followed by `torch.log`, instead of `torch.log_softmax`.
  5. Building a 0/1 mask over positions, multiplying, and dividing by the mask's sum.
  6. The same computation in `float64`.
- Verified on the shipped cases — each wrong reading below was **implemented and run**:
  - **Scoring every token, prompt included** (no masking at all): `0.8344` / `0.7749` against
    `1.5796` / `1.0083`. Caught on both, and by a wide margin — the logits were built so the
    prompt's own tokens are predicted confidently, which is what separates the two readings
    strongly. This is the single most important wrong reading and both cases catch it.
  - **Off by one, starting too late** — masking through the end of the prompt and so dropping the
    term for the *first* response token, leaving `len(response_ids) - 1` terms: `1.5454` / `1.0345`.
    Caught on both, but this is the **tightest near-miss in the question** (0.034 and 0.026), which
    is what sets the tolerance. Step 4 exists to make this reading indefensible: it fixes the count
    at one term per response token, so the position that predicts the first response token — the
    last prompt position — must count.
  - **Off by one, starting too early** (one extra term whose target is the last prompt token):
    `1.2813` / `0.9197`. Caught on both.
  - **Summing instead of averaging**: `6.3184` / `8.0664`. Caught on both. Worth pinning in step 5,
    because the objective is often written as a sum over positions while the reported training loss
    is a mean; the two cases have 4 and 8 response tokens respectively, so no single divisor
    reconciles them.
  - **Averaging the response terms over the whole sequence length**: `0.702` / `0.6722`. Caught on
    both.
  - **Masking correctly but calling `.mean()` over all positions** (counting the zeroed prompt
    entries in the denominator): `0.7898` / `0.7333`. Caught on both.
  - **No shift** — scoring row `t` against token `t` rather than token `t + 1`: `2.4819` / `3.3153`.
    Caught on both.
  - **Log base 2** instead of the natural log: `2.2789` / `1.4547`. Caught on both.
  - **Softmax over the wrong axis** (`dim=0`, normalising down a column instead of across the
    vocabulary): `2.2161` / `1.4147`. Caught on both.
  - **Negating the raw logit without a softmax**: `-0.9` / `-2.1125`. Caught on both, and the
    negative sign makes it obvious.
  - **Using the final row too**, wrapping its target around to the start of the sequence:
    `1.662` / `1.2497`. Caught on both.
- **Case design.** Case 1 has a 5-token prompt and a 4-token response over an 8-entry vocabulary;
  case 2 a 4-token prompt and an 8-token response over a 10-entry vocabulary. The prompt/response
  split differs in both size and ratio, so a reading that happens to land near the right answer by
  using the wrong denominator on one case cannot do so on the other. Case 1 has the larger
  confident-prompt block and therefore the strongest separation for the no-masking reading; case 2
  has twice as many scored terms and therefore the strongest separation for the sum-versus-mean
  reading.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L4_Fine_Tuning_Existing_Models.md`:
  - The next-token objective `L = -Σ_{t=1}^{T-1} log P(x_{t+1} | x_≤t)` — **line 219**, restated at
    **line 1593**; the per-position form `ℓ = -log(p_y)` at **line 225**, with the worked check
    "p_y = 0.001 → loss = 6.9" at **line 228** fixing the **natural** log.
  - Softmax over the vocabulary — **line 209** (step 5 of the forward pass) and the formula at
    **line 232**.
  - The score matrix's shape, `(seq_len, vocab_size)` — **line 208**.
  - Shift-by-one target construction — the Input/Label table at **lines 240–243** plus "At position
    t, the model sees tokens [x₁, …, x_t] and must predict x_{t+1}" at **line 245**.
  - Taking the **mean** — **line 245** ("computed across all positions simultaneously in one
    forward pass, then averaged"); the run reports one scalar mean, `Final loss: 1.3502`
    (**lines 1131**, **1157**, **1207**).
  - Loss on the response only — **line 251**: "we compute the cross-entropy loss **only on the
    response tokens**, not the instruction tokens. The prompt tokens still pass through the forward
    pass (providing context), but they don't contribute to the gradient." Restated for the
    prompt/completion pair at **line 297** ("The loss is applied only to the completion tokens") and
    at **line 1080** ("computing the loss only on assistant responses").
  - The prompt-and-completion pair as an example's two halves, which is exactly the two-list
    argument shape — **lines 289–297**.
  - `torch` as the tensor library — imported at **line 100**.
  - **Disclosed, not taught:** the source never extracts a logits tensor out of a model and never
    calls a softmax or cross-entropy function — the objective is presented as mathematics and the
    training loop is delegated to a trainer. The score matrix therefore arrives as an argument, and
    step 3 names the reduction in words so no unfamiliar API has to be recalled. Two deliberate
    exclusions: `lm_head` is named once in the source (**line 208**) as the layer that produces the
    logits, and the question neither mentions it nor requires it; and **no sentinel or ignore-index
    convention is required**, since the source never writes one — that route is accepted, not
    demanded (see the open-mechanism bullet above).
- **Overlap check:** nothing else in this file or in `../advanced-ai-agents-coding-ques.md` touches
  the training objective — Q1 and Q2 here are adapter structure and parameter budget, Q3 is the
  merge arithmetic, and the topic-organized bank's nearest neighbours are quantization and
  KV-cache sizing. This is the only question in either bank that computes a loss.
- Both cases executed against the reference solution (Python 3.12.13, torch 2.13.0, CPU).

---

## Q5: From an Alpaca Record to a Rendered Chat Template

**Context:** A supervised fine-tuning example does not reach the model as three database fields. It
is first rewritten as a conversation — a system instruction, the user's turn, the assistant's reply
— and then rendered through the model family's own chat template, which wraps each turn in the
special tokens that family was pretrained to recognise. Only after that rendering does the example
have a token count, and only then can you say where the prompt ends and the response begins, which
is exactly the boundary the training loss is masked on. Getting the rendering wrong is the classic
cause of a fine-tune that trains cleanly and then produces nonsense.

**Problem Statement:**

Using the `transformers` library, write a function
`chat_template_budget(model_id, instruction, input_text, output_text)`.

1. Load the tokenizer for `model_id`.
2. Build the user turn's content from the record's two request fields. When `input_text` carries
   anything other than whitespace, the content is `instruction`, then a blank line, then the literal
   prefix `Input: ` followed by `input_text`; otherwise it is `instruction` alone.
3. Assemble a three-message conversation in this order: a system message whose content is exactly
   `You are a helpful, accurate, and concise assistant.`, then the user message from step 2, then an
   assistant message whose content is `output_text`.
4. Render the conversation to text with the tokenizer's chat template, without tokenizing. Render it
   a second time with the assistant message left out and the template's generation prompt appended —
   this is what the model would be shown at inference, and everything the first rendering has beyond
   it is the part the response occupies.
5. Report the token count of each rendering, and the difference between them.
6. Return a dictionary with exactly these five keys: `"total_tokens"`, `"prompt_tokens"` and
   `"response_tokens"` as integers, `"has_input"` — a boolean, true when step 2 used the input field
   — and `"turns"`, the number of times the template's turn-opening special token appears in the
   full rendering.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: model_id (string)
    Single line: a string
  Argument 2: instruction (string)
    Single line: a string
  Argument 3: input_text (string)
    Single line: a string
  Argument 4: output_text (string)
    Single line: a string
```

**Output Format:**

For each test case, print the result of `chat_template_budget()` on a new line.

**Sample Input:**

```
model_id = "trl-internal-testing/tiny-Qwen2ForCausalLM-2.5"
instruction = "Rearrange the following sentence to make the sentence more interesting."
input_text = "She left the party early"
output_text = "Early, she left the party."
```

**Sample Output:**

```
{'total_tokens': 53, 'prompt_tokens': 44, 'response_tokens': 9, 'has_input': True, 'turns': 3}
```

**Note:** The input handling is already in place — you only need to implement the function. Only the
tokenizer is loaded, never the model, so this costs a few megabytes and no GPU. Count tokens by
tokenizing the rendered strings, not by asking the template to tokenize as it renders — the two
differ on whether special tokens are added a second time. The turn-opening token is whatever this
model family's template uses; read it off the rendering rather than assuming a spelling.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: chat_template_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. model_id    → String
2. instruction → String
3. input_text  → String
4. output_text → String
```

(Five values must come back, so they fold into one `Dictionary`. The three record fields arrive as
separate strings rather than as one `Dictionary` argument so that the blank-input branch is
expressible in a test case.)

**Reference Solution:**

```python
from transformers import AutoTokenizer

SYSTEM_PROMPT = "You are a helpful, accurate, and concise assistant."


def chat_template_budget(model_id: str, instruction: str, input_text: str,
                         output_text: str) -> dict:
    tokenizer = AutoTokenizer.from_pretrained(model_id)

    if input_text.strip():
        user_content = f"{instruction}\n\nInput: {input_text}"
    else:
        user_content = instruction

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": user_content},
        {"role": "assistant", "content": output_text},
    ]

    full = tokenizer.apply_chat_template(messages, tokenize=False)
    prompt = tokenizer.apply_chat_template(messages[:2], tokenize=False,
                                           add_generation_prompt=True)

    total_tokens = len(tokenizer(full).input_ids)
    prompt_tokens = len(tokenizer(prompt).input_ids)

    return {
        "total_tokens": total_tokens,
        "prompt_tokens": prompt_tokens,
        "response_tokens": total_tokens - prompt_tokens,
        "has_input": bool(input_text.strip()),
        "turns": full.count("<|im_start|>"),
    }
```

**Test Cases —** `in.txt`

```
2
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
Rearrange the following sentence to make the sentence more interesting.
She left the party early
Early, she left the party.
trl-internal-testing/tiny-Qwen2ForCausalLM-2.5
Give three tips for staying healthy.
 
Eat well, move daily, and sleep enough.
```

**Test Cases —** `out.txt`

```
{'total_tokens': 53, 'prompt_tokens': 44, 'response_tokens': 9, 'has_input': True, 'turns': 3}
{'total_tokens': 43, 'prompt_tokens': 31, 'response_tokens': 12, 'has_input': False, 'turns': 3}
```

**Grader Notes:**

- **Environment:** needs `transformers` and the HF Hub, tokenizer files only — no weights, no GPU.
  Verified at well under a second per case (transformers 5.15.0, Python 3.12.13).
- **The library produces the graded value.** The token counts are the output of this model family's
  own Jinja chat template plus its BPE tokenizer; nothing about `<|im_start|>` placement, the
  `<|im_end|>` terminators or the generation prompt is derivable from the input strings. The
  checkpoint carries the **same tokenizer as the material's own `Qwen/Qwen2.5-1.5B`** — vocabulary
  size 151,665, matching the `Vocabulary size: 151,665` the material prints at line 571 — so the
  rendering a learner sees here is byte-identical to the one the lecture shows, at none of the
  download cost.
- **This question is new.** The dataset-preparation half of this material had no coverage: the other
  four questions in this file are all on the LoRA and loss side.
- **Scope trace** — every construct traces to
  `modules/02-advanced-ai-agents/markdown/L4_Fine_Tuning_Existing_Models.md`:
  - The Alpaca record's three fields and the conversational target format — **lines 263–285**
    (§1.3), and the conversion itself at **lines 763–790** (`format_alpaca_to_chat`), whose
    `if example.get("input") and example["input"].strip():` branch is step 2 and whose system
    content is step 3's pinned string, verbatim.
  - The blank-line-then-`Input: ` join — **line 780**:
    `user_content = f"{example['instruction']}\n\nInput: {example['input']}"`.
  - Rendering with the template — **line 824**:
    `rendered = tokenizer.apply_chat_template(sample["messages"], tokenize=False)`, and its printed
    output at **lines 832–839**, which is exactly case 1's conversation (same instruction, same
    input, same output) rendered with `<|im_start|>system` / `<|im_start|>user` /
    `<|im_start|>assistant`. Case 1 reproduces the material's own worked example.
  - `add_generation_prompt=True` for the inference-time rendering — **line 151**
    (`generate_response` builds its prompt that way).
  - `AutoTokenizer.from_pretrained(MODEL_NAME)` — **line 529**.
  - Why the prompt/response split matters — **line 251**: the loss is computed "**only on the
    response tokens**", and **line 1080**: `SFTTrainer` "computing the loss only on assistant
    responses". `"response_tokens"` is the size of exactly that masked region.
  - **Disclosed, not taught:** counting tokens of a rendered string. The material renders and prints
    but never counts; step 5 asks for the counts in words. Also the `tokenize=False`-then-tokenize
    route — passing `tokenize=True` re-adds nothing here but is a different call path, so the Note
    pins the order rather than leaving two readings live.
- **Determinism.** Tokenizer output is a pure function of the vocabulary and the template, both
  frozen in the checkpoint. Both cases re-run byte-identical. Pin `transformers` and re-check if the
  checkpoint's `chat_template` is ever revised — the counts are template-derived, and that is the one
  thing a repo update could move.
- Compare all five values exactly. Dictionary key order is not significant.
- **What each case is for:**
  - **Case 1** — the input field is populated, so the blank-line join is exercised; it is also the
    material's own printed example, so the expected rendering can be read straight off line 832.
  - **Case 2** — the input field is **blank**, so the other branch runs and `has_input` is `False`.
    A solution that always joins produces `total_tokens` 47 and `prompt_tokens` 35 here.
    **Case 2 must stay in any shipped subset.**
- **The blank field is written as a single space, deliberately.** A truly empty line risks being
  consumed differently by the portal's string parser than by a local harness. A space is
  unambiguous either way, and the solution's `.strip()` sends both spellings down the same branch —
  verified by running the case with `""` and with `" "` and diffing: identical output.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Always appending the input field**: case 2 gives 47 / 35 / 12 against 43 / 31 / 12 — caught
    by case 2 only.
  - **Omitting `add_generation_prompt`**: `prompt_tokens` 41 / 28, so `response_tokens` becomes
    12 / 15 — caught on both.
  - **Rendering all three messages for the prompt too**: `response_tokens` 0 on both — caught.
  - **Counting with `apply_chat_template(..., tokenize=True)` on the full conversation**: matches
    `total_tokens` here, so it is an accepted route for that value; it is the *prompt* rendering
    where the two diverge, and step 4 pins that one.
  - **Using a different system string**: shifts both counts by the difference in system-prompt
    length; case 1's 53 is only reachable with the pinned sentence, which is why step 3 quotes it.
  - **Counting `<|im_end|>` instead of `<|im_start|>`**: also 3 here, so `"turns"` alone does not
    separate them — this key is corroborating evidence, not a discriminator, and the notes say so
    rather than pretending otherwise.
- **Overlap check:** Q4 of this file consumes a prompt/response split as two ready-made id lists and
  computes a loss over it; this question *produces* that split from a raw record and never computes
  a loss. Together they cover the two ends of the same boundary. Nothing in the topic-organized bank
  touches chat templates.
- Both cases executed against the reference solution.
