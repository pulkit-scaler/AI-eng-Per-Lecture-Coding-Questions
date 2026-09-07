# Module 3, Lecture 20 — Advanced Diffusion & Agentic Image Generation

Six coding questions. Q1 covers the two techniques that turn a text-to-image model into an
**editing** tool: `strength`-truncated sampling (image-to-image — start partway down the noise
ladder so the original still shows through) and **mask-blended** denoising (inpainting — let the
model repaint one region while the rest of the image is pinned to the original at every step).
Q5 measures what `strength` actually leaves of the input at the moment the loop starts, and Q6 proves
on a freshly built adapter that ControlNet's zero convolutions inject exactly nothing before training —
the mechanism behind the claim that attaching one preserves the base model.

> **Which of these are live.** The notebook
> [`Coding_Ques_Module_3_Agentic_AI_Systems.ipynb`](Coding_Ques_Module_3_Agentic_AI_Systems.ipynb)
> currently carries **Q5 and Q6** (as its Questions 18 and 19 — the notebook was renumbered
> continuously from Q1 on 2026-08-27). An earlier Q6, `configured_step`, was **superseded on
> 2026-08-27** as part of moving this set off scheduler mechanics; it was replaced by the ControlNet
> question above. **Q2** (the feathered outpainting
> mask), **Q3** (textual-inversion token registration) and **Q4** (shared frame latents) were **cut by
> the author on 2026-08-27** — each graded bookkeeping around the model (pixel counts, vocabulary ids,
> RNG statistics) rather than a value the diffusion process itself produces. They are kept here as a
> record, not as candidates; do not reinstate any of them without asking. Q1 lives only in this file,
> and carries its own caveat below.

> **Scope note.** Q1 was written against the pre-recording brief in
> [`modules/03-agentic-ai-systems/FUTURE_CLASSES.md`](../../../modules/03-agentic-ai-systems/FUTURE_CLASSES.md)
> ("Advanced Diffusion & Agentic Image Generation") and stays inside its image-to-image and
> inpainting items. The material has since been recorded as
> `modules/03-agentic-ai-systems/markdown/L19_Advanced_Diffusion.md` (img2img, inpainting/
> outpainting, ControlNet, IP-Adapter, textual inversion, DreamBooth) and
> `L19_Advanced_Diffusion_Part_2.md` (agentic pipelines, AnimateDiff, production hosting), which is
> what **Q2–Q4 trace to, line by line, in their grader notes**. This file is curriculum position
> 20; the class tag in
> [`Coding_Ques_Module_3_Agentic_AI_Systems.ipynb`](Coding_Ques_Module_3_Agentic_AI_Systems.ipynb)
> is `[Class 19]`, off the markdown filename.
>
> No question here needs a GPU or model weights. What remains ungraded from that material is the
> work that cannot run without one — ControlNet, IP-Adapter and DreamBooth inference, AnimateDiff
> generation itself — and the LLM-driven orchestration (prompt optimisation,
> generate-critique-refine agents, ComfyUI), which is covered by the agent questions in
> [`../agentic-ai-systems-coding-ques.md`](../agentic-ai-systems-coding-ques.md).

---

## Q1: Inpaint a Region with Strength-Truncated DDIM

**Context:** Inpainting keeps everything outside a mask **byte-identical** to the original, which a
plain denoising loop cannot do — every step rewrites the whole latent. Real pipelines fix this by
blending at every step: denoise the whole latent, then paste the untouched region back in, noised
to exactly the level the loop is about to continue from. The `strength` slider layers the
image-to-image trick on top: instead of starting from pure noise, start from the original latent
noised only partway up the ladder, and run only the tail of the schedule — low `strength` means a
light touch-up, `strength = 1.0` means a full repaint.

**Problem Statement:**

Using the `diffusers` library, write a function
`inpaint_latent(init_latent, mask, noise, noise_preds, num_inference_steps, strength, num_train_timesteps)`.

