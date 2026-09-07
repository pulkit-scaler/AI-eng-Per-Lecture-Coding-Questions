# Module 3, Lecture 19 — Diffusion Models Fundamentals

Seven coding questions. Q1 and Q2 cover the two halves of the diffusion loop: the **forward**
process (walking a clean sample up the noise ladder in one hop, from the cumulative β-schedule) and
the **reverse** process (a DDIM sampling loop driven by a classifier-free-guidance blend of the
prompt and negative-prompt branches). Q5 covers the sinusoidal time embedding that tells one U-Net
where on the ladder it currently is, Q6 what the choice of noise schedule actually buys (linear
against cosine, measured), and Q7 where a U-Net's parameters actually sit — encoder against decoder,
which is where the skip connections become visible.

> **Which of these are live.** The notebook
> [`Coding_Ques_Module_3_Agentic_AI_Systems.ipynb`](Coding_Ques_Module_3_Agentic_AI_Systems.ipynb)
> currently carries **Q5, Q6 and Q7** (as its Questions 15, 16 and 17 — the notebook was renumbered
> continuously from Q1 on 2026-08-27, and again on 2026-08-31 when its Class-13 prompt-rendering
> question was removed, shifting everything from 13 on down by one). An earlier Q7, `step_budget_cost`, was **superseded on
> 2026-08-27**: it measured the same √ᾱ quantity over an inference schedule that `M3-L20` Q5 already
> measures, making four of the day's questions scheduler questions. It was replaced by the U-Net
> profile above, which grades a different part of the model entirely. **Q3** (CLIP's 77-token
> prompt budget) and **Q4** (the seeded latent canvas) were **cut by the author on 2026-08-27** — they
> graded bookkeeping around the model (token counts, RNG fingerprints, shape arithmetic) rather than a
> value the diffusion process itself produces. They are kept here as a record, not as candidates; do
> not reinstate either without asking. Q1 and Q2 live only in this file.

> **Scope note.** Q1 and Q2 were written against the pre-recording brief in
> [`modules/03-agentic-ai-systems/FUTURE_CLASSES.md`](../../../modules/03-agentic-ai-systems/FUTURE_CLASSES.md)
> ("Difussion Models Fundamentals") and stay inside it — forward diffusion, reverse/denoising,
> DDPM, DDIM (faster sampling), the Hugging Face **Diffusers** library, guidance scale, negative
> prompts, sampling steps, schedulers, and fixed noise for reproducibility. The material has since
> been recorded as `modules/03-agentic-ai-systems/markdown/L18_Diffusion_Models_Lecture.md`
> (theory) and `L18_Diffusion_Models_Lecture_2.md` (the `diffusers`/SDXL build), which is what
> **Q3–Q5 trace to, line by line, in their grader notes**. This file is curriculum position 19;
> the class tag in
> [`Coding_Ques_Module_3_Agentic_AI_Systems.ipynb`](Coding_Ques_Module_3_Agentic_AI_Systems.ipynb)
> is `[Class 18]`, off the markdown filename. No question here needs a GPU or model weights; Q1, Q2,
> Q4 and Q5 need no network at all, and Q3 fetches only a 1.7 MB tokenizer vocabulary.

---

## Q1: Jump to Any Point on the Forward Diffusion Ladder

**Context:** The forward diffusion process destroys an image by adding a little Gaussian noise at
a time, over hundreds or thousands of timesteps, following a **variance schedule** `β₁…β_T`.
Training never walks that ladder one rung at a time, though — because the per-step noise is
Gaussian, the whole prefix collapses into a closed form, so `x_t` can be produced from `x₀` in a
single hop using the **cumulative** product of the schedule. That one shortcut is what makes
training a diffusion model affordable: pick a random timestep, jump straight to it, and ask the
model to predict the noise you added.

**Problem Statement:**

Using the `diffusers` library, write a function
`forward_diffuse(x0, noise, timesteps, num_train_timesteps, beta_start, beta_end)`.

1. Build a DDPM noise schedule with `diffusers.DDPMScheduler`, configured with the given
   `num_train_timesteps`, `beta_start`, `beta_end`, and a **linear** beta schedule. Leave every
   other scheduler setting at its default.
2. `x0` is one clean flattened sample and `noise` is one Gaussian noise vector of the same
   length. The **same** noise vector is reused for every timestep — this is what makes the run
   reproducible, the role a fixed seed plays in a real pipeline.
3. `timesteps` holds 0-based indices into that schedule. For each one, in the order given,
   produce the noisy sample `x_t` **directly from `x0` in a single hop** (the closed form of the
   forward process, which uses the cumulative schedule up to `t`) — not by looping `t` times.
4. Return a dictionary whose key is the timestep (an integer) and whose value is the list of that
   `x_t`'s values, in the same positional order as `x0`, each rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: x0 (numpy_1d_array)
    Line 1: L (array length)
    Line 2: L space-separated floats
  Argument 2: noise (numpy_1d_array)
    Line 1: L (array length)
    Line 2: L space-separated floats
  Argument 3: timesteps (list_int)
    Line 1: M (list length)
    Line 2: M space-separated integers
  Argument 4: num_train_timesteps (integer)
    Single line: one integer
  Argument 5: beta_start (float)
    Single line: one float
  Argument 6: beta_end (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `forward_diffuse()` on a new line.

**Sample Input:**

```
x0 = np.array([0.8, -0.4, 0.15, 0.6])
noise = np.array([0.5, 1.2, -0.7, -1.1])
timesteps = [0, 100, 500, 999]
num_train_timesteps = 1000
beta_start = 0.0001
beta_end = 0.02
```

**Sample Output:**

```
{0: [0.805, -0.388, 0.143, 0.589], 100: [0.9188, 0.0101, -0.0848, 0.2115], 500: [0.7033, 1.0408, -0.6304, -0.889], 999: [0.5051, 1.1974, -0.699, -1.0962]}
```

**Note:** The input handling is already in place — you only need to implement the function.
`diffusers` schedulers work on `torch` tensors, so convert `x0` and `noise` before handing them
over, and convert back to plain Python floats when you build the returned dictionary. Read the
sample output as a sanity check on the schedule: at `t = 0` the result is still essentially the
clean sample, and by `t = 999` it is essentially the noise.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: forward_diffuse
RETURN TYPE: Dictionary

ARGUMENTS:
1. x0                  → Numpy 1D Array
2. noise               → Numpy 1D Array
3. timesteps           → List of Ints
4. num_train_timesteps → Integer
5. beta_start          → Float
6. beta_end            → Float
```

(`num_train_timesteps`, `beta_start` and `beta_end` are all defaulted in `DDPMScheduler`
(1000 / 0.0001 / 0.02) — they are required arguments here because the tool supports no argument
defaults, and making them explicit is also what catches a hardcoded 1000. The return is a
`Dictionary` of timestep → list of floats: a per-timestep stack of vectors is a 2D result, and
`Numpy 2D Array` would print as a multi-line repr, which the one-line-per-test-case output format
cannot carry.)

**Reference Solution:**

```python
import numpy as np
import torch
from diffusers import DDPMScheduler


def forward_diffuse(x0: np.ndarray, noise: np.ndarray, timesteps: list,
                    num_train_timesteps: int, beta_start: float, beta_end: float) -> dict:
    scheduler = DDPMScheduler(
        num_train_timesteps=num_train_timesteps,
        beta_start=beta_start,
        beta_end=beta_end,
        beta_schedule="linear",
    )
    x0_t = torch.tensor(np.asarray(x0), dtype=torch.float32)
    noise_t = torch.tensor(np.asarray(noise), dtype=torch.float32)

    out = {}
    for t in timesteps:
        x_t = scheduler.add_noise(x0_t, noise_t, torch.tensor([int(t)]))
        out[int(t)] = [round(float(v), 4) for v in x_t]
    return out
```

**Test Cases —** `in.txt`

```
2
4
0.8 -0.4 0.15 0.6
4
0.5 1.2 -0.7 -1.1
4
0 100 500 999
1000
0.0001
0.02
5
0.25 -0.9 0.4 1.05 -0.15
5
-1.3 0.6 0.9 -0.2 1.4
3
10 50 199
200
0.001
0.05
```

**Test Cases —** `out.txt`

```
{0: [0.805, -0.388, 0.143, 0.589], 100: [0.9188, 0.0101, -0.0848, 0.2115], 500: [0.7033, 1.0408, -0.6304, -0.889], 999: [0.5051, 1.1974, -0.699, -1.0962]}
{10: [0.0444, -0.7955, 0.5353, 1.006, 0.07], 50: [-0.5121, -0.4169, 0.8316, 0.7633, 0.6507], 199: [-1.2777, 0.5311, 0.9274, -0.121, 1.3849]}
```

**Grader Notes:**

- **Scope trace (added 2026-08-27, after the material was recorded).** The closed-form one-hop
  forward process this question grades is stated verbatim at
  `modules/03-agentic-ai-systems/markdown/L18_Diffusion_Models_Lecture.md:966`, with ᾱ_t explained
  as "a number between 0 and 1" at `:969`; the noise schedule is `:422`, the **Linear** schedule is
  named at `:428`, and β magnitudes "like 0.0001" at `:957`. `diffusers` as the library supplying
  these pieces: `L18_Diffusion_Models_Lecture_2.md:237`. **Disclosed, not taught:** `DDPMScheduler`
  and `add_noise` appear in **none** of the four diffusion files — the material only ever reaches a
  scheduler inside a loaded pipeline — so the statement names both explicitly. The arithmetic they
  perform is exactly the taught equation, and the accepted-equivalent note below confirms a
  hand-rolled `np.cumprod` version scores identically, so nothing here depends on knowing the API.
- Both cases were **executed** against the reference solution (Python 3.12, `torch` 2.13.0,
  `diffusers` 0.39.0, `numpy` 2.5.1); the `out.txt` above is real program output.
- Compare **structurally**: dictionary key order is not graded, and the list values are compared
  element-by-element with float tolerance **`1e-4`**.
- **Case 2 is the only case that catches a hardcoded `num_train_timesteps=1000`** — case 1's
  schedule *is* 1000 steps, so hardcoding passes it. Never drop case 2. Case 2 also varies
  `beta_start`/`beta_end` (0.001 / 0.05), the vector length (5), and includes `t = 199 = T-1`, the
  top rung of a 200-step ladder.
- **Accepted equivalent:** a hand-rolled closed form
  (`np.linspace(beta_start, beta_end, num_train_timesteps)` → `np.cumprod(1 - beta)` →
  `sqrt(ᾱ_t)·x0 + sqrt(1-ᾱ_t)·noise`) was run in both `float32` and `float64` and reproduces the
  reference **exactly** (max abs diff `0.0`) on both cases. Grade the returned values, not the
  route: `scheduler.add_noise` and the hand-rolled form are both correct. Batched `add_noise`
  calls (tiling `x0`/`noise` and passing all timesteps at once) are likewise equivalent.
- Wrong readings, each **implemented and run** — all differ from the reference on **both** cases:
  - dropping the `sqrt(ᾱ_t)` factor on the signal (`x0 + sqrt(1-ᾱ_t)·noise`);
  - swapping the two coefficients (`sqrt(1-ᾱ_t)·x0 + sqrt(ᾱ_t)·noise`);
  - using the **per-step** `α_t`/`β_t` instead of the cumulative `ᾱ_t` (i.e. treating one rung as
    the whole climb);
  - `beta_schedule="scaled_linear"` (Stable Diffusion's schedule) instead of `"linear"`.
- `beta_schedule="linear"` is `DDPMScheduler`'s own default, so a solution that omits the argument
  is identical to the reference. It is named in the statement because the *value* is graded, and
  the SD-flavoured `"scaled_linear"` is the plausible wrong pick.
- **Untested edges, deliberately:** an empty `timesteps` list and a repeated timestep are both
  unspecified in the statement, so no case may depend on them (an empty list would return `{}`, a
  repeat would silently collapse to one key).
- The statement fixes "same noise vector for every timestep" because it is the difference between
  a reproducible answer and an unreproducible one — a learner who draws fresh noise per timestep
  cannot match any expected output.

---

## Q2: DDIM Sampling with Classifier-Free Guidance and a Negative Prompt

**Context:** At inference a text-to-image model runs the U-Net **twice** per step: once
conditioned on the prompt and once on the negative prompt (an empty string, if none is given).
Classifier-free guidance then blends the two predictions, pushing the sample away from what the
negative branch predicts and towards the prompt — the `guidance_scale` slider exposed in every
Stable Diffusion UI. DDIM makes the reverse process cheap by walking only a strided subsequence
of the training timesteps (say 20 or 50 of 1000) and, at `eta = 0`, doing it deterministically:
same starting latent, same trace, same image. Because the two U-Net calls are the only expensive
part, a **captured trace** of their outputs is enough to test the sampling loop itself on a CPU.

**Problem Statement:**

Using the `diffusers` library, write a function
`guided_ddim_sample(latent, cond_noise_preds, uncond_noise_preds, guidance_scale, num_inference_steps, num_train_timesteps)`.

1. Build `diffusers.DDIMScheduler` with the given `num_train_timesteps` and with
   `clip_sample=False` (matching Stable Diffusion's own scheduler config). Leave every other
   scheduler setting at its default.
2. Ask the scheduler for an inference schedule of `num_inference_steps` timesteps — the strided
   subsequence of training timesteps that DDIM actually visits, walked from the noisiest to the
   cleanest — and iterate over it in that order.
3. `latent` is the starting (fully noisy) latent. `cond_noise_preds` and `uncond_noise_preds` hold
   one row per step of that inference schedule, in the same order: row `i` is the recorded
   noise prediction at the `i`-th timestep for the **prompt** branch and for the
   **negative-prompt (unconditional)** branch respectively.
4. At each step, combine the two rows into a single guided noise prediction: **start from the
   negative-prompt branch's prediction and move `guidance_scale` times the gap from it to the
   prompt branch's prediction.**
5. Hand that guided prediction, together with the current timestep and the current latent, to the
   scheduler to obtain the previous (less noisy) latent, and continue the loop from there.
6. Return the final latent as a 1D array of floats, rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: latent (numpy_1d_array)
    Line 1: D (array length)
    Line 2: D space-separated floats
  Argument 2: cond_noise_preds (numpy_2d_array)
    Line 1: N D (number of rows, dimension)
    Next N lines: D space-separated floats
  Argument 3: uncond_noise_preds (numpy_2d_array)
    Line 1: N D (number of rows, dimension)
    Next N lines: D space-separated floats
  Argument 4: guidance_scale (float)
    Single line: one float
  Argument 5: num_inference_steps (integer)
    Single line: one integer
  Argument 6: num_train_timesteps (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `guided_ddim_sample()` on a new line.

**Sample Input:**

```
latent = np.array([1.1, -0.6, 0.3, -1.4])
cond_noise_preds = np.array([[ 1.0767, -0.8237,  0.4769, -0.6898],
                             [ 1.4323,  0.1828,  0.2162, -2.4298],
                             [ 1.4616, -0.1067, -0.1190, -1.6628],
                             [ 0.9954,  0.1351,  0.2859, -1.9268]])
uncond_noise_preds = np.array([[ 1.0765, -0.8595,  0.5098, -0.5829],
                               [ 1.4869,  0.3018,  0.2090, -2.5907],
                               [ 1.5206, -0.0322, -0.1778, -1.7057],
                               [ 0.9828,  0.2468,  0.2894, -2.0103]])
guidance_scale = 7.5
num_inference_steps = 4
num_train_timesteps = 1000
```

**Sample Output:**

```
[ 0.4154 -0.1744  0.6507 -0.3094]
```

**Note:** The input handling is already in place — you only need to implement the function. The
two prediction arrays stand in for the U-Net's two forward passes, so no model is loaded and
nothing is downloaded. `diffusers` schedulers work on `torch` tensors — convert on the way in, and
convert the final latent back to a NumPy array on the way out. DDIM's default `eta = 0` makes the
loop deterministic, so no generator or seed is needed.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: guided_ddim_sample
RETURN TYPE: Numpy 1D Array

ARGUMENTS:
1. latent              → Numpy 1D Array
2. cond_noise_preds    → Numpy 2D Array
3. uncond_noise_preds  → Numpy 2D Array
4. guidance_scale      → Float
5. num_inference_steps → Integer
6. num_train_timesteps → Integer
```

(`guidance_scale` (7.5 in most pipelines) and `num_inference_steps` (50) are defaulted in the real
pipeline API — required here, since the tool supports no argument defaults.)

**Reference Solution:**

```python
import numpy as np
import torch
from diffusers import DDIMScheduler


def guided_ddim_sample(latent: np.ndarray, cond_noise_preds: np.ndarray,
                       uncond_noise_preds: np.ndarray, guidance_scale: float,
                       num_inference_steps: int, num_train_timesteps: int) -> np.ndarray:
    scheduler = DDIMScheduler(num_train_timesteps=num_train_timesteps, clip_sample=False)
    scheduler.set_timesteps(num_inference_steps)

    lat = torch.tensor(np.asarray(latent), dtype=torch.float32)
    cond = torch.tensor(np.asarray(cond_noise_preds), dtype=torch.float32)
    uncond = torch.tensor(np.asarray(uncond_noise_preds), dtype=torch.float32)

    for i, t in enumerate(scheduler.timesteps):
        noise_pred = uncond[i] + guidance_scale * (cond[i] - uncond[i])
        lat = scheduler.step(noise_pred, t, lat).prev_sample

    return np.round(lat.numpy().astype(np.float64), 4)
```

**Test Cases —** `in.txt`

```
2
4
1.1 -0.6 0.3 -1.4
4 4
1.0767 -0.8237 0.4769 -0.6898
1.4323 0.1828 0.2162 -2.4298
1.4616 -0.1067 -0.119 -1.6628
0.9954 0.1351 0.2859 -1.9268
4 4
1.0765 -0.8595 0.5098 -0.5829
1.4869 0.3018 0.209 -2.5907
1.5206 -0.0322 -0.1778 -1.7057
0.9828 0.2468 0.2894 -2.0103
7.5
4
1000
3
-0.9 1.7 0.25
6 3
-0.9804 1.2791 -0.2572
-0.7626 1.9422 0.4437
-1.1946 1.8455 -0.066
-0.2278 1.1964 0.2713
-1.2388 1.8777 0.3844
-1.1519 1.4932 0.3137
6 3
-0.9872 1.0072 -0.5021
-0.6605 2.0018 0.5491
-1.3085 1.8567 -0.2154
0.1417 0.8831 0.2906
-1.3749 1.905 0.4602
-1.2446 1.3283 0.3542
3
6
500
```

**Test Cases —** `out.txt`

```
[ 0.4154 -0.1744  0.6507 -0.3094]
[ 0.3005 -0.5496  0.12  ]
```

**Grader Notes:**

- **Scope trace (added 2026-08-27, after the material was recorded).** Classifier-free guidance as
  "unconditional + guidance strength × (conditional − unconditional)" is
  `modules/03-agentic-ai-systems/markdown/L18_Diffusion_Models_Lecture.md:1630`–`:1646`, with "we
  run the U-Net twice" at `:1613` and `guidance_scale = 7.5` at `:1678`. The negative prompt filling
  the unconditional branch is `L18_Diffusion_Models_Lecture_2.md:461`–`:465`. DDIM's
  estimate-x̂₀-then-jump is `L18_Diffusion_Models_Lecture.md:1358` and `:1382`, its determinism at
  σ_t = 0 is `:1410`, step-skipping is `:1256`–`:1312`, and "20 and 50 sampling steps" is `:1448`.
- **Two pieces of this question's scheduler config are NOT in Class 18's own material.**
  `DDIMScheduler` and `clip_sample` appear only in Class 19's
  `L19_Advanced_Diffusion_Part_2.md:811` and `:839` (the AnimateDiff pipeline), and
  `set_timesteps` / `step` / `prev_sample` appear in no diffusion file at all. Both are named
  explicitly in the statement, so the question stays solvable from the statement plus the taught
  equations — and per the note further down, `clip_sample` is a verified no-op on both cases, so a
  learner who omits it still scores. Treat all of it as **disclosed, not taught** rather than as
  assumed knowledge, and do not add a case that makes `clip_sample` load-bearing without moving
  that disclosure into the statement's own steps.
- Both cases were **executed** against the reference solution (Python 3.12, `torch` 2.13.0,
  `diffusers` 0.39.0, `numpy` 2.5.1); the `out.txt` above is real program output. Compare
  numerically with tolerance **`1e-4`**.
- **The traces are synthetic but not arbitrary.** Each row was constructed so the guided
  prediction is exactly the epsilon that steers the current latent toward a fixed clean target,
  which is why the correct answer converges to a plausible latent
  (`[0.4154, -0.1744, 0.6507, -0.3094]` for case 1) instead of blowing up. Do not regenerate the
  traces with random numbers: with `guidance_scale = 7.5`, unstructured rows send the final latent
  into the tens, which looks broken and hides genuine errors in the noise.
- **Step 4's wording is load-bearing: two conventions for the CFG scale exist in the wild.**
  `uncond + s·(cond − uncond)` (the `diffusers` pipelines' form, required here) and
  `(1 + w)·cond − w·uncond` (the form used in parts of the literature) differ by 1 in the scale;
  implemented and run, the second gives `[0.6041, -0.3059, 1.0356, 0.739]` on case 1, a max abs
  difference of **1.0484**. The statement therefore pins the combination in words. If a learner
  disputes a mark here, this note is the answer: the required convention is stated, not implied.
- Wrong readings, each **implemented and run** — all differ from the reference on **both** cases:
  - swapping the branches (`cond + s·(uncond − cond)`) — i.e. guiding *toward* the negative prompt;
  - using the prompt branch alone (no guidance at all);
  - `noise_pred = guidance_scale * cond[i]` (scaling instead of extrapolating);
  - iterating the inference schedule **ascending** (cleanest → noisiest) instead of descending.
- **Case 2 is the only case that catches a hardcoded `num_train_timesteps=1000`**; case 1's value
  *is* 1000. Case 2 also uses a different guidance scale (3.0), a different step count (6, whose
  stride 500//6 = 83 gives the non-round schedule `[415, 332, 249, 166, 83, 0]`), and a different
  latent width (3). Never drop case 2.
- **Scheduler config is graded, and three defaults matter.** Verified on case 1: `steps_offset=1`
  (Stable Diffusion's own config value, a plausible habit) shifts the schedule to
  `[751, 501, 251, 1]` and gives `[0.4181, -0.1755, 0.6556, -0.3112]`; `set_alpha_to_one=False`
  gives `[0.4261, -0.1803, 0.6533, -0.3232]`; `beta_schedule="scaled_linear"` gives
  `[0.2195, -0.1047, 0.2151, -0.2161]`. This is why the statement says to set only
  `num_train_timesteps` and `clip_sample`, leaving the rest at their defaults.
- **`clip_sample` is a no-op on these two cases** — the predicted `x₀` never leaves `[-1, 1]`, so
  leaving the default `True` in place returns byte-identical output. It is still named in the
  statement because it is data-dependent (it is *not* a no-op in the L20 inpainting question), and
  because SD's config sets it. Do **not** mark down a solution that omits it, and do not treat
  this pair of cases as testing it.
- **Accepted equivalent:** a hand-rolled DDIM step
  (`pred_x0 = (x_t − sqrt(1−ᾱ_t)·ε) / sqrt(ᾱ_t)`, then
  `x_prev = sqrt(ᾱ_prev)·pred_x0 + sqrt(1−ᾱ_prev)·ε`, with `ᾱ_prev = 1` at the last step) was run
  in `float64` NumPy against both cases and reproduces the reference **exactly** (max abs diff
  `0.0`). Grade the returned values, not the route.
- Requires outbound network access **only** for `pip install diffusers` at image-build time — no
  weights are fetched at run time. `DDPMScheduler`/`DDIMScheduler` are pure-math classes; the
  grader environment needs `torch` + `diffusers` + `numpy` and nothing else.

---

## Q3: Fitting a Layered Prompt Inside CLIP's Token Budget

**Context:** A text-to-image pipeline never reads a prompt as text — a CLIP text encoder turns it
into an embedding first, and that encoder has a hard ceiling of **77 tokens**. Everything past the
ceiling is silently dropped, so on a long prompt the last thing the writer added is often the first
thing the model never sees. Prompts are normally layered — subject, then setting, then style, then
lighting, then quality tags — which means a useful budget check reports not just "too long" but
*which layers actually made it in*.

**Problem Statement:**

Using the `transformers` library, write a function `prompt_token_budget(clauses, token_limit)`.

1. Load the CLIP tokenizer that Stable Diffusion pipelines use for their text encoder:
   `CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")`.
2. `clauses` holds the prompt's layers in the order they would be written. The full prompt is those
   clauses joined with `", "` — a comma and a space.
3. Count tokens the way the encoder counts them: the length of the tokenizer's own `input_ids` for
   the string, exactly as the tokenizer returns them for that string.
4. Find how many *leading* clauses survive the budget — the largest number `k` (possibly `0`) such
   that the prompt built from only the first `k` clauses, joined the same way, comes to at most
   `token_limit` tokens.
5. Return a dictionary with exactly these four keys:
   - `"total_tokens"` — the token count of the full prompt
   - `"kept_clauses"` — `k`
   - `"dropped_clauses"` — how many clauses fall outside the budget
   - `"kept_tokens"` — the token count of the prompt built from the first `k` clauses

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: clauses (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 2: token_limit (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `prompt_token_budget()` on a new line.

**Sample Input:**

```
clauses = ["a golden retriever playing in the snow",
           "pine forest background",
           "watercolor painting style",
           "soft morning light",
           "highly detailed",
           "4k"]
token_limit = 77
```

**Sample Output:**

```
{'total_tokens': 27, 'kept_clauses': 6, 'dropped_clauses': 0, 'kept_tokens': 27}
```

**Note:** Load the tokenizer once at module level, outside the function, so it is not rebuilt on
every call. All four values are plain Python integers.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: prompt_token_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. clauses     → List of Strings
2. token_limit → Integer
```

(`token_limit` is the model's own constant (77) rather than a parameter anyone passes in a real
pipeline — it is an explicit argument here because the tool supports no argument defaults, and
making it explicit is also what catches a hardcoded 77.)

**Reference Solution:**

```python
from transformers import CLIPTokenizer

clip_tokenizer = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")


def prompt_token_budget(clauses: list, token_limit: int) -> dict:
    def n_tokens(text: str) -> int:
        return len(clip_tokenizer(text)["input_ids"])

    kept, kept_tokens = 0, n_tokens("")
    for k in range(1, len(clauses) + 1):
        size = n_tokens(", ".join(clauses[:k]))
        if size > token_limit:
            break
        kept, kept_tokens = k, size

    return {"total_tokens": n_tokens(", ".join(clauses)),
            "kept_clauses": kept,
            "dropped_clauses": len(clauses) - kept,
            "kept_tokens": kept_tokens}
```

**Test Cases —** `in.txt`

```
3
6
a golden retriever playing in the snow
pine forest background
watercolor painting style
soft morning light
highly detailed
4k
77
9
realistic vibrant orange mango juice completely filling the inside of the transparent plastic glass
bright saturated orange-yellow liquid
clearly visible liquid surface line near the top of the masked region
glossy reflections and light refraction through the transparent plastic
distinct color contrast between the liquid and the empty jug
believable high juice level
photorealistic
natural studio lighting
preserve the exact shape and structure of the glass
77
6
a golden retriever playing in the snow
pine forest background
watercolor painting style
soft morning light
highly detailed
4k
25
```

**Test Cases —** `out.txt`

```
{'total_tokens': 27, 'kept_clauses': 6, 'dropped_clauses': 0, 'kept_tokens': 27}
{'total_tokens': 81, 'kept_clauses': 8, 'dropped_clauses': 1, 'kept_tokens': 71}
{'total_tokens': 27, 'kept_clauses': 5, 'dropped_clauses': 1, 'kept_tokens': 24}
```

**Grader Notes:**

- **Scope trace.** The 77-token ceiling and the truncation behaviour:
  `L18_Diffusion_Models_Lecture_2.md:393`. The layered prompt order and the golden-retriever
  example the sample input reuses: `:396`–`:417`. CLIP as the pipeline's own tokenizer/text
  encoder: `:224`–`:228` and the printed component list at `:309`. **Disclosed, not taught:**
  building a `CLIPTokenizer` standalone — the material only ever reaches the tokenizer through a
  loaded pipeline, so the checkpoint id is given in the statement.
- All three cases were **executed** against the reference solution through a portal-style stdin
  harness (Python 3.12.13, `transformers` 5.15.0, `tokenizers` from that build); the `out.txt`
  above is real program output. Values are exact integers — compare them exactly, and dictionary
  key order is not graded.
- **Case 2 reproduces a figure the source material prints.** Its nine clauses are the inpainting
  prompt from `L19_Advanced_Diffusion.md:276`–`:282`, whose own recorded output is
  `The following part of your input was truncated because CLIP can only handle sequences up to 77
  tokens: ['structure of the glass']` (`:316`). The reference agrees: the prompt is 81 tokens, the
  first eight clauses fit in 71, and the ninth — the one ending in "structure of the glass" — is the
  one that does not fit **entirely**. Note that CLIP truncates at the token level, mid-clause: the
  recorded message shows only the tail of that ninth clause being dropped, not the whole clause. The
  question deliberately reports the stricter clause-level budget (how many layers survive intact),
  which is the number a writer needs when deciding what to cut. Do not let a future edit restate
  this as "CLIP drops whole clauses".
- **Case 3 is the only case that catches a hardcoded `77`** in place of `token_limit`. Never drop
  it.
- **Case 2 is the only case that catches counting with truncation on**
  (`tokenizer(text, truncation=True, max_length=77)`), which caps `total_tokens` at 77 and reports
  81 as 77. Cases 1 and 3 are under the ceiling, so truncation is a no-op there.
- Wrong readings, each **implemented and run** — all three differ from the reference on **all
  three** cases: counting whitespace-separated words instead of tokens (case 1 → 19 instead of 27);
  counting with `add_special_tokens=False` (case 1 → 25); joining the clauses with `" "` instead of
  `", "` (case 1 → 22).
- **Cosmetic warning, not a defect.** On case 2 the tokenizer logs
  `Token indices sequence length is longer than the specified maximum sequence length for this
  model (81 > 77)` — to **stderr**, verified with `2>/dev/null`, so graded stdout is unaffected.
  A solution that silences it with `verbose=False` returns identical values; neither route is
  preferred.
- **Untested edge, deliberately:** no case makes `k` come out `0`, so nothing depends on
  `"kept_tokens"` for an empty prompt (which is the tokenizer's 2 special tokens). Do not add such
  a case without saying so in the statement.
- Needs the **HF Hub at grading time** — the tokenizer's `vocab.json` + `merges.txt`, about 1.7 MB,
  no model weights. Measured end to end, the three-case run above takes 2.6 s of wall clock
  against a warm cache, tokenizer construction included. The grader environment needs
  `transformers` and nothing else for this question.

---

## Q4: The Latent Canvas a Seed Pins Down

**Context:** Latent diffusion never denoises pixels. A VAE first compresses the image into a small
multi-channel latent grid, and every denoising step runs on that grid — which is the whole reason
the process is affordable. Generation begins by filling that grid with random noise, and the seed
handed to the random generator is the only thing standing between "the same image again" and "a
different image every run". Getting that wrong is the classic reason an A/B comparison of two
prompts proves nothing: the generator is stateful, so a second draw from the same generator object
is *not* the same noise, no matter what seed it started from.

**Problem Statement:**

Using `torch`, write a function
`latent_canvas_report(seed, width, height, vae_scale_factor, latent_channels)`.

1. The pipeline is set up to produce a `width` × `height` RGB image. The VAE shrinks each spatial
   side by `vae_scale_factor`, so the latent grid actually denoised is
   `height // vae_scale_factor` rows by `width // vae_scale_factor` columns, with
   `latent_channels` channels.
2. Draw **A**, the starting noise for one image: a `torch.randn` tensor of shape
   `(1, latent_channels, rows, columns)`, drawn from a CPU `torch.Generator` seeded with `seed`.
3. Draw **B**: the same shape, from a **freshly created** generator seeded with the same `seed`.
4. Draw **C**: the same shape again, from **the same generator object that produced draw A**,
   without re-seeding it.
5. Report the compression the VAE bought: the number of values in the pixel image (three channels,
   one per RGB channel) divided by the number of values in the latent grid, rounded to 2 decimal
   places.
6. Return a dictionary with exactly these seven keys:
   - `"latent_height"`, `"latent_width"` — the latent grid's rows and columns
   - `"compression_ratio"` — from step 5
   - `"noise_mean"`, `"noise_std"` — draw A's mean and standard deviation, each rounded to 4
     decimal places
   - `"reseeded_matches"` — whether draw B is element-for-element identical to draw A
   - `"continued_matches"` — whether draw C is element-for-element identical to draw A

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: seed (integer)
    Single line: one integer
  Argument 2: width (integer)
    Single line: one integer
  Argument 3: height (integer)
    Single line: one integer
  Argument 4: vae_scale_factor (integer)
    Single line: one integer
  Argument 5: latent_channels (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `latent_canvas_report()` on a new line.

**Sample Input:**

```
seed = 42
width = 512
height = 512
vae_scale_factor = 8
latent_channels = 4
```

**Sample Output:**

```
{'latent_height': 64, 'latent_width': 64, 'compression_ratio': 48.0, 'noise_mean': 0.0091, 'noise_std': 1.004, 'reseeded_matches': True, 'continued_matches': False}
```

**Note:** Return plain Python numbers and booleans, not NumPy or torch scalars — a tensor scalar
renders as `tensor(0.0091)` and will not compare equal. Leave the generator on the CPU and take
`torch.randn`'s default dtype.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: latent_canvas_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. seed             → Integer
2. width            → Integer
3. height           → Integer
4. vae_scale_factor → Integer
5. latent_channels  → Integer
```

(`width`/`height` (512), `vae_scale_factor` (8) and `latent_channels` (4) are all fixed by the
checkpoint or defaulted in the pipeline API — required arguments here, since the tool supports no
argument defaults, and each one catches a different hardcoded constant.)

**Reference Solution:**

```python
import torch


def latent_canvas_report(seed: int, width: int, height: int,
                         vae_scale_factor: int, latent_channels: int) -> dict:
    latent_h = height // vae_scale_factor
    latent_w = width // vae_scale_factor
    shape = (1, latent_channels, latent_h, latent_w)

    generator = torch.Generator().manual_seed(seed)
    draw_a = torch.randn(shape, generator=generator)
    draw_b = torch.randn(shape, generator=torch.Generator().manual_seed(seed))
    draw_c = torch.randn(shape, generator=generator)

    pixel_values = width * height * 3
    latent_values = latent_channels * latent_h * latent_w

    return {"latent_height": latent_h,
            "latent_width": latent_w,
            "compression_ratio": round(pixel_values / latent_values, 2),
            "noise_mean": round(float(draw_a.mean()), 4),
            "noise_std": round(float(draw_a.std()), 4),
            "reseeded_matches": bool(torch.equal(draw_b, draw_a)),
            "continued_matches": bool(torch.equal(draw_c, draw_a))}
```

**Test Cases —** `in.txt`

```
3
42
512
512
8
4
123
1024
768
8
16
7
640
384
8
4
```

**Test Cases —** `out.txt`

```
{'latent_height': 64, 'latent_width': 64, 'compression_ratio': 48.0, 'noise_mean': 0.0091, 'noise_std': 1.004, 'reseeded_matches': True, 'continued_matches': False}
{'latent_height': 96, 'latent_width': 128, 'compression_ratio': 12.0, 'noise_mean': -0.0037, 'noise_std': 1.0025, 'reseeded_matches': True, 'continued_matches': False}
{'latent_height': 48, 'latent_width': 80, 'compression_ratio': 48.0, 'noise_mean': 0.0056, 'noise_std': 0.9971, 'reseeded_matches': True, 'continued_matches': False}
```

**Grader Notes:**

- **Scope trace.** "Every generation starts from random latent noise" and the seed's role:
  `L18_Diffusion_Models_Lecture_2.md:547`–`:553`; the generator being re-created before **every**
  run (which is what `"continued_matches"` grades): `:560`–`:564`. The latent grid's dimensions and
  the compression it buys — `512 × 512 × 3` → `64 × 64 × 4`, "roughly 48× fewer values":
  `L18_Diffusion_Models_Lecture.md:1764`–`:1775`. **Disclosed, not taught:** constructing the
  latent tensor by hand (the pipeline does it internally) and using a CPU generator where the
  material writes `torch.Generator("cuda")` — the statement says CPU, since a grader has no GPU.
- All three cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `torch` 2.13.0); the `out.txt` above is real program output. Compare `noise_mean` / `noise_std`
  with a float tolerance of `1e-4`, the two booleans and three integers exactly; key order is not
  graded.
- **Case 1 reproduces a figure the source material prints** — `48.0`, at the taught
  512 × 512 → 64 × 64 × 4 geometry.
- **Case 2 is the only case that catches a hardcoded `compression_ratio` of 48** (it uses a
  16-channel latent, giving 12.0) and, with case 3, the only one that catches swapping rows and
  columns (case 1 is square). Never drop case 2.
- Wrong readings, each **implemented and run**:
  - **re-seeding before every draw** (a fresh `manual_seed(seed)` for draw C as well) — reports
    `"continued_matches": True`; differs on all three cases. This is the whole point of the
    question.
  - **omitting the three RGB channels** from the pixel-value count — case 1 → 16.0 instead of
    48.0; differs on all three cases.
  - **swapping rows and columns** — differs on cases 2 and 3, not on case 1.
- **Accepted equivalents, all verified to give identical output:** `torch.std`'s unbiased default
  and NumPy's population `std` agree to 4 decimal places on all three cases (checked explicitly —
  the arrays are ≥ 15 360 values, so the Bessel correction is far below the rounding cut);
  `torch.equal` and `(a == b).all()` are interchangeable; drawing B before C or after makes no
  difference, since B always comes from a fresh generator.
- torch's CPU generator is deterministic for a fixed seed on a fixed build. It is **not** contract
  guaranteed across torch releases, so pin `torch` in the grader image (verified on 2.13.0) and
  regenerate `out.txt` if that pin moves. The three integers, both booleans and the compression
  ratio are version-independent; only `noise_mean` / `noise_std` would move.
- No network access and no weights at run time. The grader environment needs `torch` only.

---

## Q5: How a U-Net Tells One Timestep From Another

**Context:** One U-Net handles every step of the reverse process, and it can only apply the right
amount of denoising if it knows where on the noise ladder it currently sits. The integer timestep
is therefore expanded into a sinusoidal **time embedding** and injected into the network's layers.
Whether two steps are distinguishable to the network is a property of that embedding, not of the
integers — so a sampler's step plan is worth probing before it is wired into a loop: embed the
steps it will actually visit and measure how alike consecutive ones look.

**Problem Statement:**

Using the `diffusers` library, write a function
`time_embedding_similarity(timesteps, embedding_dim, flip_sin_to_cos, downscale_freq_shift)`.

1. Embed all of `timesteps` in one call with `diffusers`' own sinusoidal time-embedding builder,
   `get_timestep_embedding` from `diffusers.models.embeddings`, into vectors of width
   `embedding_dim`, passing `flip_sin_to_cos` and `downscale_freq_shift` through to it unchanged and leaving every
   other argument at its default.
2. For each **consecutive pair** of timesteps, in the order given, compute the cosine similarity
   between their two embedding vectors.
3. Return those similarities as a list of floats, in pair order, each rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: timesteps (list_int)
    Line 1: N (list length)
    Next N lines: one integer each
  Argument 2: embedding_dim (integer)
    Single line: one integer
  Argument 3: flip_sin_to_cos (boolean)
    Single line: true or false
  Argument 4: downscale_freq_shift (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `time_embedding_similarity()` on a new line.

**Sample Input:**

```
timesteps = [950, 900, 800, 650, 0]
embedding_dim = 320
flip_sin_to_cos = True
downscale_freq_shift = 0.0
```

**Sample Output:**

```
[0.5124, 0.4433, 0.4172, 0.2207]
```

**Note:** `get_timestep_embedding` takes the timesteps as a torch tensor, and returns one row per
timestep. Return plain Python floats, not torch scalars.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: time_embedding_similarity
RETURN TYPE: List of Floats

ARGUMENTS:
1. timesteps            → List of Ints
2. embedding_dim        → Integer
3. flip_sin_to_cos      → Boolean
4. downscale_freq_shift → Float
```

(`flip_sin_to_cos` and `downscale_freq_shift` are defaulted in `get_timestep_embedding`
(`False` / `1`) — required arguments here, since the tool supports no argument defaults.
`downscale_freq_shift` is what catches a solution that ignores the configuration it was handed;
`flip_sin_to_cos` **cannot affect this question's output at all** — see the grader notes.)

**Reference Solution:**

```python
import torch
from diffusers.models.embeddings import get_timestep_embedding


def time_embedding_similarity(timesteps: list, embedding_dim: int,
                              flip_sin_to_cos: bool, downscale_freq_shift: float) -> list:
    embeddings = get_timestep_embedding(
        torch.tensor([int(t) for t in timesteps]),
        embedding_dim,
        flip_sin_to_cos=flip_sin_to_cos,
        downscale_freq_shift=downscale_freq_shift,
    )
    unit = embeddings / embeddings.norm(dim=-1, keepdim=True)
    similarities = (unit[:-1] * unit[1:]).sum(dim=-1)
    return [round(float(s), 4) for s in similarities]
```

**Test Cases —** `in.txt`

```
2
5
950
900
800
650
0
320
true
0.0
4
0
100
500
999
32
false
1.0
```

**Test Cases —** `out.txt`

```
[0.5124, 0.4433, 0.4172, 0.2207]
[0.3052, 0.1931, 0.3156]
```

**Grader Notes:**

- **Scope trace.** The U-Net receiving the timestep as a time embedding, and why the same network
  needs it: `L18_Diffusion_Models_Lecture.md:900`–`:913` and `:915`–`:931`, including
  "converted into a **time embedding** (often using sinusoidal embeddings) and injected into
  multiple layers" at `:927`. Case 1's timesteps are a DDIM skip path of the kind drawn at
  `:1256`–`:1310`. **Disclosed, not taught:** the `get_timestep_embedding` entry point, its two
  configuration flags, and cosine similarity as the probe — the material names sinusoidal
  embeddings but never writes the formula, which is exactly why the library has to produce the
  numbers. Cosine similarity itself appears **nowhere** in Class 18's two files — the only "cosine"
  hit is the *Cosine Schedule* at `L18_Diffusion_Models_Lecture.md:430`, an unrelated noise
  schedule. It is taught earlier in the programme (Module 1's embeddings and multimodal lectures,
  and Module 3's L9–L11 retrieval lectures), so every learner has met it, but treat it as assumed
  background rather than as this class's material, and keep it named in the statement.
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `diffusers` 0.40.0, `torch` 2.13.0); the `out.txt` above is real program output. Compare
  element-by-element with a float tolerance of `1e-4`.
- **Case 1 is the only case that catches a solution ignoring `downscale_freq_shift`** and using the
  library default (`1`) — case 2's value *is* the default. Never drop case 1. Case 1's configuration
  (`True` / `0.0`, width 320) is Stable Diffusion's own.
- **`flip_sin_to_cos` cannot affect this question's output, and no case grades it.** It concatenates
  `[sin, cos]` and then swaps the two halves — a column permutation applied identically to every row —
  and cosine similarity is invariant under a shared permutation. Verified 2026-08-31: `flip=True` and
  `flip=False` agree on both cases and at `embedding_dim` 320 / 32 / 33 / 7, at both
  `downscale_freq_shift` values. It is declared so the configuration is forwarded honestly. A solution
  that hardcodes it, or drops it from the call, scores full marks — do not claim it is caught.
- Case 1's gaps (50, 100, 150, 650) are all different, so its four numbers are four distinct
  values — a solution that computes one similarity and repeats it fails. Note that cosine
  similarity between two sinusoidal embeddings depends only on the *difference* of the timesteps,
  so equally spaced timesteps would have produced four identical numbers; that is why case 1 is
  unevenly spaced.
- Wrong readings, each **implemented and run**: measuring every timestep against the **first**
  instead of against its predecessor (differs on both cases); returning Euclidean distance instead
  of cosine similarity (differs on both cases); hardcoding the library defaults (differs on case 1).
- **Accepted equivalent:** `torch.nn.functional.cosine_similarity(emb[:-1], emb[1:], dim=-1)`
  reproduces the reference exactly on both cases. Grade the returned values, not the route.
- **Untested edge, deliberately:** neither case passes fewer than two timesteps, and the statement
  says nothing about what a single timestep returns (there are no pairs, so the reference returns an
  empty list). Do not add such a case without extending the statement.
- No network access and no weights: `get_timestep_embedding` is pure math. The grader environment
  needs `torch` + `diffusers`.

---

## Q6: What the Noise Schedule Decides

**Context:** The forward process is a fixed recipe, not something the model learns, and the recipe is
the noise schedule. Two schedules that both end at pure noise can take very different routes to get
there, and the route decides how long the image stays recognisable — which is the whole reason more
than one schedule exists. The quantity that settles the argument is the coefficient the forward
process applies to the clean image at step `t`: while it is near 1 the image is barely touched, and
once it approaches 0 there is nothing left to recover.

**Problem Statement:**

Using the `diffusers` library, write a function
`schedule_survival(schedule_names, thresholds, num_train_timesteps, beta_start, beta_end)`.

1. For each name in `schedule_names`, build a `diffusers.DDPMScheduler` with the given
   `num_train_timesteps`, `beta_start`, `beta_end`, and that name as its beta schedule. Leave every
   other scheduler setting at its default.
2. The scheduler exposes the cumulative product of the schedule as `alphas_cumprod`. The fraction of
   the clean image still present at step `t` is the **square root** of that cumulative product at `t`
   — the coefficient the forward process multiplies the clean image by. Timestep `t` is index `t` of
   `alphas_cumprod`.
3. For each value in `thresholds`, in the order given, find the **smallest** timestep at which that
   surviving fraction has dropped **below** the threshold. Every threshold given is crossed before the
   schedule ends.
4. Return a dictionary keyed by schedule name, whose value is the list of those timesteps, one per
   threshold, in the same order as `thresholds`.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: schedule_names (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 2: thresholds (list_float)
    Line 1: M (list length)
    Next M lines: one float each
  Argument 3: num_train_timesteps (integer)
    Single line: one integer
  Argument 4: beta_start (float)
    Single line: one float
  Argument 5: beta_end (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `schedule_survival()` on a new line.

**Sample Input:**

```
schedule_names = ["linear", "squaredcos_cap_v2"]
thresholds = [0.5, 0.1]
num_train_timesteps = 1000
beta_start = 0.0001
beta_end = 0.02
```

**Sample Output:**

```
{'linear': [368, 673], 'squaredcos_cap_v2': [664, 935]}
```

**Note:** The input handling is already in place — you only need to implement the function. Timesteps
are plain Python integers. Read the sample as a sanity check on what the two schedules are doing: one
of them is down to half the original image by step 368 while the other still holds half of it at 664,
which is the difference the choice of schedule buys.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: schedule_survival
RETURN TYPE: Dictionary

ARGUMENTS:
1. schedule_names      → List of Strings
2. thresholds          → List of Floats
3. num_train_timesteps → Integer
4. beta_start          → Float
5. beta_end            → Float
```

(`num_train_timesteps`, `beta_start` and `beta_end` are all defaulted in `DDPMScheduler`
(1000 / 0.0001 / 0.02) — required here since the tool supports no argument defaults, and making them
explicit is what catches a hardcoded 1000. The schedule names are arguments rather than constants so
that no `diffusers` config vocabulary has to be recalled.)

**Reference Solution:**

```python
from diffusers import DDPMScheduler


def schedule_survival(schedule_names: list, thresholds: list, num_train_timesteps: int,
                      beta_start: float, beta_end: float) -> dict:
    report = {}
    for name in schedule_names:
        scheduler = DDPMScheduler(
            num_train_timesteps=num_train_timesteps,
            beta_start=beta_start,
            beta_end=beta_end,
            beta_schedule=name,
        )
        surviving = scheduler.alphas_cumprod.sqrt()
        report[name] = [int((surviving < threshold).nonzero()[0]) for threshold in thresholds]
    return report
```

**Test Cases —** `in.txt`

```
2
2
linear
squaredcos_cap_v2
2
0.5
0.1
1000
0.0001
0.02
2
squaredcos_cap_v2
linear
2
0.9
0.5
500
0.001
0.05
```

**Test Cases —** `out.txt`

```
{'linear': [368, 673], 'squaredcos_cap_v2': [664, 935]}
{'squaredcos_cap_v2': [140, 332], 'linear': [56, 158]}
```

**Grader Notes:**
- **QC fixes, 2026-08-31 — no expected output moved** (both cases re-run in fresh processes,
  byte-identical). The statement now pins **timestep `t` is index `t` of `alphas_cumprod`**: an
  off-by-one reading diverges by exactly 1 on every value (`[369, 674]` / `[665, 936]` against the
  shipped `[368, 673]` / `[664, 935]`), and a "largest index still above the threshold" reading gives
  `[367, 672]`. It also now guarantees **every threshold is crossed before the schedule ends**, because
  a threshold below the schedule's floor (linear at 1000 steps bottoms out at 0.006353) makes
  `.nonzero()[0]` raise. The unused `import torch` came out of the reference.

- **Scope trace.** The noise schedule as a fixed, unlearned recipe:
  `modules/03-agentic-ai-systems/markdown/L18_Diffusion_Models_Lecture.md:422`–`:436`, with the
  **Linear** schedule named at `:428` and the **Cosine** schedule at `:430` — including the claim this
  question makes quantitative, that the cosine schedule "preserves useful image information for
  longer". The coefficient being measured is the `\sqrt{\bar\alpha_t}` of the closed form at `:966`,
  described at `:969` as "a single number summarizing how much of the *original image* survives by
  step t", and β magnitudes "like 0.0001" are `:957`. **Disclosed, not taught:** `DDPMScheduler`,
  `alphas_cumprod` and the diffusers spelling of the cosine schedule — the material names the two
  schedules but never writes either formula, which is exactly why the library has to produce the
  numbers. The statement therefore names the attribute and passes the schedule names in as data.
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `diffusers` 0.40.0, `torch` 2.13.0); the `out.txt` above is real program output. All values are
  exact integers — compare them exactly; key order is not graded.
- **Case 1 is the pedagogical payoff and case 2 is the anti-hardcode case.** Case 1 shows linear at
  half-signal by 368 against cosine's 664 (and a tenth by 673 against 935). Case 2 changes
  `num_train_timesteps` to 500, both betas, both thresholds, **and the order of the two schedule
  names**, so it catches a hardcoded 1000, a hardcoded threshold, and any assumption about which
  schedule comes first. Never drop case 2.
- **The cosine schedule ignores `beta_start` / `beta_end`** — verified: holding
  `num_train_timesteps=1000` and moving the betas from `0.0001/0.02` to `0.005/0.5` leaves the cosine
  answer at `664`, while linear moves from `368` to `65`. So a solution that forgets to forward the
  betas is caught by the **linear** entry only. Both cases contain a linear entry; do not build a
  case out of cosine alone.
- Wrong readings, each **implemented and run** — all three differ from the reference on **both**
  cases: comparing the threshold against `alphas_cumprod` itself instead of its square root; using
  the per-step `alphas` instead of the cumulative product (treating one rung as the whole climb);
  hardcoding `"linear"` for every entry.
- **Untested edge, deliberately:** every threshold in both cases is crossed before the schedule ends.
  A threshold so low that the surviving fraction never falls below it would make `.nonzero()[0]`
  raise, and the statement says nothing about it — do not add such a case without extending the
  statement.
- No network access and no weights: `DDPMScheduler` is pure math. The grader environment needs
  `torch` + `diffusers`.

---

## Q7: Where a U-Net's Parameters Actually Sit

**Context:** The network doing the denoising is a U-Net, and its shape is the reason it can predict
noise at all: an encoder that walks the image down to a low resolution where it can reason about the
whole scene, a bottleneck at the bottom, and a decoder that walks back up while recovering detail.
The decoder does not work from the bottleneck alone — skip connections hand it the encoder's feature
maps at matching resolutions, and that has a consequence you can read straight off a parameter count.
Two other details only the built model will tell you: how many levels actually halve the resolution,
and how much of the network exists purely to encode the timestep.

**Problem Statement:**

Using the `diffusers` library, write a function
`unet_stage_profile(sample_size, in_channels, block_out_channels, layers_per_block)`.

1. Build a `diffusers.UNet2DModel` for `sample_size` × `sample_size` inputs with `in_channels`
   channels in and the same number out. `block_out_channels` gives the channel width at each level,
   so its length is the number of levels; use a plain `"DownBlock2D"` at every level of the encoder
   and a plain `"UpBlock2D"` at every level of the decoder, and pass `layers_per_block` through — the
   block lists go in as `down_block_types` and `up_block_types`, and the output width as
   `out_channels`. Leave every other setting at its default.
2. Count the parameters in each of the model's down blocks, in each of its up blocks, in its mid
   block, in its timestep-embedding module and in its input convolution — `down_blocks`, `up_blocks`,
   `mid_block`, `time_embedding` and `conv_in`.
3. Count the down blocks whose `downsamplers` is not `None`. The resolution at the bottleneck is
   `sample_size` halved once per such level.
4. Return a dictionary with exactly these seven keys:
   - `"down_params"` — the per-down-block parameter counts, encoder order
   - `"up_params"` — the per-up-block parameter counts, in `up_blocks` order (deepest level first)
   - `"mid_params"` — the mid block's parameter count
   - `"time_embedding_params"` — the timestep-embedding module's parameter count
   - `"conv_in_params"` — the input convolution's parameter count
   - `"downsampling_stages"` — how many down blocks have a `downsamplers` module
   - `"bottleneck_resolution"` — the spatial resolution at the bottleneck

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: sample_size (integer)
    Single line: one integer
  Argument 2: in_channels (integer)
    Single line: one integer
  Argument 3: block_out_channels (list_int)
    Line 1: N (list length)
    Next N lines: one integer each
  Argument 4: layers_per_block (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `unet_stage_profile()` on a new line.

**Sample Input:**

```
sample_size = 64
in_channels = 4
block_out_channels = [32, 64, 128]
layers_per_block = 1
```

**Sample Output:**

```
{'down_params': [32000, 102912, 246656], 'up_params': [1051136, 312704, 78528], 'mid_params': 690688, 'time_embedding_params': 20736, 'conv_in_params': 1184, 'downsampling_stages': 2, 'bottleneck_resolution': 16}
```

**Note:** The input handling is already in place — you only need to implement the function. Every
value is a plain Python integer. No weights are downloaded: the model is constructed from the
configuration you pass, and parameter counts do not depend on how those parameters were initialised.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: unet_stage_profile
RETURN TYPE: Dictionary

ARGUMENTS:
1. sample_size        → Integer
2. in_channels        → Integer
3. block_out_channels → List of Ints
4. layers_per_block   → Integer
```

(All four are defaulted in `UNet2DModel` — required here since the tool supports no argument defaults,
and varying them across cases is what catches a solution that hardcodes any part of the shape.)

**Reference Solution:**

```python
from diffusers import UNet2DModel


def unet_stage_profile(sample_size: int, in_channels: int, block_out_channels: list,
                       layers_per_block: int) -> dict:
    levels = len(block_out_channels)
    unet = UNet2DModel(
        sample_size=sample_size,
        in_channels=in_channels,
        out_channels=in_channels,
        block_out_channels=tuple(block_out_channels),
        layers_per_block=layers_per_block,
        down_block_types=("DownBlock2D",) * levels,
        up_block_types=("UpBlock2D",) * levels,
    )

    count = lambda module: sum(p.numel() for p in module.parameters())
    stages = sum(1 for block in unet.down_blocks if block.downsamplers is not None)

    return {"down_params": [count(b) for b in unet.down_blocks],
            "up_params": [count(b) for b in unet.up_blocks],
            "mid_params": count(unet.mid_block),
            "time_embedding_params": count(unet.time_embedding),
            "conv_in_params": count(unet.conv_in),
            "downsampling_stages": stages,
            "bottleneck_resolution": sample_size // 2 ** stages}
```

**Test Cases —** `in.txt`

```
3
64
4
3
32
64
128
1
64
4
2
64
128
2
128
3
4
32
64
96
128
1
```

**Test Cases —** `out.txt`

```
{'down_params': [32000, 102912, 246656], 'up_params': [1051136, 312704, 78528], 'mid_params': 690688, 'time_embedding_params': 20736, 'conv_in_params': 1184, 'downsampling_stages': 2, 'bottleneck_resolution': 16}
{'down_params': [218048, 591616], 'up_params': [1593088, 448512], 'mid_params': 723456, 'time_embedding_params': 82432, 'conv_in_params': 2368, 'downsampling_stages': 1, 'bottleneck_resolution': 32}
{'down_params': [32000, 102912, 240416, 287680], 'up_params': [1092160, 644064, 292160, 78528], 'mid_params': 690688, 'time_embedding_params': 20736, 'conv_in_params': 896, 'downsampling_stages': 3, 'bottleneck_resolution': 16}
```

**Grader Notes:**
- **QC fixes, 2026-08-31 — the expected outputs changed; all three were re-run in fresh processes.**
  Three problems, all of them coverage rather than correctness:
  (1) `time_embedding_params` was the constant **20736** in all three cases, because every case passed
  `block_out_channels[0] = 32`; case 2's widths are now `[64, 128]`, giving **82432**. It follows
  `20*b0**2 + 8*b0`, verified over 180 configurations.
  (2) **`in_channels` affected none of the six graded values** — a solution hardcoding `4` passed the
  whole suite. A seventh key `"conv_in_params"` was added (`count(unet.conv_in)`, i.e.
  `9*in_channels*b0 + b0`), and case 3 now passes `in_channels = 3` so the argument is actually
  exercised. It is the only key that moves with `in_channels`.
  (3) The statement never named `UNet2DModel`'s attributes or kwargs, none of which appears in **any**
  module-3 lecture file; `down_blocks`, `up_blocks`, `mid_block`, `time_embedding`, `conv_in`,
  `down_block_types`, `up_block_types` and `out_channels` are now all named.
- **Derivability audit (2026-08-31).** Of the seven keys, `down_params`, `up_params` and `mid_params`
  have **no closed form** in the arguments, and because the whole dict is exact-matched they gate every
  submission — the question cannot be passed without building the model. The other four
  (`time_embedding_params`, `conv_in_params`, `downsampling_stages`, `bottleneck_resolution`) are
  arithmetic, and two of those are *deliberately* so: step 3 asks the learner to read them off the
  model. `"total_params"` was considered and **rejected** as an eighth key — it equals the reported
  parts plus `conv_out` and `conv_norm_out`, so it is derivable from the dict itself.

- **Scope trace.** The whole question is `L18_Diffusion_Models_Lecture.md:812`–`:899`, §6.2 "Why Is a
  U-Net Used?", which names the three parts and walks the resolutions explicitly: the **Encoder
  (Downsampling Path)** at `:826`–`:852` with its printed ladder `512 → 256 → 128 → 64` in the fenced
  block at `:834`–`:848`, the **Bottleneck** at `:854`–`:860` ("at the lowest resolution … the largest
  receptive field"), the **Decoder (Upsampling Path)** at `:862`–`:884` with the ladder back up, and
  **Skip Connections** at `:886`–`:898` ("directly pass feature maps from the encoder to the decoder
  at matching resolutions"). The timestep-embedding module is `:900`–`:913` and `:927`. **Disclosed,
  not taught:** `UNet2DModel` and the attribute names (`down_blocks`, `up_blocks`, `mid_block`,
  `time_embedding`, `downsamplers`) — the material describes the architecture in prose and never
  constructs one, so the statement names the class and describes each part it wants counted. Reading
  the structure is the contract here; the skill under test is knowing what the three parts are and
  why the decoder side is heavier.
- All three cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `diffusers` 0.40.0, `torch` 2.13.0); the `out.txt` above is real program output. Every value is an
  exact integer — compare exactly; key order is not graded.
- **The skip-connection payoff is in the numbers, and it holds in all three cases.** At matching
  levels the decoder block is always heavier than its encoder counterpart (case 1: 1,051,136 against
  246,656 at the bottleneck level, 78,528 against 32,000 at the top), because a skip connection
  concatenates the encoder's feature map onto the decoder's input, widening every convolution that
  consumes it. A learner who expects a symmetric U-Net gets a surprise they can explain.
- **`downsampling_stages` is one fewer than the number of levels**, because the last down block
  carries no downsampler — verified: `[True, True, False]` for case 1's three blocks. This is why the
  statement says to ask the model rather than assume one halving per level, and it is the single most
  likely thing to get wrong.
- **Channel widths must be multiples of 32.** `UNet2DModel`'s default `norm_num_groups` is 32, so a
  width like 16 raises `ValueError: num_channels (16) must be divisible by num_groups (32)`. All three
  cases respect that; do not add a case with a smaller width without also passing `norm_num_groups`.
- **Parameter counts do not depend on initialisation**, so no seed is needed and the values are stable
  across runs — verified by building each config twice and comparing. Only *values* would be random,
  and none is graded.
- **Case 2 is the only case with a single downsampling stage**, and the only one whose
  `bottleneck_resolution` is not 16. **Case 3 is the only case with four levels.** Keep all three.
- **No case catches a hardcoded `len(block_out_channels) - 1`.** Verified 2026-08-31 over 1–5 levels:
  with plain `DownBlock2D` at every level, `downsampling_stages` is *always* `len(block_out_channels)
  - 1`, not just in case 2. Step 3 is enforced only by the three block-parameter keys, which have no
  closed form. Note also that `hasattr(block, "downsamplers")` is `True` for **every** block (it is
  `None` on the last level), which is why step 3 says "is not `None`" rather than "carries a module".
- Wrong readings, each **implemented and run**: counting `unet.parameters()` in total instead of per
  block (differs on all three cases); assuming every level downsamples, i.e. `stages = levels`
  (differs on all three — bottleneck resolution comes out 8/16/8 instead of 16/32/16); reading
  `up_params` in encoder order rather than decoder order (differs on all three, since the lists are
  not palindromes).
- No network access and no weights: `UNet2DModel` is constructed from config. Each case builds in
  about 10 ms. The grader environment needs `torch` + `diffusers`.