1. Build `diffusers.DDIMScheduler` with the given `num_train_timesteps` and with
   `clip_sample=False` (matching Stable Diffusion's own scheduler config), leaving every other
   scheduler setting at its default, and ask it for a full inference schedule of
   `num_inference_steps` timesteps (noisiest first).
2. `strength` decides how much of that schedule actually runs: the number of steps to run is
   `num_inference_steps * strength` **rounded down to a whole number**, and the steps that run are
   the **last** ones — the high-noise front of the schedule is skipped, which is what keeps the
   result close to the original.
3. `noise_preds` has one row per timestep of the **full** schedule, in the same order: row `i` is
   the recorded noise prediction at the `i`-th timestep of the full schedule. A truncated run
   therefore uses only the rows belonging to the timesteps it visits.
4. `init_latent` is the original image's latent and `noise` is a fixed Gaussian noise vector of the
   same length (the role a fixed seed plays in a real pipeline). Start the loop from `init_latent`
   noised — in one hop, by the forward process — to the **first timestep that will actually run**.
5. `mask` has one value per latent position: `1.0` marks a position to be **repainted**, `0.0` a
   position to be **kept**. At each step: hand the current timestep's noise prediction, the
   timestep, and the current latent to the scheduler to get the previous (less noisy) latent, then
   restore the kept positions from the original — noised, again in one hop, to the **next timestep
   the loop will run**. After the final step there is no next timestep, so the kept positions are
   restored from `init_latent` itself, unnoised. Repainted positions always keep whatever the
   scheduler produced.
6. Return a dictionary whose key is the timestep of each step that ran (an integer) and whose value
   is the list of the latent's values **after** that step's restore, in positional order, each
   rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: init_latent (numpy_1d_array)
    Line 1: D (array length)
    Line 2: D space-separated floats
  Argument 2: mask (numpy_1d_array)
    Line 1: D (array length)
    Line 2: D space-separated floats
  Argument 3: noise (numpy_1d_array)
    Line 1: D (array length)
    Line 2: D space-separated floats
  Argument 4: noise_preds (numpy_2d_array)
    Line 1: N D (number of rows, dimension)
    Next N lines: D space-separated floats
  Argument 5: num_inference_steps (integer)
    Single line: one integer
  Argument 6: strength (float)
    Single line: one float
  Argument 7: num_train_timesteps (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `inpaint_latent()` on a new line.

**Sample Input:**

```
init_latent = np.array([0.5, -0.2, 0.9, -0.7, 0.1, 0.3])
mask = np.array([0., 0., 1., 1., 0., 1.])
noise = np.array([0.4, -1.0, 0.8, 0.2, -0.5, 1.3])
noise_preds = np.array([[ 0.3588,  1.5107, -1.7863,  1.6866, -0.0473, -0.8000],
                        [-0.8030, -1.0828, -0.2236,  0.8339,  0.5841,  0.6383],
                        [-1.6948, -1.5710,  1.5538,  0.9689,  2.1832,  1.2098],
                        [-1.0244,  1.2853,  0.6284,  0.2148, -0.8199,  0.0028],
                        [-0.1470,  0.8925,  0.1245,  1.5847, -0.7745,  0.4711]])
num_inference_steps = 5
strength = 0.7
num_train_timesteps = 1000
```

**Sample Output:**

```
{400: [0.6396, -0.7482, 0.3935, -1.2706, -0.2121, 1.1014], 200: [0.504, -0.21, 0.0373, -1.7215, 0.095, 1.3574], 0: [0.5, -0.2, 0.0361, -1.7374, 0.1, 1.3528]}
```

**Note:** The input handling is already in place — you only need to implement the function.
`noise_preds` stands in for the U-Net's forward passes, so no model is loaded and nothing is
downloaded; `diffusers` schedulers work on `torch` tensors, so convert on the way in and back to
Python floats when building the returned dictionary. Read the sample output as a sanity check: the
kept positions (0, 1, 4) drift while the loop is running and land back on exactly
`0.5, -0.2, 0.1` at the end, while the repainted positions (2, 3, 5) end up somewhere new.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: inpaint_latent
RETURN TYPE: Dictionary

ARGUMENTS:
1. init_latent         → Numpy 1D Array
2. mask                → Numpy 1D Array
3. noise               → Numpy 1D Array
4. noise_preds         → Numpy 2D Array
5. num_inference_steps → Integer
6. strength            → Float
7. num_train_timesteps → Integer
```

(`num_inference_steps` (50), `strength` (0.8 in the img2img/inpaint pipelines) and
`num_train_timesteps` (1000) are all defaulted in the real API — required here, since the tool
supports no argument defaults. `mask` is a `Numpy 1D Array` of `0.0`/`1.0` rather than a boolean
type because the dropdown has no boolean-array type, and a float mask is also how the real
pipelines carry it.)

**Reference Solution:**

```python
import numpy as np
import torch
from diffusers import DDIMScheduler


def inpaint_latent(init_latent: np.ndarray, mask: np.ndarray, noise: np.ndarray,
                   noise_preds: np.ndarray, num_inference_steps: int, strength: float,
                   num_train_timesteps: int) -> dict:
    scheduler = DDIMScheduler(num_train_timesteps=num_train_timesteps, clip_sample=False)
    scheduler.set_timesteps(num_inference_steps)

    init = torch.tensor(np.asarray(init_latent), dtype=torch.float32)
    repaint = torch.tensor(np.asarray(mask), dtype=torch.float32)
    noise_t = torch.tensor(np.asarray(noise), dtype=torch.float32)
    preds = torch.tensor(np.asarray(noise_preds), dtype=torch.float32)

    num_run = int(num_inference_steps * strength)
    first = num_inference_steps - num_run
    timesteps = scheduler.timesteps[first:]
    preds = preds[first:]

    latent = scheduler.add_noise(init, noise_t, torch.tensor([int(timesteps[0])]))

    trace = {}
    for i, t in enumerate(timesteps):
        latent = scheduler.step(preds[i], t, latent).prev_sample
        if i + 1 < len(timesteps):
            known = scheduler.add_noise(init, noise_t, torch.tensor([int(timesteps[i + 1])]))
        else:
            known = init
        latent = repaint * latent + (1 - repaint) * known
        trace[int(t)] = [round(float(v), 4) for v in latent]
    return trace
```

**Test Cases —** `in.txt`

```
2
6
0.5 -0.2 0.9 -0.7 0.1 0.3
6
0 0 1 1 0 1
6
0.4 -1 0.8 0.2 -0.5 1.3
5 6
0.3588 1.5107 -1.7863 1.6866 -0.0473 -0.8
-0.803 -1.0828 -0.2236 0.8339 0.5841 0.6383
-1.6948 -1.571 1.5538 0.9689 2.1832 1.2098
-1.0244 1.2853 0.6284 0.2148 -0.8199 0.0028
-0.147 0.8925 0.1245 1.5847 -0.7745 0.4711
5
0.7
1000
4
-0.4 0.8 0.2 -1.1
4
1 0 0 1
4
1.2 -0.3 0.6 -0.9
8 4
-1.3976 -1.204 -1.3023 -0.6227
1.4473 -1.6013 0.944 1.2625
-0.3555 -0.7009 0.4721 1.2146
2.1555 0.8918 1.5938 -0.4503
-0.8742 -1.7198 -1.1537 -0.3634
0.193 -1.3131 0.8161 -0.103
-0.6422 -0.7653 2.0207 0.1692
-0.8979 -0.954 1.8378 -0.5784
8
0.5
500
```

**Test Cases —** `out.txt`

```
{400: [0.6396, -0.7482, 0.3935, -1.2706, -0.2121, 1.1014], 200: [0.504, -0.21, 0.0373, -1.7215, 0.095, 1.3574], 0: [0.5, -0.2, 0.0361, -1.7374, 0.1, 1.3528]}
{186: [1.0033, 0.5236, 0.4851, -1.5934], 124: [1.0708, 0.6817, 0.3623, -1.763], 62: [1.3008, 0.797, 0.206, -1.8873], 0: [1.3098, 0.8, 0.2, -1.8816]}
```

**Grader Notes:**

- **Scope trace (added 2026-08-27, after the material was recorded) — read the caveat below.**
  What IS in Class 19's own material: `strength` and "instead of starting the reverse diffusion
  process from pure Gaussian noise … partially noise it up to some intermediate timestep" at
  `modules/03-agentic-ai-systems/markdown/L19_Advanced_Diffusion.md:43`; the `strength=[0.2, 0.7,
  1.0]` sweep at `:133` whose own recorded progress bars read `0/6`, `0/21`, `0/30` (`:158`,
  `:168`, `:178`) and, at `strength=0.95` over 50 steps, `0/47` (`:320`) — which is the
  `int(num_inference_steps * strength)` rule this question grades, confirmed by the material's own
  output. Mask polarity (white regenerates, black preserves) is `:219` and `:356`–`:358`.
  `DDIMScheduler` and `clip_sample=False` are `L19_Advanced_Diffusion_Part_2.md:812` and `:840`.
- **CAVEAT — the per-step blending loop is NOT taught anywhere.** "Denoise the whole latent, then
  paste the untouched region back in, noised to exactly the level the loop is about to continue
  from" appears in none of the four diffusion files, and neither does a **latent-space** mask: the
  material treats inpainting purely as `AutoPipelineForInpainting` called with a PIL mask image
  (`L19_Advanced_Diffusion.md:234`–`:292`), never opening the loop. `add_noise` and `step` appear in
  no diffusion file either. The statement does specify the whole algorithm step by step, so the
  question is solvable as written from the statement alone — but a learner who understood this class
  perfectly still has no prior basis for the mechanism, which makes this the **least
  curriculum-anchored question in the set**. It grades the taught *observables* (strength truncates
  the schedule; the masked region changes and the rest returns to the original) through an untaught
  *mechanism*. If the set is ever trimmed, trim this one first; if it is kept, keep the statement's
  step-by-step spelling-out intact, because that spelling-out is the only thing making it fair.
- Both cases were **executed** against the reference solution (Python 3.12, `torch` 2.13.0,
  `diffusers` 0.39.0, `numpy` 2.5.1); the `out.txt` above is real program output.
- Compare **structurally**: dictionary key order is not graded, the list values are compared
  element-by-element with float tolerance **`1e-4`**. The **keys are graded** — they are the
  timesteps that ran, so a wrong `strength` truncation is caught by the keys alone
  (`{400, 200, 0}` for case 1, `{186, 124, 62, 0}` for case 2).
- **Why the return is a per-step trace, not just the final latent.** With no U-Net in the loop
  every latent position evolves independently, so the kept region's *intermediate* values can never
  influence the repainted region — and a final-latent-only return therefore **cannot** distinguish
  the correct "restore the original noised to the next timestep" from the plausible-but-wrong
  "restore the clean original at every step". Verified: with a final-latent return the two readings
  produce byte-identical output on both cases; with the trace return they differ on both. If anyone
  ever simplifies the return type, this discrimination is lost.
- Wrong readings, each **implemented and run** — all differ from the reference on **both** cases:
  - no blending at all (plain image-to-image, mask ignored);
  - restoring the **clean** `init_latent` at every step instead of the noised original;
  - restoring the original noised to the **current** timestep instead of the next one;
  - taking the **first** `num_run` rows of `noise_preds` instead of the rows for the timesteps that
    run;
  - starting from pure `noise` instead of `init_latent` noised to the first timestep that runs;
  - inverted mask polarity (treating `1.0` as "keep");
  - ignoring `strength` and running the full schedule;
  - leaving `clip_sample` at its default `True` — **unlike the L19 DDIM question, this one is
    genuinely sensitive to it**, because the repainted positions push the predicted `x₀` outside
    `[-1, 1]`. This is why the statement names it.
- **Case 1 is the only case that catches `round()` or `math.ceil()` instead of floor** for the step
  count: `5 * 0.7 = 3.5` floors to 3 but rounds/ceils to 4, while case 2's `8 * 0.5 = 4.0` is exact
  and passes all three. Never drop case 1, and keep its `strength` non-exact. This is also why the
  statement spells out "rounded down": `diffusers`' own
  `get_timesteps` uses `int(num_inference_steps * strength)`, but a learner has no way to guess
  between floor, round, and ceil.
- **Case 2 is the only case that catches a hardcoded `num_train_timesteps=1000`** (case 1's value
  *is* 1000). Case 2 also varies the latent width (4), the schedule length (8 steps, stride
  500//8 = 62), the mask polarity pattern, and uses an exact `strength`. Keep both cases.
- **Accepted equivalent:** restoring the kept region **before** the scheduler step as well as after
  (some pipeline variants do both) is verified to give byte-identical output on both cases — the
  extra restore is idempotent, since the previous iteration already left the kept region at exactly
  that noise level. Grade the returned values, not the number of restores.
- **Untested edge, deliberately:** neither case makes `int(num_inference_steps * strength)` come out
  as `0` (a `strength` below one step's worth), and the statement says nothing about that case — it
  would leave `timesteps[0]` undefined. Do not add such a case without first extending the statement
  to say what an empty run returns.
- The mask semantics (`1.0` = repaint) are stated explicitly because the real pipelines disagree
  with each other: `StableDiffusionInpaintPipeline` takes a mask where white/1 means *repaint*,
  while the internal `mask_condition` used for latent blending is inverted. A learner following
  either convention would be defensible, so the statement fixes one.
- Requires outbound network access **only** for `pip install diffusers` at image-build time — no
  weights are fetched at run time. The grader environment needs `torch` + `diffusers` + `numpy`.

---

## Q2: The Mask an Outpainting Job Actually Uses

**Context:** Extending a photo beyond its frame is inpainting with a bigger canvas: paste the
original onto a larger blank canvas, mark the new empty area white — "generate this" — and the
original black — "keep this" — and hand both to an inpainting pipeline. A hard black-and-white
boundary is what produces the visible seam everyone complains about, so production pipelines
feather the mask, blurring it slightly, before use. Feathering is not free: every pixel it softens
is a pixel of the original that is no longer strictly protected, and on a narrow extension the
softened band can eat a serious fraction of the canvas. That is worth measuring before shipping,
not after.

**Problem Statement:**

Using `Pillow`, write a function
`outpaint_mask_report(width, height, extend_right, feather_radius)`.

1. The original image is `width` × `height` and sits at the canvas's top-left corner. The canvas
   extends it to the right by `extend_right` pixels, at the same height.
2. Build the outpainting mask as a single-channel (`"L"`) image the size of the canvas, filled with
   `255` — the value marking pixels to generate — then paste `0` over the rectangle the original
   image occupies, the region to preserve.
3. Feather the mask by applying a Gaussian blur of radius `feather_radius` to it.
4. Classify every pixel of the feathered mask into exactly one of three groups: strictly preserved
   (value exactly `0`), fully generated (value exactly `255`), or blended (any value in between).
5. Return a dictionary with exactly these five keys:
   - `"canvas_width"`, `"canvas_height"` — the canvas's dimensions
   - `"preserve_px"` — how many pixels are strictly preserved
   - `"generate_px"` — how many pixels are fully generated
   - `"blend_px"` — how many pixels are blended

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: width (integer)
    Single line: one integer
  Argument 2: height (integer)
    Single line: one integer
  Argument 3: extend_right (integer)
    Single line: one integer
  Argument 4: feather_radius (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `outpaint_mask_report()` on a new line.

**Sample Input:**

```
width = 512
height = 512
extend_right = 512
feather_radius = 12
```

**Sample Output:**

```
{'canvas_width': 1024, 'canvas_height': 512, 'preserve_px': 246272, 'generate_px': 246272, 'blend_px': 31744}
```

**Note:** All five values are plain Python integers. Read the sample as a sanity check: a 12-pixel
feather on a 1024 × 512 canvas leaves 31 744 blended pixels — a band roughly 62 pixels wide down
the seam — and the strictly-preserved region is that much smaller than the 512 × 512 original.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: outpaint_mask_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. width          → Integer
2. height         → Integer
3. extend_right   → Integer
4. feather_radius → Integer
```

(`feather_radius` is the tuning knob a pipeline would default — a required argument here, since the
tool supports no argument defaults, and it is what catches a solution that skips the feather.)

**Reference Solution:**

```python
from PIL import Image, ImageFilter


def outpaint_mask_report(width: int, height: int, extend_right: int,
                         feather_radius: int) -> dict:
    canvas_width = width + extend_right

    mask = Image.new("L", (canvas_width, height), 255)
    mask.paste(0, (0, 0, width, height))
    mask = mask.filter(ImageFilter.GaussianBlur(feather_radius))

    counts = mask.histogram()

    return {"canvas_width": canvas_width,
            "canvas_height": height,
            "preserve_px": counts[0],
            "generate_px": counts[255],
            "blend_px": sum(counts[1:255])}
```

**Test Cases —** `in.txt`

```
3
512
512
512
12
512
512
88
0
384
512
256
24
```

**Test Cases —** `out.txt`

```
{'canvas_width': 1024, 'canvas_height': 512, 'preserve_px': 246272, 'generate_px': 246272, 'blend_px': 31744}
{'canvas_width': 600, 'canvas_height': 512, 'preserve_px': 262144, 'generate_px': 45056, 'blend_px': 0}
{'canvas_width': 640, 'canvas_height': 512, 'preserve_px': 165376, 'generate_px': 99840, 'blend_px': 62464}
```

**Grader Notes:**

- **Scope trace.** The outpainting canvas-and-mask construction the statement mirrors —
  `Image.new("RGB", canvas_size)`, `paste` the original at `(0, 0)`, `mask = Image.new("L",
  canvas_size, 255)`, `mask.paste(0, box)` — is `L19_Advanced_Diffusion.md:328`–`:372`, with the
  polarity comment "Black = preserve original image / White = generate new content" at `:356`–`:358`
  and `from PIL import Image, ImageFilter` at `:328`. Feathering as the fix for a visible seam:
  `:404` ("slightly feathered edges, not a hard binary cutout … most pipelines blur the mask
  slightly before use") and the quiz answer at `:512`. `ImageFilter` is imported at `:328` and
  `ImageFilter.GaussianBlur(40)` is called at `:563`, on a synthetic style reference rather than on a
  mask — so the API itself is demonstrated, and only **applying** it to a mask is new.
  **Disclosed, not taught:** the three-way pixel classification (exact `0` / exact `255` /
  in between), which is the question's own measurement rather than anything the material performs.
- All three cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `Pillow` 12.3.0); the `out.txt` above is real program output. All values are exact integers —
  compare them exactly; key order is not graded.
- **Case 2 (`feather_radius = 0`) is the only case that catches an inverted mask polarity**
  building the mask filled with `0` and pasting `255` over the original — case 1 is symmetric
  (512 preserve / 512 generate), so inverting it returns identical counts. Case 3 catches it too.
  Never drop case 2.
- **Cases 1 and 3 are the only cases that catch a skipped feather** (case 2's radius is already 0,
  so no blur is a no-op there) and a solution that classifies at a threshold — `< 128` preserve,
  `>= 128` generate — instead of at exact `0` / `255`, which reports `blend_px: 0`.
- Wrong readings, each **implemented and run**: skipping the blur (differs on cases 1 and 3);
  inverted polarity (differs on cases 2 and 3); thresholding at 128 (differs on cases 1 and 3).
- **Accepted equivalents, verified to give identical counts on all three cases:** `mask.histogram()`
  (the reference), `numpy.asarray(mask)` with `(a == 0).sum()` / `(a == 255).sum()`, and
  `list(mask.getdata())` with a comprehension. Note `Image.getdata()` raises a
  `DeprecationWarning` on Pillow 12 — to stderr, so graded stdout is unaffected; do not mark it
  down.
- `ImageFilter.GaussianBlur(0)` is a valid no-op, verified: it returns the unblurred mask rather
  than raising.
- **Version sensitivity.** Pillow's Gaussian blur is a box-blur approximation, so `blend_px` is an
  implementation detail of the installed Pillow. Pin `Pillow` in the grader image (verified on
  12.3.0) and regenerate `out.txt` if that pin moves. `canvas_width` / `canvas_height` and case 2's
  three counts are version-independent.
- No network access and no weights. The grader environment needs `Pillow` only.

---

## Q3: Registering a New Concept's Placeholder Token

**Context:** Textual inversion teaches a checkpoint a concept it has never seen without touching a
single model weight: it invents one new "word" — a placeholder token such as `<my-dog>` — and
learns the embedding vector for it. The token has to be added to the text tokenizer's vocabulary
first, and that step has a trap on either side of it. Pick a placeholder that is already an
ordinary English word and it silently collides with the concept the model already has for that
word; skip the check and re-run the same registration code twice and you try to add a token that is
already there. A registration pass therefore has to look before it adds, and report exactly which
candidates were genuinely new.

**Problem Statement:**

Using the `transformers` library, write a function `register_placeholder_tokens(candidate_tokens)`.

1. Build a CLIP tokenizer with `CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")`
   **inside** the function, so every call starts from the checkpoint's own base vocabulary.
2. Walk `candidate_tokens` in the order given. For each candidate, check whether it is already a key
   in the tokenizer's vocabulary, and add it to the tokenizer only if it is not.
3. Look up that candidate's token id in the tokenizer after the decision in step 2.
4. Return a dictionary keyed by candidate token, whose value is a two-element list: the token id
   from step 3, then `True` if you added the token and `False` if it was already in the vocabulary.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: candidate_tokens (list_string)
    Line 1: N (list length)
    Next N lines: one string each
```

**Output Format:**

For each test case, print the result of `register_placeholder_tokens()` on a new line.

**Sample Input:**

```
candidate_tokens = ["<my-dog>", "dog", "<watercolor-style>"]
```

**Sample Output:**

```
{'<my-dog>': [49408, True], 'dog': [4326, False], '<watercolor-style>': [49409, True]}
```

**Note:** Build the tokenizer inside the function rather than at module level — a shared tokenizer
would carry tokens added by one call into the next one, and the ids would drift. Return ids as plain
Python integers and the flags as plain Python booleans. Read the sample as a sanity check: the two
angle-bracketed placeholders are new and land on consecutive ids past the end of the base
vocabulary, while `dog` was already a word the tokenizer knew.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: register_placeholder_tokens
RETURN TYPE: Dictionary

ARGUMENTS:
1. candidate_tokens → List of Strings
```

**Reference Solution:**

```python
from transformers import CLIPTokenizer


def register_placeholder_tokens(candidate_tokens: list) -> dict:
    tokenizer = CLIPTokenizer.from_pretrained("openai/clip-vit-base-patch32")

    report = {}
    for token in candidate_tokens:
        already_known = token in tokenizer.get_vocab()
        if not already_known:
            tokenizer.add_tokens([token])
        report[token] = [int(tokenizer.convert_tokens_to_ids(token)), not already_known]
    return report
```

**Test Cases —** `in.txt`

```
2
3
<my-dog>
dog
<watercolor-style>
3
art
sks
<my-logo>
```

**Test Cases —** `out.txt`

```
{'<my-dog>': [49408, True], 'dog': [4326, False], '<watercolor-style>': [49409, True]}
{'art': [1486, False], 'sks': [49408, True], '<my-logo>': [49409, True]}
```

**Grader Notes:**

- **Scope trace.** Textual inversion inventing one new token and leaving every weight untouched:
  `L19_Advanced_Diffusion.md:730`, with `--placeholder_token="<my-dog>"` /
  `--initializer_token="dog"` at `:742`–`:743`. The vocabulary guard the question is built around is
  that section's own code: `if "<cat-toy>" not in pipe.tokenizer.get_vocab():` at `:753`, with the
  comment "avoids the 'already in vocabulary' error if this cell is re-run" at `:752`. That only
  the text encoder's vocabulary gains an entry: `L18_Diffusion_Models_Lecture_2.md:349`.
  **Disclosed, not taught:** building a `CLIPTokenizer` standalone, `add_tokens`, and
  `convert_tokens_to_ids` — the material reaches the tokenizer only through a loaded pipeline and
  adds the token via `load_textual_inversion`, which needs weights and a GPU.
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `transformers` 5.15.0), **both in one process**, which is what proves the per-call tokenizer works
  (case 2's new ids come back as 49408/49409, not 49410/49411). The `out.txt` above is real program
  output. All values are exact — compare them exactly; key order is not graded.
- **Deliver these two cases as a single `in.txt` with `T = 2`.** Split into two one-case files they
  no longer catch a **module-level tokenizer**, which is the second wrong reading below.
- Wrong readings, each **implemented and run**:
  - **no guard** — calling `add_tokens` on every candidate and reporting its return count as the
    flag. Differs on both cases: it reports `'dog': [4326, True]` (case 1) and `'art': [1486, True]`
    (case 2). Note the *ids* are unaffected — `add_tokens` on a word already in the vocabulary
    returns 1 but leaves the id alone — so the flag is the only thing that catches this, which is
    why the flag is part of the return value.
  - **module-level tokenizer** shared across calls. Case 1 passes; case 2 returns
    `{'art': [1486, False], 'sks': [49410, True], '<my-logo>': [49411, True]}` because case 1
    already grew the vocabulary. Caught only when both cases run in one process — see the delivery
    note above.
- **Accepted equivalent, verified on every candidate in both cases:** guarding with
  `tokenizer.convert_tokens_to_ids(token) != tokenizer.convert_tokens_to_ids(tokenizer.unk_token)`
  instead of `token in tokenizer.get_vocab()` gives the same verdict for all six candidates
  (`dog` → 4326, `art` → 1486, the four placeholders → the unk id 49407 before being added).
  `tokenizer.vocab` and `tokenizer.get_vocab()` are likewise interchangeable — both reflect tokens
  added earlier in the same pass, verified. Grade the returned
  values, not the route.
- **The candidates are chosen, not incidental.** `dog` and `art` are ordinary words the base
  vocabulary already holds, `sks` is not (it is a rare token DreamBooth-style workflows lean on),
  and the two angle-bracketed placeholders are not. Case 2 puts the already-known word **first**,
  so a solution that assumes the first candidate is always new fails it.
- **Untested edge, deliberately:** no case repeats a candidate, so nothing depends on what a
  duplicate does (the returned dictionary would collapse to one entry, with the second visit
  reporting `False`). A duplicate is the exact re-run scenario the guard exists for, so if a case is
  ever added for it, say in the statement which entry survives.
- Needs the **HF Hub at grading time** — `vocab.json` + `merges.txt`, about 1.7 MB, no model
  weights. `from_pretrained` runs once per call here, which is the cost of correctness; measured
  end to end, the two-case run above takes 3.7 s of wall clock against a warm cache. The grader
  environment needs `transformers` and nothing else for this question.

---

## Q4: Shared Latents Against Frame Flicker

**Context:** A video model that draws every frame from its own fresh noise flickers: textures boil,
backgrounds crawl, and a face drifts over a few seconds. The cheapest fix in the toolbox is to stop
drawing fresh noise per frame at all — reuse one latent for the whole clip, so the only thing
varying between frames is the motion module's work rather than the starting canvas. It is worth
measuring the options before picking one, because the obvious middle road — bump the seed by one per
frame — buys nothing at all: a different seed is a different noise pattern, which is exactly what
the clip was trying to avoid.

**Problem Statement:**

Using `torch`, write a function
`frame_latent_drift(seed, num_frames, latent_height, latent_width, latent_channels, strategies)`.

1. Every frame's latent has shape `(latent_channels, latent_height, latent_width)`, and a clip has
   `num_frames` of them.
2. `strategies` names the noise strategies to measure, in the order given. Build a clip's frame
   latents for each named strategy with `torch.randn` and a CPU `torch.Generator`:
   - `"independent"` — one generator, seeded once with `seed`; draw one frame latent per frame, in
     frame order, from that same generator.
   - `"shared"` — draw one frame latent from a generator seeded with `seed`, and use that same
     tensor for every frame.
   - `"per_frame_seed"` — for frame `i` (0-based), a freshly created generator seeded with
     `seed + i`, drawing that frame's latent.
3. Measure a clip's drift like this: for each consecutive pair of frames, take the mean of the
   absolute differences across every value of the two latents; then average those per-pair numbers
   over all the pairs.
4. Return a dictionary mapping each strategy name in `strategies` to its drift, rounded to 4 decimal
   places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: seed (integer)
    Single line: one integer
  Argument 2: num_frames (integer)
    Single line: one integer
  Argument 3: latent_height (integer)
    Single line: one integer
  Argument 4: latent_width (integer)
    Single line: one integer
  Argument 5: latent_channels (integer)
    Single line: one integer
  Argument 6: strategies (list_string)
    Line 1: N (list length)
    Next N lines: one string each
```

**Output Format:**

For each test case, print the result of `frame_latent_drift()` on a new line.

**Sample Input:**

```
seed = 42
num_frames = 8
latent_height = 64
latent_width = 64
latent_channels = 4
strategies = ["independent", "shared", "per_frame_seed"]
```

**Sample Output:**

```
{'independent': 1.1343, 'shared': 0.0, 'per_frame_seed': 1.1268}
```

**Note:** Return plain Python floats, not torch scalars. Leave the generator on the CPU and take
`torch.randn`'s default dtype. Read the sample as a sanity check on what the three strategies buy:
one of them is the only one that actually holds the starting canvas still.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: frame_latent_drift
RETURN TYPE: Dictionary

ARGUMENTS:
1. seed            → Integer
2. num_frames      → Integer
3. latent_height   → Integer
4. latent_width    → Integer
5. latent_channels → Integer
6. strategies      → List of Strings
```

(`num_frames` (16 in most motion adapters) and `latent_channels` (4) are fixed or defaulted in the
real pipeline API — required arguments here, since the tool supports no argument defaults.)

**Reference Solution:**

```python
import torch


def frame_latent_drift(seed: int, num_frames: int, latent_height: int,
                       latent_width: int, latent_channels: int, strategies: list) -> dict:
    shape = (latent_channels, latent_height, latent_width)

    report = {}
    for strategy in strategies:
        if strategy == "independent":
            generator = torch.Generator().manual_seed(seed)
            frames = [torch.randn(shape, generator=generator) for _ in range(num_frames)]
        elif strategy == "shared":
            generator = torch.Generator().manual_seed(seed)
            frames = [torch.randn(shape, generator=generator)] * num_frames
        else:  # "per_frame_seed"
            frames = [torch.randn(shape, generator=torch.Generator().manual_seed(seed + i))
                      for i in range(num_frames)]

        gaps = [float((frames[i + 1] - frames[i]).abs().mean())
                for i in range(num_frames - 1)]
        report[strategy] = round(sum(gaps) / len(gaps), 4)
    return report
```

**Test Cases —** `in.txt`

```
2
42
8
64
64
4
3
independent
shared
per_frame_seed
7
4
32
48
4
2
shared
independent
```

**Test Cases —** `out.txt`

```
{'independent': 1.1343, 'shared': 0.0, 'per_frame_seed': 1.1268}
{'shared': 0.0, 'independent': 1.129}
```

**Grader Notes:**

- **Scope trace.** "Fixed seed + shared latents — Reuses the same initial noise pattern across
  frames" is the first row of the temporal-coherence table at
  `L19_Advanced_Diffusion_Part_2.md:942`; the three failure modes the question is motivated by
  (flicker, identity drift, background instability) are `:934`–`:936`; the AnimateDiff pipeline
  whose frame latents these are runs at `:803`–`:924`. **Disclosed, not taught:** the drift metric,
  building the frame latents by hand, and the `"per_frame_seed"` contrast — the table names the fix
  but never quantifies it, so the numbers have to come from the library.
- **Cross-class note.** The *concept* is Class 19's (the table row above), but the *API* —
  `torch.Generator(...).manual_seed(seed)` — is demonstrated in **Class 18's** material
  (`L18_Diffusion_Models_Lecture_2.md:422`, `:560`), not in Class 19's, and `torch.randn` appears in
  no diffusion file at all. Both are named in the statement, so nothing has to be recalled from the
  neighbouring class; a learner meeting seeds for the first time here can still follow the steps.
  Do not remove those names from the statement on the grounds that seeds were "already covered".
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `torch` 2.13.0); the `out.txt` above is real program output. Compare with a float tolerance of
  `1e-4`; key order is not graded, though the reference preserves the order of `strategies`.
- **`"shared"` is exactly `0.0` by construction** — every frame is the same tensor. That value is
  guessable; the other two are not, and a submission is only correct if all of them match. Case 2
  lists the strategies in the other order and drops `"per_frame_seed"`, so a solution that assumes
  a fixed set or a fixed order fails it.
- `"independent"` and `"per_frame_seed"` are both ~1.128 — the expected absolute gap between two
  standard normals — because re-seeding per frame gives statistically independent frames just as one
  continuous stream does. They are nonetheless **different** draws, so the two values differ in the
  third decimal (1.1343 vs 1.1268 on case 1); a solution that computes one and reuses it fails.
  That near-equality is the point of the question, and it is why the tolerance is `1e-4` and not
  looser.
- Wrong readings, each **implemented and run** — both differ from the reference on **both** cases:
  - **treating `"per_frame_seed"` as one continuous stream** (and `"independent"` as a re-seed per
    frame) — the two strategies swap, giving `{'independent': 0.0, 'shared': 0.0,
    'per_frame_seed': 1.1343}` on case 1;
  - **measuring the difference of the frame means** instead of the mean of the absolute differences
    — case 1 → `{'independent': 0.0082, 'shared': 0.0, 'per_frame_seed': 0.0074}`.
- **Accepted equivalent, verified byte-identical on both cases:** drawing `"independent"` as one
  `torch.randn((num_frames, latent_channels, latent_height, latent_width), generator=g)` call and
  splitting it into frames. `torch.randn` fills sequentially from the generator, so a single batched
  draw and `num_frames` per-frame draws produce the same values. Grade the returned values, not the
  route.
- **Untested edge, deliberately:** neither case sets `num_frames` to 1, and the statement says
  nothing about a one-frame clip (there are no pairs to average, so the reference divides by zero).
  Do not add such a case without extending the statement. The reference's `else` branch is
  `"per_frame_seed"`; no case passes a name outside the three, and the statement does not define
  one.
- torch's CPU generator is deterministic for a fixed seed on a fixed build, but is **not** contract
  guaranteed across torch releases: pin `torch` in the grader image (verified on 2.13.0) and
  regenerate `out.txt` if that pin moves. Only `"shared"`'s `0.0` is version-independent.
- No network access and no weights at run time. The grader environment needs `torch` only.

---

## Q5: How Much of the Input Survives at Each `strength`

**Context:** Image-to-image does not blend the input with the output. It noises the input part of the
way up the ladder and starts denoising from there, so `strength` is a *noise level*, not an opacity.
That is why the parameter behaves so unevenly: the difference between 0.2 and 0.4 is a light retouch
against a real edit, while 0.9 and 1.0 both amount to starting over. Anyone tuning the dial is really
asking one question — how much of my image is still in there when the loop starts — and the schedule
answers it exactly.

**Problem Statement:**

Using the `diffusers` library, write a function
`strength_survival(strengths, num_inference_steps, num_train_timesteps)`.

1. Build a `diffusers.DDIMScheduler` with the given `num_train_timesteps` and every other scheduler
   setting left at the library default — `timestep_spacing` included, which means `"leading"`; do not
   carry over an override from anywhere else. Call `set_timesteps(num_inference_steps)` on it and read
   the schedule off `scheduler.timesteps`, which runs from noisiest to cleanest.
2. For each value in `strengths`, work out how much of that schedule actually runs: the number of steps
   is `num_inference_steps * strength` **rounded down** to a whole number — every `strength` is no larger than 1 and
   large enough that at least one step runs, so that count is between 1 and `num_inference_steps` — and the steps that run are
   the **last** ones — the high-noise front of the schedule is skipped, which is what keeps the result
   close to the input.
3. The loop therefore starts at the first timestep that actually runs. The scheduler exposes the
   cumulative product of its schedule as `alphas_cumprod`; the fraction of the input still present at
   a timestep is the **square root** of that cumulative product at that timestep.
4. Return a dictionary mapping each value in `strengths` to a two-element list: the number of steps
   that run, then the fraction of the input still present at the timestep the loop starts from,
   rounded to 4 decimal places.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: strengths (list_float)
    Line 1: N (list length)
    Next N lines: one float each
  Argument 2: num_inference_steps (integer)
    Single line: one integer
  Argument 3: num_train_timesteps (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `strength_survival()` on a new line.

**Sample Input:**

```
strengths = [0.2, 0.7, 1.0]
num_inference_steps = 30
num_train_timesteps = 1000
```

**Sample Output:**

```
{0.2: [6, 0.8651], 0.7: [21, 0.1091], 1.0: [30, 0.0096]}
```

**Note:** The input handling is already in place — you only need to implement the function. Step counts
are plain Python integers and fractions plain Python floats. Read the sample as a sanity check on why
the dial feels so uneven: at 0.2 most of the input is still there, at 0.7 only about a tenth of it is,
and at 1.0 there is essentially nothing left to preserve.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: strength_survival
RETURN TYPE: Dictionary

ARGUMENTS:
1. strengths           → List of Floats
2. num_inference_steps → Integer
3. num_train_timesteps → Integer
```

(`num_inference_steps` (50 in the pipelines), `strength` (0.8) and `num_train_timesteps` (1000) are all
defaulted in the real API — required here since the tool supports no argument defaults.)

**Reference Solution:**

```python
from diffusers import DDIMScheduler


def strength_survival(strengths: list, num_inference_steps: int,
                      num_train_timesteps: int) -> dict:
    scheduler = DDIMScheduler(num_train_timesteps=num_train_timesteps)
    scheduler.set_timesteps(num_inference_steps)
    surviving = scheduler.alphas_cumprod.sqrt()

    report = {}
    for strength in strengths:
        steps_run = int(num_inference_steps * strength)
        first = num_inference_steps - steps_run
        start_timestep = int(scheduler.timesteps[first])
        report[strength] = [steps_run, round(float(surviving[start_timestep]), 4)]
    return report
```

**Test Cases —** `in.txt`

```
2
3
0.2
0.7
1.0
30
1000
2
0.4
0.95
50
1000
```

**Test Cases —** `out.txt`

```
{0.2: [6, 0.8651], 0.7: [21, 0.1091], 1.0: [30, 0.0096]}
{0.4: [20, 0.4762], 0.95: [47, 0.0137]}
```

**Grader Notes:**
- **QC BLOCKER fixed, 2026-08-31 — no expected output moved.** The statement said "leaving every other
  scheduler setting at its default", but **the only `DDIMScheduler` construction in this question's own
  class sets a non-default `timestep_spacing`** —
  `modules/03-agentic-ai-systems/markdown/L19_Advanced_Diffusion_Part_2.md:836`–`:841`
  (`DDIMScheduler.from_pretrained(… clip_sample=False, timestep_spacing="linspace")`). Copying it
  scores **zero on every fraction in both cases**: measured `{0.2: [6, 0.8547], 0.7: [21, 0.0895],
  1.0: [30, 0.0064]}` against the shipped `0.8651 / 0.1091 / 0.0096`. `clip_sample=False` is harmless.
  The statement now pins `timestep_spacing` to the library default `"leading"` outright and tells the
  learner not to carry an override over. Note that under `"leading"` the schedule tops out at t=957,
  not 999.
- Also 2026-08-31: `set_timesteps` and `scheduler.timesteps` are now **named** (both absent from every
  module-3 lecture file — the earlier note claiming they were already named was wrong); the statement
  now states **`0 < strength <= 1`**, and the two clamps that bound rested on
  (`min(int(n*strength), n)` and `max(n - steps_run, 0)`) were removed from the reference as
  unreachable dead code. The unused `import torch` came out. Both cases re-run byte-identical.
  Residual, unchanged: a `strength` below one step's worth still makes the reference raise
  `IndexError`; the stated bound does not exclude it, so do not add such a case.

- **Scope trace.** `strength` as a noise level rather than a blend, and the reverse process starting
  partway up the ladder: `modules/03-agentic-ai-systems/markdown/L19_Advanced_Diffusion.md:43`
  ("instead of starting the reverse diffusion process from pure Gaussian noise at timestep T, we take
  our input image, partially noise it up to some intermediate timestep, and then run the denoising
  process from there. The less noise we add (lower `strength`), the closer the output stays to the
  input"). The three bands this question makes quantitative are `:192`–`:194`
  (0.2–0.3 "same composition"; 0.5–0.7 "silhouette and rough composition survive"; 0.9+ "looks like a
  fresh text-to-image generation"), with the `strength=1.0` case called out at `:196` ("you've
  essentially replaced it with pure noise") and again in the quiz explanation at `:211`. **Both test
  cases reproduce step counts the material itself prints:** the `strengths = [0.2, 0.7, 1.0]` sweep at
  `:133` records progress bars `0/6`, `0/21`, `0/30` (`:158`, `:168`, `:178`), and the
  `strength=0.95` inpainting call over 50 steps records `0/47` (`:320`). **Disclosed, not taught:**
  `DDIMScheduler`, `set_timesteps`, `alphas_cumprod`, and the truncation arithmetic — the material
  shows the *effect* of `strength` but never the schedule slicing, so the statement spells the rule out.
- **The quantity being reported belongs to Class 18, not Class 19.** `\sqrt{\bar\alpha_t}` — "a single
  number summarizing how much of the *original image* survives by step t" — is
  `L18_Diffusion_Models_Lecture.md:966`/`:969`, and `alphas_cumprod` appears in no diffusion file at
  all. What Class 19 owns is the *question* ("how much of my input is still in there when the loop
  starts", `L19_Advanced_Diffusion.md:43`) and the qualitative answer (`:192`–`:194`); this question
  supplies the measurement. Step 3 of the statement therefore defines the fraction outright rather than
  assuming it, which is what keeps the question self-contained for a learner meeting it here first.
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `diffusers` 0.40.0, `torch` 2.13.0); the `out.txt` above is real program output. Compare the
  fractions with a float tolerance of `1e-4` and the step counts exactly; key order is not graded.
- **"Rounded down" is stated because a learner cannot guess it.** `diffusers`' own `get_timesteps`
  uses `int(num_inference_steps * strength)`, but floor, round and ceil are all defensible readings.
- **Case 2 is the only case that catches ceil-instead-of-floor.** Every product in case 1 is already a
  whole number (30 × 0.2 = 6, 30 × 0.7 = 21, 30 × 1.0 = 30), so floor and ceil agree there; case 2's
  50 × 0.95 = 47.5 is the only value that separates them (47 against 48). Never drop case 2.
- Wrong readings, each **implemented and run**: `ceil` instead of floor (differs on case 2 only, see
  above); keeping the **front** of the schedule instead of the tail, i.e. always starting from
  `timesteps[0]` (differs on both cases); reporting the *noise* fraction `sqrt(1 - abar)` instead of
  the surviving fraction (differs on both cases).
- **Untested edge, deliberately:** no case makes `int(num_inference_steps * strength)` come out as `0`
  (a `strength` below one step's worth), which would leave the start timestep undefined. The statement
  says nothing about it; do not add such a case without extending it first.
- No network access and no weights. The grader environment needs `torch` + `diffusers`.

---

## Q6: Proving ControlNet Starts by Doing Nothing

**Context:** ControlNet adds spatial control to a checkpoint without damaging it, and the claim that
it leaves the base model's behaviour intact is not a matter of trust — it is built into how the
adapter is initialised. ControlNet is a trainable copy of the U-Net's encoder that feeds its features
back into the frozen base model through a set of convolutions deliberately initialised to **zero**,
so that before any training happens the injected signal is exactly nothing and the base model behaves
as if the adapter were not attached. The conditioning image's own encoder ends the same way. That is a
property you can verify on a freshly built adapter in a few lines, and it is worth verifying, because
it is the entire safety argument for attaching one.

**Problem Statement:**

Using the `diffusers` library, write a function `controlnet_injection_profile(block_out_channels,
layers_per_block, cross_attention_dim, conditioning_embedding_out_channels)`.

1. Build a `diffusers.ControlNetModel` with 4 input channels, the given `block_out_channels` (whose
   length is the number of levels), `layers_per_block` and `cross_attention_dim`, a plain
   `"DownBlock2D"` at every level, and the given `conditioning_embedding_out_channels`. Leave every
   other setting at its default.
2. The convolutions that inject features back into the base model are the model's
   `controlnet_down_blocks`, plus its single `controlnet_mid_block`. Count them, and check whether
   **every** one of them has both weights and bias exactly zero.
3. Check whether the weights of the conditioning-image encoder's output convolution,
   `controlnet_cond_embedding.conv_out`, are zero too.
4. For contrast, check whether the weights of an ordinary convolution inside the adapter's own
   backbone — `down_blocks[0].resnets[0].conv1` — are zero.
5. Count the parameters in the adapter's own mid block, `mid_block`.
6. Return a dictionary with exactly these six keys:
   - `"n_injection_convs"` — how many injection convolutions there are, mid block included
   - `"injection_convs_all_zero"` — whether all of them are entirely zero
   - `"cond_embedding_output_zero"` — whether the conditioning encoder's output convolution is zero
   - `"backbone_conv_zero"` — whether the ordinary backbone convolution is zero
   - `"mid_block_params"` — the adapter's own mid block's parameter count
   - `"total_params"` — the adapter's total parameter count

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: block_out_channels (list_int)
    Line 1: N (list length)
    Next N lines: one integer each
  Argument 2: layers_per_block (integer)
    Single line: one integer
  Argument 3: cross_attention_dim (integer)
    Single line: one integer
  Argument 4: conditioning_embedding_out_channels (list_int)
    Line 1: M (list length)
    Next M lines: one integer each
```

**Output Format:**

For each test case, print the result of `controlnet_injection_profile()` on a new line.

**Sample Input:**

```
block_out_channels = [32, 64]
layers_per_block = 1
cross_attention_dim = 32
conditioning_embedding_out_channels = [8, 16]
```

**Sample Output:**

```
{'n_injection_convs': 5, 'injection_convs_all_zero': True, 'cond_embedding_output_zero': True, 'backbone_conv_zero': False, 'mid_block_params': 252096, 'total_params': 390104}
```

**Note:** The input handling is already in place — you only need to implement the function. Return
plain Python integers and booleans. No weights are downloaded: the adapter is constructed from the
configuration you pass. Read the sample as a sanity check on the claim being tested: the contrast
between the injection convolutions and the ordinary backbone convolution is the answer to "why is
attaching a ControlNet safe?".

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: controlnet_injection_profile
RETURN TYPE: Dictionary

ARGUMENTS:
1. block_out_channels                  → List of Ints
2. layers_per_block                    → Integer
3. cross_attention_dim                 → Integer
4. conditioning_embedding_out_channels → List of Ints
```

(All four are defaulted in `ControlNetModel` — required here since the tool supports no argument
defaults, and they are what makes `n_injection_convs` and `total_params` vary between cases.)

**Reference Solution:**

```python
from diffusers import ControlNetModel


def controlnet_injection_profile(block_out_channels: list, layers_per_block: int,
                                 cross_attention_dim: int,
                                 conditioning_embedding_out_channels: list) -> dict:
    levels = len(block_out_channels)
    controlnet = ControlNetModel(
        in_channels=4,
        block_out_channels=tuple(block_out_channels),
        layers_per_block=layers_per_block,
        down_block_types=("DownBlock2D",) * levels,
        cross_attention_dim=cross_attention_dim,
        conditioning_embedding_out_channels=tuple(conditioning_embedding_out_channels),
    )

    count = lambda module: sum(p.numel() for p in module.parameters())
    injection = list(controlnet.controlnet_down_blocks) + [controlnet.controlnet_mid_block]
    is_zero = lambda tensor: float(tensor.detach().abs().sum()) == 0.0
    backbone = controlnet.down_blocks[0].resnets[0].conv1.weight

    return {"n_injection_convs": len(injection),
            "injection_convs_all_zero": all(is_zero(c.weight) and is_zero(c.bias) for c in injection),
            "cond_embedding_output_zero": is_zero(controlnet.controlnet_cond_embedding.conv_out.weight),
            "backbone_conv_zero": is_zero(backbone),
            "mid_block_params": count(controlnet.mid_block),
            "total_params": count(controlnet)}
```

**Test Cases —** `in.txt`

```
2
2
32
64
1
32
2
8
16
3
32
64
128
2
64
2
16
32
```

**Test Cases —** `out.txt`

```
{'n_injection_convs': 5, 'injection_convs_all_zero': True, 'cond_embedding_output_zero': True, 'backbone_conv_zero': False, 'mid_block_params': 252096, 'total_params': 390104}
{'n_injection_convs': 10, 'injection_convs_all_zero': True, 'cond_embedding_output_zero': True, 'backbone_conv_zero': False, 'mid_block_params': 971136, 'total_params': 1874832}
```

**Grader Notes:**
- **QC fixes, 2026-08-31 — the expected outputs changed; both cases re-run in fresh processes.**
  (1) The Note used to say "three of the four checks come back one way and one comes back the other",
  which hands over the entire boolean pattern; those three booleans are input-independent
  (`True`/`True`/`False` over 20 fresh builds), so the sentence was the answer. Removed.
  (2) Steps 3 and 4 demanded "both weights and bias" while the reference checks only `.weight`. Both
  readings give identical booleans on both cases (`zero_module` zeroes the conditioning `conv_out`'s
  bias too, and the backbone conv's weight is non-zero regardless of its bias), so the statement was
  aligned to weights-only, matching what the reference does.
  (3) A sixth key **`"mid_block_params"`** was added. It is one of only two values here with no closed
  form in the arguments, and the only key besides `total_params` that responds to
  `cross_attention_dim` (case 1: 32 → 252096, 64 → 256192, 128 → 264384). Case 1 = 252096,
  case 2 = 971136.
- **Rejected keys, each measured (2026-08-31).** `injection_conv_out_channels` was proposed and
  **fully predicted from the arguments alone** on 4/4 configurations — one leading conv at
  `block_out_channels[0]`, then `layers_per_block` convs per level plus a downsampler conv on every
  level but the last, then the mid conv at `block_out_channels[-1]` — so it carries no information
  beyond `n_injection_convs`. Per-injection-conv parameter counts are `c*c + c`, derivable from those.
  `controlnet_mid_block.weight`'s shape is `[boc[-1], boc[-1], 1, 1]`. `n_zero_init_tensors` (24 / 42)
  is also closed-form and is mostly GroupNorm biases, which muddies the zero-init lesson. A viable
  alternative to `mid_block_params`, if `conditioning_embedding_out_channels` ever needs covering
  directly, is `cond_embedding_params` (6616 / 16656).

- **Scope trace.** The claim this question verifies is stated in one sentence of the class's own
  ControlNet section: `L19_Advanced_Diffusion.md:415` — "ControlNet is a trainable copy of the U-Net's
  encoder blocks that takes the conditioning image (e.g., a Canny edge map) as an additional input and
  **injects features into the frozen base model via 'zero convolutions,' so the base model's original
  capabilities are preserved** while gaining a new spatial constraint." §3 opens at `:410`, the
  tracing-paper analogy is `:413`, and `ControlNetModel` is imported at `:418` and instantiated at
  `:458` of that section's own code. **Disclosed, not taught:** every attribute path (`controlnet_down_blocks`,
  `controlnet_mid_block`, `controlnet_cond_embedding.conv_out`, `down_blocks[0].resnets[0].conv1`) —
  the material loads a pretrained adapter and never opens it, so the statement names each one.
  Navigating the object is the contract; the skill under test is understanding *what* zero
  initialisation buys and being able to tell the injection path from the backbone.
- Both cases were **executed** through a portal-style stdin harness (Python 3.12.13,
  `diffusers` 0.40.0, `torch` 2.13.0); the `out.txt` above is real program output. Values are exact
  integers and booleans — compare exactly; key order is not graded.
- **`backbone_conv_zero` is the load-bearing key.** Without it a learner could return `True` for
  everything and look correct on the three zero checks. It is `False` because that convolution is
  randomly initialised like the rest of the backbone — its absolute weight sum lands around 270 on
  these configs. **Do not grade that magnitude**: it is seed-dependent and no seed is set. Only the
  boolean is stable, which is why the statement asks for a check rather than a value.
- **`n_injection_convs` is not `len(block_out_channels)`.** There is one injection convolution per
  down-block residual output: one for the initial convolution, then `layers_per_block` per level plus
  one more for every level that downsamples, plus the single mid block. Verified against the built
  model for both cases — `1 + (1+1) + (1+0) + 1 = 5` for case 1 and
  `1 + (2+1) + (2+1) + (2+0) + 1 = 10` for case 2, where the last level never downsamples. A learner cannot derive it from the config
  without either knowing ControlNet's structure or asking the model, which is the point. Case 2
  varies levels, `layers_per_block`, `cross_attention_dim` and the conditioning widths together, so it
  catches any hardcoded count.
- **Channel widths must be multiples of 32** (default `norm_num_groups=32`), exactly as in the U-Net
  question; `conditioning_embedding_out_channels` is not normed and may be smaller. Both cases respect
  this.
- **Parameter counts and the zero checks do not depend on initialisation**, so no seed is needed and
  the output is stable across runs — verified by building each config twice.
- Wrong readings, each **implemented and run** — both differ from the reference on **both** cases:
  omitting the mid block from the injection count (4 and 9 instead of 5 and 10); checking only the
  weights and not the biases (which happens to give the same booleans here, so this one is **not**
  caught — recorded deliberately: the biases are zero too, so a weights-only check scores correctly.
  Do not claim this is graded); reporting `backbone_conv_zero` as `True` by checking one of the
  injection convolutions instead of the backbone one.
- No network access and no weights. Each case builds in about 10 ms. The grader environment needs
  `torch` + `diffusers`.
