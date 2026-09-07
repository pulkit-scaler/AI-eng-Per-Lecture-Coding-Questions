# Per-Lecture Coding Questions

One file per lecture, each with **2–3 fresh coding questions** authored for the portal's
**ML Function Descriptor** tool (created via the `creating-ml-function-descriptor-questions`
workflow). These are distinct from the topic-organized banks in
[`../bascis-of-gen-ai-coding-ques.md`](../bascis-of-gen-ai-coding-ques.md) and
[`../advanced-ai-agents-coding-ques.md`](../advanced-ai-agents-coding-ques.md) — this set is a
deliberate, lecture-by-lecture pass so every lecture in a module has dedicated coverage.

Module 1 (Basics of GenAI) files are named `L<n>-…`; later modules carry a module prefix
(`M2-L<n>-…`) so lecture numbers don't collide across modules.

Every question is designed to fit the tool's hard constraints (no argument defaults → all
params required; fixed argument/return types; a single return value; `List of Dicts` is an
**argument-only** type; ranked/record outputs folded into a `Dictionary`; no
`if __name__ == "__main__"` harness in the reference solution).

Each file contains, per question: the **student-facing problem statement**, then clearly
marked **internal** sections (ML Function Descriptor config, reference solution, `in.txt`/
`out.txt` test cases, and grader notes).

## Lecture index — Module 1: Basics of GenAI

> **Authoritative lecture numbering.** The `modules/01-basics-of-gen-ai/markdown/L<n>_*.md`
> filenames are the only authoritative numbering for this module, and the `[Class N]` tags in
> [`01-basics-of-gen-ai/Coding_Ques_Module_1_Basics_of_GenAI.ipynb`](01-basics-of-gen-ai/Coding_Ques_Module_1_Basics_of_GenAI.ipynb)
> follow them. An earlier revision of this table numbered Prompt Engineering: Introduction as L4,
> Prompt Engineering: Security as L5, Embeddings as L6, RAG as L7 and Eval Pipelines as L9 — that
> order was **wrong** and contradicted the notebook's tags. Never take a class number from an index
> file; read it off the markdown filename.

| # | Lecture | Questions in the notebook |
|---|---------|---------------------------|
| 1 | Introduction to AI Engineering | Distance-metric ranking · FAISS `IndexFlatL2` retrieval |
| 2 | Refresher: Modern Text & Image Architectures | Multi-head causal self-attention |
| 3 | Getting Started with Text Generation & LLM APIs | Top-k sampling decoder · Repetition-penalty logits processor · Beam search (length-normalised) · Temperature-scaled softmax & entropy |
| 4 | Designing Eval Pipelines & Observability | ROUGE-L (F1) · Sentence-level BLEU · BERTScore |
| 5 | Prompt Engineering: Introduction | Packing a RAG prompt under a token budget |
| 6 | Retrieval-Augmented Generation (RAG): Introduction | Fixed-size token chunking with overlap · Metadata-filtered semantic search · Recursive chunking |
| 7 | Embeddings Deep Dive | NDCG@K · Hard-negative mining · Recall@K & MRR · Triplet loss |
| 8 | Multimodal RAG | CLIP symmetric contrastive loss · Zero-shot classification · Chroma cross-modal retrieval · Caption matching |
| 9 | Prompt Engineering: Security | Red-team attack enhancers · Presidio analyzer · Custom recognizer · Anonymizer operators |

The 26 Module 1 questions live in one consolidated notebook,
[`01-basics-of-gen-ai/Coding_Ques_Module_1_Basics_of_GenAI.ipynb`](01-basics-of-gen-ai/Coding_Ques_Module_1_Basics_of_GenAI.ipynb).
The per-lecture `L<n>-*.md` files this table used to link to were folded into it and no longer exist.

## Lecture index — Module 2: Advanced AI Agents

> **Authoritative lecture numbering.** As in Module 1, the
> `modules/02-advanced-ai-agents/markdown/L<n>_*.md` filenames are the only authoritative
> numbering. **Lectures 3 and 5 are each covered by two lecture files** — Lecture 3 by MCP theory
> plus the MCP hands-on tutorial, and Lecture 5 (since 2026-08-24) by
> `L5_AI_Modalities_Audio.md` and `L5_AI_Modalities_Video.md`, which replaced the single
> `L5_AI_Modalities.md`. Class 5's questions are split the same way, into
> `M2-L5-ai-modalities-audio.md` and `M2-L5-ai-modalities-video.md`. (Original note, still valid
> for Lecture 3: MCP theory + the MCP hands-on
> tutorial), so the module has 10 lecture files across 9 classes. An earlier revision of this
> table — and of
> [`modules/02-advanced-ai-agents/LECTURE_SUMMARY.md`](../modules/02-advanced-ai-agents/LECTURE_SUMMARY.md)
> — numbered AI Modalities as L1, pushing the agent lectures to 2–5 and Fine-Tuning Existing
> Models to **L6**; that order was **wrong**. Both were corrected on 2026-08-17, and the file
> formerly named `M2-L6-fine-tuning-existing-models.md` is now `M2-L4-…`.

**Format split.** Classes 1–3 (the agent/MCP lectures) are assessed as **VM labs** — the
material is "build a working agent", which a single-function descriptor cannot grade — and
Classes 4–9 as ML Function Descriptor questions — 5 each for Classes 4 and 5, 4 for each of the
rest, 26 in total. The three labs have their own index
at [`02-advanced-ai-agents/vm-labs/README.md`](02-advanced-ai-agents/vm-labs/README.md); each is
Max Score 50 (5 checks × 10), needs no Docker and no hosted model, and ships a stdlib
OpenAI-compatible endpoint whose decisions are computed rather than sampled.

None of the three uses LangChain or LangGraph: Classes 1–2 use the **raw OpenAI SDK** and Class 3
the official **`mcp`** SDK, which is what those lectures actually teach — and it also keeps them
distinct from the three LangGraph labs in the Module 3 set.

| Class | Lecture | Format | Coverage |
|-------|---------|--------|----------|
| 1 | Agents: Foundations & Planning | VM lab | [vm-labs/kilnbrook-foundry](02-advanced-ai-agents/vm-labs/kilnbrook-foundry/) — persona → system prompt · OpenAI-format tool schemas · three real `sqlite3` tools + SELECT-only guard · the function-calling ReAct loop · one shared history across turns |
| 2 | Advanced Agent Concepts | VM lab | [vm-labs/ashford-grid](02-advanced-ai-agents/vm-labs/ashford-grid/) — critique gate before execution · bounded evaluator-optimizer refine loop · execution-aware feedback + error memory · routing through a dispatch table · genuinely concurrent guard checks |
| 3 | MCP (Theory + Server/Client Tutorial) | VM lab | [vm-labs/larkspur-transit](02-advanced-ai-agents/vm-labs/larkspur-transit/) — FastMCP server: 3 tools + a resource + a prompt over stdio · MCP client session · MCP→OpenAI schema conversion · agent loop driven through the protocol |
| 4 | Fine-Tuning Existing Models | MFD | [M2-L4-fine-tuning-existing-models.md](02-advanced-ai-agents/M2-L4-fine-tuning-existing-models.md) — PEFT LoRA injection + adapter shapes (real model) · two target-module presets costed by `peft` itself · a real `merge_and_unload()` fold · SFT loss on the response tokens only · an Alpaca record rendered through the real chat template |
| 5 | AI Modalities (Audio + Video) | MFD | **Audio** — [M2-L5-ai-modalities-audio.md](02-advanced-ai-agents/M2-L5-ai-modalities-audio.md): frame-level RMS + zero-crossing rate → voiced/unvoiced · the real `librosa` Mel pipeline (shape, compression, loudest band) · WER with its S/D/I split + quality band.<br>**Video** — [M2-L5-ai-modalities-video.md](02-advanced-ai-agents/M2-L5-ai-modalities-video.md): measured temporal redundancy + uniform sampling on a real clip tensor · tubelet grid, VideoMAE mask and clip memory |
| 6 | Scaling AI Applications | MFD | [M2-L6-scaling-ai-applications.md](02-advanced-ai-agents/M2-L6-scaling-ai-applications.md) — DDP gradient sync checked against the single-device gradient (real autograd) · an MLP block split column-then-row across GPUs (real matmuls) · bucketed all-reduce overlapped with the backward pass (simulated) · the GPipe and 1F1B schedules built and measured (simulated) |
| 7 | Model Quantization Techniques | MFD | [M2-L7-model-quantization-techniques.md](02-advanced-ai-agents/M2-L7-model-quantization-techniques.md) — per-group vs per-tensor granularity · 16-bit float layout: range, overflow, underflow · static calibration → frozen scale/zero-point + clipping coverage · ternary 1.58-bit footprint |
| 8 | Advanced Fine-Tuning Techniques | MFD | [M2-L8-advanced-fine-tuning-techniques.md](02-advanced-ai-agents/M2-L8-advanced-fine-tuning-techniques.md) — training-memory budget vs one GPU · what each rank holds after an NCCL collective · replicated vs sharded per-GPU memory + per-step traffic · a real `FlatParameter` flattened, padded and sharded |
| 9 | LLM Inference Optimization | MFD | [M2-L9-llm-inference-optimization.md](02-advanced-ai-agents/M2-L9-llm-inference-optimization.md) — the cost of not caching · a real `DynamicCache` measured across prefill and decode · committing a speculative step's output · loop-level speculative accounting |

The 26 MFD questions (Classes 4–9) are also consolidated into one notebook,
[`02-advanced-ai-agents/Coding_Ques_Module_2_Advanced_AI_Agents.ipynb`](02-advanced-ai-agents/Coding_Ques_Module_2_Advanced_AI_Agents.ipynb),
in the same layout as the Module 1 notebook: per question one Markdown cell (student statement
plus the internal descriptor config, reference solution and `in`/`out` test cases), one code cell
holding the reference solution, then one executed code cell per test case. The three VM labs
(Classes 1–3) are **not** in the notebook — they are graded on a VM, not by a function descriptor,
and stay in `vm-labs/`. The per-lecture `M2-L<n>-*.md` files remain the source of truth: only they
carry the grader notes.

**Depth pass (2026-08-18).** An audit of what each question's graded value actually *requires*
found the set skewed toward closed-form arithmetic: only 2 of 24 questions put a real library in
the graded path, 7 did real tensor work by hand, and **15 computed a formula over scalars without
importing anything**. Whole classes — 6 and 8 — were arithmetic end to end. Six questions were
rewritten and one added so that the library performs the operation the lecture teaches, rather than
the learner reproducing its formula:

| Question | Was | Now |
|---|---|---|
| L4 Q2 | `r × (d_in + d_out) × layers` from a width table | two presets wrapped by `peft`, counts from `get_nb_trainable_parameters()` |
| L4 Q3 | `(α/r)·(B @ A)` folded by hand | a real `merge_and_unload()`, probed before and after |
| L4 Q5 | *(new)* | an Alpaca record → `apply_chat_template()` → real token counts |
| L5 Q1, Q3 | *(superseded 2026-08-24 — see below)* | replaced when the lecture was rewritten |
| L8 Q4 | `ceil(u / world_size)` per unit | a real `FlatParameter` concatenated, padded and chunked |
| L9 Q2 | `2 × L × H × d × b` from six integers | a real `DynamicCache` measured after prefill and after decode |

The distribution moved from **2 / 7 / 15** to **7 / 7 / 11** across those three tiers. The eleven
that remain arithmetic are mostly Class 6 and Class 8, whose source material is prose, CLI usage and
diagrams with no runnable code to grade against — for those, a formula is the honest ceiling.

Two of the rewrites are deliberately built so the measurement *confirms* the taught formula rather
than replacing it: L9 Q2's measured 64.0 bytes/token is exactly `2 × 2 layers × 2 heads × 2 wide ×
4 bytes`, and L4 Q3's merged delta is exactly `(α/r) × r × a_fill × b_fill` on top of a base weight
only the checkpoint can supply.

**Class 5 re-authored (2026-08-24).** The AI Modalities lecture was replaced by two new scripts —
`L5_AI_Modalities_Audio.md` and `L5_AI_Modalities_Video.md` — and the change is not cosmetic. Four
concepts the previous questions were built on are **no longer taught anywhere in the material**:

| Retired concept | Was graded by |
|---|---|
| Nyquist limit (`fs/2`), tone survival | old Q1 |
| Quantization SNR (~6 dB per bit) | old Q1 |
| Anti-aliasing vs naive decimation | old Q1 (the `librosa.resample` contrast) |
| Full 3-D conv vs factorized (2+1)D (`k³` vs `k²+k`) | old Q4, entirely |

Rather than patch questions whose observables had gone out of scope, Class 5 was re-authored from
the new material into five questions, split to mirror the lecture's own Part 1 / Part 2 division:

| # | Question | What produces the answer |
|---|---|---|
| Audio Q1 | Frame-level RMS + zero-crossing rate → voiced/unvoiced labelling | `numpy`, the lecture's exact framing loop and both formulas |
| Audio Q2 | The Mel spectrogram a speech model consumes | the real `librosa` mel filterbank |
| Audio Q3 | WER, its S/D/I split, and the quality band | the real `jiwer` aligner |
| Video Q1 | Measured temporal redundancy + uniform sampling | `torch` over a real clip tensor |
| Video Q2 | Tubelet grid, VideoMAE mask, clip memory | integer arithmetic (see note) |

Four of the five reproduce a figure the new lectures print: Audio Q2 case 1 returns the mel shape
`(80, 301)` and 100 frames/second; Audio Q3's three cases are the WER demo's own rows
(22.2% / 2 of 9, 0.0% / 0 of 9, 20.0% / 1 of 5); Video Q1's sampling rule is the lecture's
`uniform_sample`; and Video Q2 case 1 returns the tokenisation cell's printed 4×4×4 grid, 64 tokens,
1176 numbers per token, 6 visible and 58 masked.

Video Q2 is deliberately left as arithmetic: the video lecture's tokenisation cell is itself a
counting exercise that builds a synthetic clip only to draw a grid over it, so there is no library
call to grade, and inventing one would import machinery the material never shows. Video Q1 carries
the real tensor work for that half.

The superseded file is preserved at
`02-advanced-ai-agents/superseded/M2-L5-ai-modalities-pre-2026-08-24.md` — deliberately outside the
`M2-L*.md` glob the notebook builder reads, so it cannot be picked up by accident.

Two figures worth knowing about, both recorded in the grader notes: the new video lecture measures
memory in **10⁶-byte megabytes**, not MiB (its "batch of 8 clips = 77 MB" against a 9.63 MB clip is
what settles it), and its WER quality table leaves 5% in two bands and 30% in neither, so Video/Audio
Q3 closes both edges explicitly.

**Class 6 re-authored (2026-08-24).** The four original Class 6 questions were retired for being too
shallow — each reduced to evaluating one stated formula or definition over supplied scalars (a
serving-metric summary, tail-latency percentiles, the pipeline-bubble ratio, and a parallelism-degree
decision tree). This is the class where that was hardest to avoid: its material is prose, CLI usage
and diagrams, with no CPU-runnable framework code to grade against. The replacement set gets depth
from two directions instead:

| # | Question | What produces the answer |
|---|---|---|
| Q1 | DDP gradient sync, checked against the full-batch gradient | real `torch` autograd — per-replica backward passes, then the averaging collective |
| Q2 | An MLP block split column-then-row across GPUs | real `torch` matmuls — sharded result must reproduce the unsharded one |
| Q3 | Bucketed all-reduce overlapped with the backward pass | a two-stream discrete-event simulation |
| Q4 | The GPipe and 1F1B schedules, built and measured | a stage-grid schedule simulation |

Q1 and Q2 **perform** the strategy on one device and verify it against the single-device result,
which is what makes them checkable at all — no process group, no GPU. Q3 and Q4 carry state through
time rather than evaluating a closed form; neither has one.

Q4 is the direct answer to the retired bubble question: it reports the measured bubble *and* the
material's `(p−1)/(p−1+m)` rule of thumb, and on all three cases they agree exactly. Three
independent invariants hold on every case — steps equal `2(m+p−1)`, the measured bubble equals the
formula for both schedules, and GPipe's peak activation count equals `m` while 1F1B's equals `p`.
Those invariants caught two real bugs while the reference was being written: a draft that mutated
stage state mid-step reported 19 steps and a 15.79% bubble against the formula's 27.27%, and a draft
that modelled 1F1B as greedy prefer-backward got the timing right but the peak wrong (7 against 4).
**The peak activation count is the only value that separates a real 1F1B schedule from a merely
work-conserving one** — the grader notes say so, and it must not be dropped.

## Lecture index — Module 3: Agentic AI Systems

| File | Class | Lecture | Questions |
|------|-------|---------|-----------|
| [M3-L1-type-safety-validation-with-pydantic.md](M3-L1-type-safety-validation-with-pydantic.md) | **2** | Type Safety & Validation with Pydantic | Tool-call envelope validation (`Literal` allowlist + payload validator) · One argument schema per tool · Pydantic models → strict-mode tool specs (`model_json_schema()`) · **Wire round-trip: `model_dump_json` → `model_validate_json`, and what tampering does *not* catch** · **Cross-field `@model_validator(mode="after")` and why a field error stops it running** |
| [M3-L2-async-programming-and-concurrency-for-ai.md](M3-L2-async-programming-and-concurrency-for-ai.md) | **1** | Asynchronous Programming & Concurrency for AI | Semaphore-capped fan-out: completion order + measured peak · Replica race on `FIRST_COMPLETED` with cancellation handshake · Merged token transcript from concurrent async generators with early stop · Latency budget that includes the semaphore queue wait |
| [vm-labs/caldon-wire](03-agentic-ai-systems/vm-labs/caldon-wire/) | **1** | Asynchronous Programming & Concurrency for AI (**VM lab**) | Concurrent fan-out preserving input order · queue scored under a semaphore cap · batch surviving a rejected request · call abandoned at its deadline · bulletin streamed through an async generator |
| [Coding_Ques_Module_3_Agentic_AI_Systems.ipynb](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **9** | LlamaIndex & Advanced RAG Frameworks | Vector retrieval with source attribution (FastEmbed) · What a vector index reaches vs a keyword table index · Chunk size vs what the retriever hands back · `SimpleGraphStore` relation map at depth |
| [Coding_Ques_Module_3_Agentic_AI_Systems.ipynb](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **10** | Agentic RAG & GraphRAG | Multi-hop join over a NetworkX property graph (document *or* skill evidence, engineering-manager filter) · Rank-then-filter metadata search · Bounded subgraph serialized as triples · **one slot open** |
| [Coding_Ques_Module_3_Agentic_AI_Systems.ipynb](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **11** | Hybrid Search & Advanced Retrieval | BM25 + dense fused by RRF · Cross-encoder reranking of a fused shortlist · hit@3 and MRR head-to-head · **one slot open** |
| [Coding_Ques_Module_3_Agentic_AI_Systems.ipynb](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **12** | Parsing Complex Documents | **no questions** — the four authored for this class were removed on 2026-08-26 |
| [Coding_Ques_Module_3_Agentic_AI_Systems.ipynb](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **13** | DSPy: Mathematical Prompt Optimization | Baseline `Evaluate` score with a normalizing metric · `BootstrapFewShot` demo gate + compiled prompt growth · Saving, inspecting and reloading the compiled artifact · **one slot open** |
| [M3-L19-diffusion-models-fundamentals.md](M3-L19-diffusion-models-fundamentals.md) + [notebook](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **18** | Diffusion Models | Forward-process closed form off a DDPM β-schedule · DDIM loop with classifier-free guidance + negative prompt · Sinusoidal time-embedding separation across a step plan · What the noise schedule buys (linear vs cosine, measured) · Where a U-Net's parameters actually sit (encoder vs decoder, and the skip connection read off the counts) |
| [M3-L20-advanced-diffusion-image-generation.md](M3-L20-advanced-diffusion-image-generation.md) + [notebook](03-agentic-ai-systems/Coding_Ques_Module_3_Agentic_AI_Systems.ipynb) | **19** | Advanced Diffusion | Inpainting via mask-blended, `strength`-truncated DDIM · How much of the input `strength` actually leaves at the first step that runs · Proving a fresh ControlNet's zero convolutions really are zero · **one slot open** |

> **The `M3-L<n>` filename is NOT the class number.** Two of these files are numbered off the
> curriculum position, not off `modules/03-agentic-ai-systems/markdown/L<n>_*.md`, which is the
> authoritative source everywhere else in this repo. Concretely: Pydantic is **Class 2**
> (`markdown/L2_Type_Safety…`) but its file is called `M3-L1-`, and Async is **Class 1**
> (`markdown/L1_Asynchronous…`) but its file is called `M3-L2-`. **The `[Class N]` tags in the
> notebook are correct; the filenames are not.** The two diffusion files are numbered 19/20 off the
> curriculum and would be 18/19 under the markdown scheme. Renaming was deliberately not done here
> because `vm-labs/README.md` already links these paths — settle the scheme first, then rename all
> four together.

**Class 1 (Async) authored (2026-08-25) — four questions, `asyncio` only.** The single question this table
previously listed for this lecture no longer existed on disk; the class was authored from scratch against
`modules/03-agentic-ai-systems/markdown/L1_Asynchronous_Programming_&_Concurrency_for_AI.md`. All four
are standard library only — no LLM call, no API key, no network — with every simulated call an
`asyncio.sleep`, and each grades a value the event loop *produces* rather than a formula over the
inputs. **Q1, Q2 and Q4 each carry a case that a closed-form solution gets wrong**, named in the
grader notes. One draft of Q4 was discarded for being reproducible in three lines of arithmetic with
`asyncio` never imported; the shipped version puts the slot wait inside the latency budget, which no
closed form predicts. Verified over **20 fresh runs per case, byte-identical**, since three of the four
graded values are orderings.

> **Numbering caveat.** These files use the `M3-L<n>` scheme already on disk (`M3-L1` = Pydantic,
> `M3-L2` = Async). The `modules/03-agentic-ai-systems/markdown/` tree numbers the same two lectures
> `L2_` and `L1_` respectively — module 3's markdown L-numbers run one *below* the curriculum position
> from `L3` on, because `L4_` carries two files. Unlike Modules 1 and 2, module 3's markdown filename is
> **not** the authoritative number for the assessment files. Decide which scheme module 3 standardises
> on before adding more.

**Classes 9–13 authored (2026-08-25), in the notebook only.** Each class was authored against its own
`modules/03-agentic-ai-systems/markdown/L<n>_*.md` and drives the real library that lecture uses:
`llama-index-core` + FastEmbed ONNX embeddings (Class 9), `networkx` + `sentence-transformers`
(Class 10), `rank-bm25` + a bi-encoder and a cross-encoder (Class 11), `reportlab` + `pymupdf` +
`unstructured` (Class 12, since removed), and `dspy` driven by a stand-in LM so the optimizer runs
offline (Class 13). No hosted model, no API key. The graded value in every one is something the library
decides — an embedding score, a keyword table's reach, a graph store's traversal, the prompt DSPy
renders — so none is reproducible by arithmetic over the inputs.

> **Numbering.** The notebook was **renumbered continuously from Q1 on 2026-08-27**, so its twenty
> questions are now Q1–Q20 in class order: Class 2 → 1, Class 9 → 2–5, Class 10 → 6–8, Class 11 →
> 9–11, Class 13 → 12–15, Class 18 → 16–18, Class 19 → 19–20. **The paragraph immediately below uses
> the older numbering it was written in**; every reference after it uses the current one. `M3-L19` and
> `M3-L20` question numbers are file-local and unaffected.

**Numbering caveat (2026-08-31).** The notebook now holds **19 questions in 42 test cases**. Its
Class-13 prompt-rendering question was **removed on 2026-08-31** (see the third-pass section below),
and everything from 13 on shifted down by one. Dated sections below use the numbering in force when
they were written; the map from that numbering to the current one is:
`Q1–Q11 unchanged · 13→12 · 14→13 · 15→14 · 16→15 · 17→16 · 18→17 · 19→18 · 20→19`, with the old
**Q12 gone**. A bare `Q12` in a section dated before 2026-08-31 means the removed question.

Twenty were authored as Questions 10–29. On **2026-08-26** six were removed — Q15 (SQL guardrail),
Q21 (calibrated confidence gate) and all four Class 12 parsing questions — and the remaining fourteen
were **renumbered continuously as Questions 10–23**: Class 9 → 10–13, Class 10 → 14–16, Class 11 →
17–19, Class 13 → 20–23. **Classes 10 and 11 now hold three questions each and Class 12 holds none**,
against a four-per-class floor. ~~BM25 tokenization is deliberately left to the learner in the three Class 11 questions: the
statements give no regex, since any tokenization that splits on non-alphanumerics reproduces the
shipped answers.~~ **— SUPERSEDED 2026-08-31.** That safety argument was disproven and the tokenizer
is now specified behaviourally in Q9–Q11; see "The BM25 tokenizer is now specified" below. Do not
restore an unspecified tokenizer on the strength of this paragraph.

**Five diffusion questions were cut and four authored to replace them (2026-08-27).** The author kept
exactly one of the six questions added earlier that day — the sinusoidal time-embedding probe — and cut
the other five. The pattern in what survived is the design rule for anything added here next: **the
graded value has to be produced by the diffusion process itself.** The five that went (CLIP token
counts, a seeded latent's shape and RNG fingerprint, feathered-mask pixel counts, tokenizer vocabulary
ids, frame-noise drift statistics) all graded *bookkeeping around* the model; the one that stayed
grades a number only the model's own math produces. The four replacements
(`schedule_survival`, `step_budget_cost`, `strength_survival`, `configured_step`) each make a real
`diffusers` scheduler compute the answer — **and two of those four were themselves superseded later the
same day**, after the author objected that all four were scheduler questions: `step_budget_cost` became
`unet_stage_profile` and `configured_step` became `controlnet_injection_profile`, which is what the
notebook now carries, and three of them turn a claim the material states
qualitatively into a measured quantity: the cosine schedule holding half the signal to step 664 against
linear's 368, the largest per-step noise leap roughly halving as the step budget doubles, and
`strength` 0.2 / 0.7 / 1.0 leaving 87% / 11% / 1% of the input. The cut questions remain in the two
`.md` files as a record, flagged there as cut; **do not reinstate any of them without asking.** The
notebook now carries Class 18 → Questions 16–18 and Class 19 → Questions 19–20.

**Lecture-alignment QC, 2026-08-27 — all 24 questions in the notebook and the two diffusion files.**
Every technique each reference solution uses was traced to its own class's
`modules/03-agentic-ai-systems/markdown/L<n>_*.md`; nothing was taken on trust. Outcome: 10 aligned,
5 disclosed-not-taught, 7 partial, 2 misaligned — **no question failed on correctness**, every stored
output reproduces, and the gaps were disclosure and version-pinning rather than arithmetic. Six fixes
were applied, none of which changes a statement's meaning, a reference answer, or an expected output
(all re-verified afterwards):

- **Class 11 (Q9–Q11): the descending-sort tie-break is now stated.** BM25 over these 12-document
  corpora is dominated by exact-zero ties — three of Q11's four queries have only **one** document
  scoring above zero — so ranks 2–5 were an arbitrary ordering. Measured: switching
  `np.argsort(-s)` (the material's idiom, `L11:361`) for the equally idiomatic `np.argsort(s)[::-1]`
  moved `bm25_ranks` from `[None, 1, None, 1]` to `[5, 1, None, 1]` and `bm25_mrr` from `0.5` to
  `0.55` — **two of six graded values**. Each statement now says the lower document index ranks first
  on a tie. ~~The BM25 tokenizer is still deliberately left open per the 2026-08-26 decision.~~
  **— SUPERSEDED 2026-08-31**; the tokenizer is now specified behaviourally. See below.
- **Class 9 (Q2–Q4): `as_retriever` is now named in the statements.** It has **zero occurrences in
  all 23 module-3 lecture files** — L9 retrieves only via `as_query_engine` (`L9:290`, `:389`,
  `:416`, `:556`, `:679`) — so it was an undisclosed dependency, not neighbour-lecture leakage. Naming
  it also removes the trap that the taught path needs `Settings.llm = None` (verified: without it,
  `as_query_engine(...).query()` raises `ImportError: llama-index-llms-openai`), which only Q3
  mentioned.
- **Q4 now names the `docstore`** as where the nodes live. `docstore` likewise has zero occurrences
  module-wide, and `"n_nodes"` previously had no taught route at all. Q4's remaining weakness is
  conceptual and unfixed: chunk-size *tuning* is not taught in L9, which carries only two bare
  `Settings.chunk_size` / `chunk_overlap` config lines (`L9:98-99`) and never varies them; the effect
  of chunking on retrieval is discussed in **L12** (`:927`, `:1151-1162`), three classes later.
- **Q5 now pins whose subject each hop carries.** This was the only finding rated *wrong* rather
  than merely undisclosed: `L9:531` prints the dict **key** as the subject (`f"  {entity}  --[{rel[1]}]-->  {rel[2]}"`)
  while its own comment one line above (`L9:529`) says `rel` is `[subject, relation, object]`. A
  learner copying the material's pattern emits `seed` as the subject of every hop and fails both test
  cases on any depth-2 row. The statement now says each hop uses its own subject.
- **Q6 dedups by manager name**, matching `L10:551`'s own `sorted({...})`, so the statement's "no
  duplicates" guarantee now holds even if two managers share a name. Verified: both test outputs are
  unchanged.
- **A setup cell was added, then removed by the author on 2026-08-27** along with the header cell's
  class index and dependency prose — the notebook is now questions only, and that is deliberate: do
  not re-add scaffolding cells. The finding that prompted it still stands for whoever builds the
  grader image. At the time, cell 0 said "Run the setup cell below first" but **no
  `pip install` existed in any of the 67 code cells**, and `numpy` was missing from the dependency
  list. Versions are pinned where a graded value is a float or a library-produced identifier:
  `pydantic==2.13.4`, `llama-index-core==0.12.52`, `rank-bm25==0.2.2`, `torch==2.13.0`,
  `diffusers==0.40.0`, `transformers==5.16.1`, `pillow==12.3.0`, `numpy==2.5.2`, and — added
  2026-08-31 — `fastembed==0.8.0` with `llama-index-embeddings-fastembed==0.3.5`, which is what
  actually produces Q2's `0.7553`, Q3's rankings and Q4's `0.812`. `transformers` is pinned to one
  value here and below; `rank-bm25` matters because `BM25Okapi`'s default `epsilon` is load-bearing
  (`epsilon=0.0` moves 12 of 15 rankings across Q9–Q11).

**The two outstanding pins were settled on 2026-08-31, and a third was added.** All three are owed by
whoever builds the grader image; the notebook deliberately carries no install cell.

- **`dspy==3.2.1`** — the version the lecture itself resolves to (`L13:58` prints
  `Install complete. dspy version: 3.2.1`). Every Class-13 output was re-verified byte-identical on
  3.2.1 and 3.3.1, so either works, but 3.2.1 is what the learner will have. Q15's exact-match on
  DSPy's private `dump_state` field names was **removed** on 2026-08-31 rather than pinned around, so
  the remaining exposure is small.
- **`sentence-transformers==6.0.0`** (with `transformers` 5.16.1, `torch` 2.13.0) — Q2, Q4 and Q7 grade
  embedding scores to 3–4 decimals off downloaded weights. Verified: Q7 and the three Class-11
  questions reproduce byte-exactly on this stack, which is *not* the one they were authored on.
- **`diffusers==0.40.0`, `torch==2.13.0`** — every graded value in Q16–Q20 is a library artefact:
  parameter counts sensitive to `norm_num_groups` / `attention_head_dim` / `mid_block_type` defaults,
  the `alphas_cumprod` construction, and the `DDIMScheduler.timestep_spacing` default that Q19's
  statement now pins explicitly. A minor bump can silently invalidate every diffusion out-file.

**Residual findings, recorded but deliberately not acted on** (none affects gradability; all three are
disclosure-level, and each would cost more than it returns to "fix"):

- **Q1's `extra="forbid"` is mandated by the statement but cannot be exercised.** Verified by running an
  identical model without `model_config`: byte-identical output on all three cases. The tampering step
  only ever *replaces* `confidence`, and the signature takes a single `tampered_confidence: float`, so
  there is no way to inject an extra key without changing the function signature. Do not "add a case
  for it" — add one only alongside a signature change, or drop the requirement. Meanwhile do not treat
  it as graded. The same applies to `M3-L1` Q4, which is byte-identical to notebook Q1.
- **Q3 contradicts `L9:373`.** The material states "LlamaIndex uses **the LLM** to extract keywords
  from each chunk and from your query", while the question requires `Settings.llm = None`, under which
  the keyword table is built by regex instead. Both graded keyword values depend on that regex
  behaviour (hyphen sub-tokens: `INC-2915` indexes "inc" from every `INC-xxxx`). The question's Note
  discloses the `Settings.llm = None` requirement, so it is solvable — but a learner who trusts
  `L9:373` has grounds to think disabling the LLM breaks keyword indexing. The clean fix belongs in the
  lecture, not the question.
- **Q14's load-bearing observable is taught nowhere.** The `n_messages`/`roles` half of its answer rests
  on compiled demos arriving as alternating `user`/`assistant` prompt turns. L13 never calls
  `inspect_history` after compiling — all three occurrences (`:534`, `:598`, `:688`) precede Section 6 —
  and shows compiled demos only as an object dump (`:988-1004`), never as prompt turns. It is disclosed
  in the question's Context ("they arrive in the compiled prompt as extra conversational turns"), so it
  is fair, but it can only be observed, never predicted, from the material. Related: `lm.history` appears
  in no lecture file while `inspect_history` — which prints and returns `None` — is the only
  introspection route taught, so the taught API cannot produce Q12/Q14/Q15's return values at all. One
  line in L13 showing `lm.history[-1]["messages"]` next to `inspect_history` would close this for three
  questions at once.

**Two questions grade a taught observable through an untaught mechanism, and were left as they are —
each now carries the caveat in its own notes.** `M3-L20` Q1's per-step mask-blended latent loop appears
in **no** diffusion file (the material calls `AutoPipelineForInpainting` with a PIL mask and never opens
the loop), and Q4's chunk-size framing belongs to L12. Both are solvable from their statements alone,
which is the only thing making them fair; restructuring either is a curriculum decision, not an
editorial one.

**The diffusion material has since been recorded**, and the two files' scope notes were updated on
2026-08-27 to point at it: curriculum 19 is `markdown/L18_Diffusion_Models_Lecture.md` +
`L18_Diffusion_Models_Lecture_2.md`, curriculum 20 is `markdown/L19_Advanced_Diffusion.md` +
`L19_Advanced_Diffusion_Part_2.md`. The three questions written before that (M3-L19 Q1/Q2, M3-L20 Q1)
were scoped to the brief in
[`FUTURE_CLASSES.md`](../../../modules/03-agentic-ai-systems/FUTURE_CLASSES.md); each has since been
given a **scope trace against the recorded material**, and two carry an explicit caveat — `M3-L19` Q2
because `DDIMScheduler`/`clip_sample` appear only in Class 19's material, and `M3-L20` Q1 because its
per-step mask-blended latent loop appears in **no** diffusion file at all (see its grader notes; it is
the least curriculum-anchored question in the set). The six added on 2026-08-27 were authored against
the recorded material with per-technique line citations. All nine use real `diffusers` schedulers or
embeddings on the CPU, with a captured trace of U-Net outputs standing in for the U-Net, so no GPU or
weights are involved; two of the six fetch CLIP's 1.7 MB tokenizer vocabulary at grading time and the
rest need no network at all.

### Second QC and remediation pass — 2026-08-31

**A second, deeper QC ran on 2026-08-31 and its findings were then fixed.** Method: each statement was
read once with the reference solution out of view, then statement-against-solution, then every claim was
checked by *executing* extracted code rather than reasoning about it. Verdicts before remediation:
6 aligned, 2 disclosed-not-taught, 8 partial, 5 misaligned. **All 42 declared return values reproduced
byte-exact** — correctness was never the problem; disclosure and test-case discrimination were.

**Six blocking defects were found and closed.**

1. **Classes 13's four questions were solvable with no `dspy` import.** A stdlib-only stub reproduced
   all six declared outputs from the statement plus the Sample Output alone: Q13's metric is fully
   specified in prose so `score`/`per_example`/`wrong` are arithmetic over `zip(gold, replies)`;
   Q14's `n_messages` is `2*n_demos + 2` and `roles` is `['system'] + ['user','assistant']*n + ['user']`;
   Q15 had four of five keys constant across cases *and* printed in its own sample. ~~(Q12 was re-examined and is **not** materially gameable — its case-2 value is DSPy's
   `ChainOfThought` rendering, which the Predict sample does not give away.)~~
   **— WRONG, corrected 2026-08-31.** That clearance rested on a stub that reasoned only from the
   Sample Output. The *lecture* prints the complete render for both modules —
   `L13_DSPy_Mathematical_Prompt_Optimization.md:540-568` (`Predict`) and `:606-636`
   (`ChainOfThought`), the latter being exactly the value that was claimed to be safe — and its
   headline is Q12 case 1's headline verbatim. See the Q12 entry below. Fixed by grading what only the adapter
   produces: Q13 gained `"parsed"` (the adapter-parsed prediction, which differs from the reply) plus a
   third case scoring 2 of 3 so the evaluator's own `round(100*n/N, 2)` = `66.67` separates from a
   recomputed `66.66666666666667`; Q14 gained `"first_demo_turn"` (DSPy's rendering of a bootstrapped
   demo) and a case-2 whose replies make the adapter's parse decide which examples bootstrap at all;
   Q15 traded both `dump_state` keys for `"saved_demo_headlines"`. Re-tested at the time: the previously-passing stubs
   failed 3–4 of 7 cases — which was reported as "closed" when it means a stub still **passed 4 of
   7**. That was an overclaim; the remaining exposure was closed on 2026-08-31 (below).
   **Residual, recorded honestly:** a stub that reads
   `dspy/adapters/chat_adapter.py` and encodes its line-anchored, first-occurrence-wins parse rule does
   still reproduce the values. That rule appears in no statement, sample or lecture — it can only be
   looked up, not inferred — and it also has to reconstruct the `Bootstrapped …` stdout line, which
   depends on tqdm's leaked loop variable. Closing even that gap would need newlines inside `replies`,
   which the `List of Strings` input format forbids.
2. **Q14/Q15's out-files omitted a stdout line the reference itself prints.**
   `BootstrapFewShot.compile()` does a bare `print()` (`dspy/teleprompt/bootstrap.py:166`) → stdout,
   deterministic across dspy 3.2.1 and 3.3.1. Both questions' Test Cases sections were rebuilt from
   real captured stdout, so `outN.txt` is now the full program output. The same applies to **Q3**, whose
   mandated `Settings.llm = None` prints `LLM is explicitly disabled. Using MockLLM.` (43 bytes, once
   per process, verified with `od -c`). **Consequence to know:** for Q3, Q14 and Q15 the student-facing
   **Sample Output is the return value only** while `out1.txt` carries the harness banner as well. That
   divergence is deliberate. It is also load-bearing on the assumption that the grader runs each case in
   its own process, which the `in1.txt`/`in2.txt` split with `T=1` implies — if both cases ever share a
   process, the banner appears before case 1 only.
3. **Q10's graded `"before"` was decided by an undisclosed tie.** Both cases hold bit-identical fused
   RRF floats in the top two, and only the reference's dict insertion order reproduced them; a learner
   extending the *stated* lower-index rule to the fused list failed case 1 and passed case 2, so no
   stated rule passed both. Step 1 now states that BM25-ranking order breaks a fused tie, and that a
   document the BM25 ranking did not contain ranks after one it did.
4. **Q19 contradicted the only `DDIMScheduler` construction in its own class.**
   `L19_Advanced_Diffusion_Part_2.md:836`–`:841` sets `timestep_spacing="linspace"`; copying it scores
   zero on every fraction (0.8651→0.8547, 0.1091→0.0895, 0.0096→0.0064). The statement now pins the
   library default `"leading"` outright, names `set_timesteps` and `scheduler.timesteps` (both absent
   from every module-3 lecture file), states `0 < strength <= 1`, and the two clamps that bound made
   unreachable were removed.
5. **Q3's fragile ranking.** Its third query sat on a 0.0011 cosine margin at the `top_k` cut, where any
   ONNX/BLAS drift flips the answer. Replaced with `how do I add a second user to my account`, which
   keeps the keyword-empty pedagogy, moves the margin to 0.0873 and the rank-0/rank-1 gap to 0.0486, and
   **leaves the expected output identical**. Rejected alternative, for the record: raising `top_k` to the
   corpus size makes it worse, since every adjacent gap then becomes load-bearing.
6. **Q6's published reference solution contradicted its own statement** — the markdown block returned a
   generator where the executed cell returned a set, against step 4's "no duplicates" promise. A diff of
   all 20 markdown blocks against their code cells found this as the only mismatch. Fixed, with the
   divergence first reproduced on an input where two managers share a name.

**Disclosure fixes.** Every API the solutions need that appears in **no** module-3 lecture file is now
named in its statement: `upsert_triplet` and `get_rel_map(subjs=, depth=)` (Q5), `ref_doc_id`/`doc_id`
(Q3 — whose Note previously ruled out the text-lookup route that does work, while withholding the
intended one), `lm.history[-1]["messages"]` and `.results` with its `(Example, Prediction, float)` shape
(Q13–Q15), and `down_blocks` / `up_blocks` / `mid_block` / `time_embedding` / `conv_in` /
`downsamplers` / `down_block_types` / `up_block_types` (Q18).

**Three statements said something untrue, all corrected.** Q12's Note claimed the docstring's
indentation is reproduced as it stands — the eight spaces are DSPy's `chat_adapter` template, and the
one-line and multi-line docstring spellings render byte-identically because DSPy dedents. Q7's Context
claimed a filtered search does not return the department's best documents — read literally that is
false, and a pre-filter implementation passes both cases; only the truncate-then-filter error is
actually caught. Q5's step 3 said each hop's subject is "the entity the previous hop pointed at", which
its own Sample Output contradicts; it now says each hop carries its own subject.

**Coverage fixes.** Q6 gained a third case that discriminates case-sensitive document matching (`[]`),
case-insensitive skill matching, and a missing `is_engineering` filter — none of which either shipped
case caught. Q18's `in_channels` affected none of its six graded values and `time_embedding_params` was
the constant 20736 in all three cases; a seventh key `"conv_in_params"` was added, case 2's widths moved
to `[64, 128]` and case 3 now passes `in_channels = 3`. Q20 gained `"mid_block_params"`, one of only two
values there with no closed form in the arguments, and its Note stopped announcing the boolean pattern.
Q10's two cases differed only in the query string; case 2 is now `shortlist=4, top_k=2`. Q10's Sample
Input scored **0/5** non-zero on BM25 — the "hybrid" sample was pure index order — and Q11's sample had
the same defect. Q2's metadata is now pinned to exactly `{"file_name": …}`, because LlamaIndex embeds
metadata and an extra key moves every score. Q1's range is pinned as a field constraint, since a
`@field_validator` spelling changes `tampered_verdict` from `less_than_equal` to `value_error`.

**Rejected fixes, so nobody re-proposes them.** `injection_conv_out_channels` for Q20 was proposed and
dropped: it is fully predicted from the arguments on 4/4 configurations
(`1` leading conv, then `layers_per_block` per level plus a downsampler on all but the last, then the
mid conv), so it carries no information beyond `n_injection_convs`. Per-injection-conv parameter counts
are `c*c + c`, derivable from those. `total_params` was rejected as a Q18 key because it equals the
reported parts plus `conv_out` and `conv_norm_out`. And a correction to the audit's own framing: because
the whole returned dict is exact-matched, Q18's `down_params`/`up_params`/`mid_params` and Q20's
`total_params` have no closed form and already gate every submission — **neither question was ever
passable without building the model.** Their defects were dead arguments and constant keys, not
gameability.

**The BM25 tokenizer is now specified — behaviourally, not as code — and that was the subtlest finding
of the pass.** Leaving it open was an explicit author decision on 2026-08-26, on the correct principle
that pasting `re.findall(r"[a-z0-9\-]+", text.lower())` writes the learner's line for them. But the
*safety argument* behind it — "any tokenization that splits on non-alphanumerics reproduces the shipped
answers, only `str.split()` diverges" — was **disproven on 2026-08-31**:

- **Hyphens alone split the four previously-blessed regex spellings.** `red-team` is one token under
  `[a-z0-9\-]+` (so a query term `red` does not match it) and two under `\w+` (so it does), moving one
  document's BM25 score 3.9600 → 5.3978 and past another. `guardrail-protected` and `inc-2847` change a
  document's token count, hence its length normalisation, hence shortlist positions 3–4.
- **Stopword removal breaks more**, and sklearn's list contains `inc`, so even a pure identifier query
  is not immune.
- **The shipped questions looked safe only because their BM25 was degenerate.** An all-zero score vector
  falls back to index order under every tokenizer — degeneracy was masquerading as robustness, which is
  exactly why the premise survived the earlier audit. So non-degeneracy and tokenizer-robustness are
  structurally opposed on this 12-document corpus.
- **Q10 case 1 was stopword-fragile as originally shipped**: `before[:3]` is `[8, 1, 4]` under the regex
  spellings and `[1, 8, 0]` once stopwords go, which moves `after` and `top_score` too.

The fix names the *requirement*, not the code: "lowercase the text and treat every run of whitespace or
punctuation as a term boundary, except a hyphen inside an identifier such as `INC-2847` or `red-team`,
and remove no stopwords." **Fourteen conforming spellings were written and run against all nine slots of
Q9/Q10/Q11 — all fourteen agree everywhere.** They collapse into three equivalence classes differing
only on `v2.3`, the single period-inside-a-token in either corpus, which perturbs one document's length
normalisation; the tightest surviving gap retains 51% of its width. The clause repairs Q10 case 1 with
no query, parameter or output change, and it excludes the one reading that still diverged (a bare
`str.split()` leaving punctuation glued to terms, which contradicts the clause's own "same terms" anyway).
**Do not revert to an unspecified tokenizer without re-establishing degeneracy**, and re-check that
`v2.3` gap if another period-bearing token is ever added.

**Class 11's inputs were rebuilt on top of that.** Q9's three query slots went from 1–3 non-zero-scoring
BM25 documents to 4–11 (parameters unchanged), so the fused answer reflects retrieval rather than an
index-order tie-break; case 1's doc 6 at `1/63 + 1/64` outranking doc 2 at `1/63` is now the RRF lesson
in miniature. Q11's queries went from 1–2 non-zero documents to 7–10 and the question now lands its own
Context claim — the two retrievers tie on hit@3 at 0.75 while MRR splits them 0.75 against 0.583 — with
a genuine BM25 miss and a genuine dense miss, each on a non-degenerate ranking. Both `_ranks` lists now
carry a `None`, where the shipped `dense_ranks` had none.

**Housekeeping.** `np.argsort(-x)` became `np.argsort(-x, kind="stable")` in all three Class-11
solutions: the statements promise lower-index-first on a tie, and introsort only honours that below
numpy's n=16 insertion-sort cutoff (verified stable at n=16, not at n=17). The unused `import torch`
came out of Q17–Q20. 32 stderr streams were stripped, two of which leaked an authoring scratchpad path.
Four over-long student-facing Note lines were reflowed.

**Not done, deliberately.** Two lecture defects are recorded but untouched, because editing delivered
lecture material is a curriculum decision: `L9:373` states the keyword index uses the LLM, which is
false for `SimpleKeywordTableIndex` (regex at both ends, confirmed by instantiation), and L13 never
shows `lm.history` while its only taught introspection route, `dspy.inspect_history`, returns `None`.
`M3-L1` Q5 carries the same "float constrained to the range" wording as Q4 and may share the
Field-vs-validator ambiguity; it is not in the notebook and was not audited. Q1's `extra="forbid"`
remains unexercisable, as already recorded — and two more of its mandated requirements turn out to be
unexercisable too: the `sources` default, and validating the **JSON text** rather than a parsed dict
(verified: all three wrong readings pass all three cases). Q2's case 1 has the next-thinnest margin in
Class 9 at 0.0080.

### Third QC pass and remediation — 2026-08-31 (nine independent auditors)

Nine read-only auditors: two reading statements blind in learner persona, six tracing one class
cluster each against its own lecture, one cross-cutting. **Measurement overturned eight of their
predictions, and two conclusions recorded in this file.** What was closed:

1. **Q13/Q14/Q15 — the Class-13 gameability hole was still open.** The previous pass's own numbers
   said so (a stub passed 4 of 7 cases) and were read as a pass. Root cause found this time: for all
   three questions **the Sample Output was case 1's output**, so case 1 could never be protected — any
   behaviour it exercised was published in the statement. Fixed by giving each question a Sample Input
   of its own (not a graded case, showing only plain replies) and putting an adapter-format reply into
   every graded case. Measured per case, stubs built from statement + Sample Output alone:
   `Q13 0/3 · Q14 0/2 · Q15 0/2`. **Residual, stated plainly:** a stub encoding the adapter's
   field-marker rule (`[[ ## sentiment ## ]]` anywhere in a reply → `''`) still reproduces Q13's three
   cases; that rule is in no statement, sample or lecture. Q14/Q15 are additionally protected by the
   `Bootstrapped …` banner, whose "after N examples / amounting to M attempts" numbers come from a
   leaked loop variable in `dspy/teleprompt/bootstrap.py` and are not derivable (sample `3/3/3`,
   case 1 `3/4/5`, case 2 `2/4/4`).
2. **Q14/Q15/Q3 — the deliberate Sample-Output-vs-`outN.txt` divergence was a defect, not a feature.**
   The previous pass rebuilt the out-files from real stdout and left the samples as return-value-only,
   recording the divergence as intentional. It means a learner who diffs against the sample sees an
   unexplained line and suppresses it, failing every case with a correct program. All three samples now
   show the library's stdout line, and each Note says it belongs there.
3. **Q18 — step 3 asked for the wrong test.** "ask each down block whether it carries a `downsamplers`
   module" reads as `hasattr`, which is `True` for **every** `DownBlock2D` (it is `None` on the last
   level). Measured: `hasattr` gives `downsampling_stages` 3 and `bottleneck_resolution` 8 where the
   truth is 2 and 16 — two of seven keys wrong in all three cases. Now "count the down blocks whose
   `downsamplers` is not `None`". The sanity-check hint was deleted and `up_params`' ordering, which
   that hint was the only statement of, moved into step 4.
4. **Q6 — the statement contradicted itself.** Step 1's attribute list omitted the skill `name` that
   step 2 reads; the lecture stores it (`L10:436`) and matches by attribute (`L10:500`), so following
   the lecture gave `KeyError` on all three cases. Step 1 now provisions it. Step 3's "follow their
   `REPORTS_TO` edges to their managers" is now pinned to a single hop (direct managers give
   `['Elena Duarte']`; transitive ancestors give three names).
5. **This file contradicted itself on the BM25 tokenizer** — `:255` and `:293` still said "deliberately
   left open" while `:489` said specified and the old premise disproven. A maintainer reading the
   earlier paragraph first would have restored exactly what `:516` warns against. Both are struck
   through and marked superseded.
6. **The Class-13 prompt-rendering question (old Q12, `compiled_prompt`) was REMOVED** — author's
   decision, 2026-08-31, after the fix was measured to fail. It asked for the prompt DSPy renders for
   `Predict` versus `ChainOfThought`. The lecture prints that render in full for both modules
   (`L13_DSPy_Mathematical_Prompt_Optimization.md:540-568` and `:606-636`) and the headline in those
   dumps was the question's own case 1 verbatim, so both declared outputs were a mechanical
   substitution into published text. A `confidence: float` output field was tried first and **measured
   to fail** — a transcription stub still passed 2/2 — because the graded value is a *template render*:
   the statement must publish one full instance of it as the Sample, and a template with more slots is
   still a template. A `list[str]` field, whose render carries an exact JSON-schema blob, fares no
   better. **Do not re-author this question in this shape.** A question grading a rendered prompt is
   only defensible if the lecture stops publishing the render, or if what it returns is not the render.
   Consequence: **Class 13 now holds three questions**, against the four-per-class floor — one slot
   open, and the notebook was renumbered (see the numbering caveat above).

Zero-cost wins applied in the same pass:

- **Q8's two dead requirements are now live at no cost to the output.** `out2.txt` is byte-identical
  before and after; verified that bare integer node keys now return `n_visited: 5` and a list instead
  of a set now emits `(Ana Iyer) -[:WORKS_ON]-> (Guardrail)` twice. Prism was renumbered `103` → `13`
  to collide with employee 13, and one assignment duplicated.
- **Two grader notes in `M3-L19` asserted coverage that does not exist.** `flip_sin_to_cos` **cannot
  affect Q16's output at all** — it is a column permutation applied identically to every row, and
  cosine similarity is invariant under a shared permutation (verified `flip=True` ≡ `flip=False` at
  `embedding_dim` 320/32/33/7 × both `downscale_freq_shift` values). And `downsampling_stages` is
  always `len(block_out_channels) - 1` over 1–5 levels, so no case catches a hardcode. Both notes
  rewritten to say so.
- **Reference tokenizer aligned with its own sentence.** `[a-z0-9\-]+` kept edge hyphens and emitted
  bare `-` tokens, which the statement's wording excludes; replaced with
  `[a-z0-9]+(?:-[a-z0-9]+)*` in Q9/Q10/Q11. All six declared outputs verified unchanged.
- **Spec gaps closed, one clause each:** Q9's Context used `1/(k + rank)` where `k` is the result count
  and `rrf_k` the constant (a learner following it returns `{1: 0.45, …}` instead of `{1: 0.0328, …}`);
  Q9 gained the fused-tie rule Q10 already had; Q10 now declares `rank` 1-based (latent — 0-based is
  measurably identical on both cases today) and no longer says "only their order matters" about a
  graded number; Q10/Q11 declare key order; Q11 states `targets` holds 0-based indexes and that hit@3
  is independent of `k`; Q16 gained "leaving every other argument at its default"; Q19's false
  inference (`0 < strength <= 1` does **not** imply ≥ 1 step; `floor(30 × 0.01) = 0` → `IndexError`)
  corrected; Q13's metric no longer puts the label scan before the lowercasing it depends on;
  Q14/Q15 pin the probe entry's shape (the other reading raises `AdapterParseError` on every case);
  Q15 names the save route (`save()` adds a `metadata` key, `json.dump(dump_state())` does not);
  Q12 pins seam whitespace; Q7 states its three lists are the same length.
- **Pins:** `fastembed==0.8.0` and `llama-index-embeddings-fastembed==0.3.5` added — they produce Q2's
  `0.7553`, Q3's rankings and Q4's `0.812` and were unpinned. `transformers` was pinned twice at
  different versions (`5.15.0` and `5.16.1`); reconciled to `5.16.1`, the installed one.

Known and **not** fixed in this pass (scope was questions, mirrors and this file only): the four
lecture defects — `L2:350`'s `indent=2` under the comment "for the wire" against the graded bare
`model_dump_json()` at `L2:377`; `L2:337`'s false "any tampering fails on arrival"; `L9:373`'s false
claim that `SimpleKeywordTableIndex` uses the LLM; `L9:531` printing the map key as every hop's
subject, which ships a wrong line at `L9:551`. Also unfixed: 18 APIs the bank requires have **zero**
occurrences in all 22 lecture files, and in Q2/Q4 the only retrieval route L9 teaches raises
`ImportError: llama-index-llms-openai`. One retriever cell in L9 and one `lm.history` line in L13
would close six questions' worth of that gap.

## Verification status

All 18 Module 1 reference solutions were executed (Python 3.14, `numpy`, `jinja2`, `faiss-cpu`; L2 Q1
re-executed on Python 3.12 with `torch` 2.13.0) on **two test cases each**; the `out.txt`
values in every file are the actual program output, not estimates.

The nine diffusion questions (M3 L19–L20, i.e. Classes 18 and 19) were executed on Python 3.12 by
parsing each document's own `in.txt` with a harness that mimics the portal's argument parser and
diffing against the document's own `out.txt` — all nine reproduce exactly. The first three (M3-L19
Q1/Q2, M3-L20 Q1) ran on `torch` 2.13.0, `diffusers` 0.39.0, `numpy` 2.5.1; the six added on
2026-08-27 (M3-L19 Q3–Q5, M3-L20 Q2–Q4) ran on `torch` 2.13.0, `diffusers` 0.40.0,
`transformers` 5.15.0, `Pillow` 12.3.0. **Only one of those six is still live** (`M3-L19` Q5,
`time_embedding_similarity`); the notebook's other four diffusion questions are `M3-L19` Q6/Q7 and
`M3-L20` Q5/Q6, authored later the same day. The notebook's current numbering is Q16–Q20, not the
pre-renumber 24–29. Every wrong reading listed in their grader notes was also implemented and run, not reasoned
about. Two of the six need the HF Hub at grading time for CLIP's 1.7 MB tokenizer vocabulary; none
of the nine loads model weights or touches a GPU.

Each question uses the same library the lecture uses for that specific operation — e.g. L2 Q1
(self-attention) is `torch`, because the lecture implements attention with `torch.matmul` and
`F.softmax`, while L2 Q2 (patchify) is `numpy`, because the lecture splits the image into
patches with numpy HWC slicing. Do not standardise a question onto a different library than
its source lecture uses. These questions use no live LLM/embedding endpoint, so their outputs are
deterministic and fully reproducible.

**Module 2 — all 24 questions across Classes 4–9 (4 per class), verified twice.** Each was first
executed by its author on 2–5 test cases, then **independently re-verified** by a separate harness
that re-extracts, from each finished document alone, its descriptor argument types, its reference
solution, its `in.txt` and its `out.txt` — then re-parses `in.txt` the way the portal does, runs the
solution, and diffs. That second pass exists so a bug shared between an authoring harness and its own
document cannot hide. Result: **58 test cases across 23 of the 24 questions reproduce their
documented `out.txt` exactly**, with no unconsumed `in.txt` lines and no `__main__` harness in any
reference solution. The one question not re-executed in that second pass was `M2-L4` Q1, which needs
the HF Hub.

That gap is now closed, and the depth pass above has been verified the same way. Building
[`02-advanced-ai-agents/Coding_Ques_Module_2_Advanced_AI_Agents.ipynb`](02-advanced-ai-agents/Coding_Ques_Module_2_Advanced_AI_Agents.ipynb)
re-extracts every question from its own Markdown file, re-parses each `in.txt` the way the portal
does, and executes every cell through a Jupyter kernel. Latest run (2026-08-24, after the Class 5 re-authoring): **118 cells, 0 error cells, and
all 66 test cases across all 26 questions reproduce their documented `out.txt` exactly** — including
every question that loads a checkpoint, runs the real mel pipeline, or measures a live KV cache.
Environment: Python 3.12.13, `torch` 2.13.0, `numpy` 2.5.2, `transformers` 5.15.0, `peft` 0.20.0,
`jiwer` 4.0.0, `librosa` 1.0.0, CPU only.

Six questions now need the HF Hub at grading time rather than one (`M2-L4` Q1, Q2, Q3, Q5 and
`M2-L9` Q2), all of them on tiny `qwen2`-architecture test checkpoints of a few hundred KB —
`M2-L4` Q5 needs only the tokenizer files, no weights at all. `M2-L5` Q1 adds `librosa`, whose
first `resample` call in a fresh process costs ~7 s of back-end warm-up; every later call is
milliseconds.

**Line citations.** The scope traces carry 251 line references into the lecture markdown; all 251
were range-checked and the rewritten questions' 64 were each read back against the cited line.
Note the lecture files contain a handful of lone `\r` characters — 4 in L4, 1 in L5, and (found
2026-08-27) **1 in `L19_Advanced_Diffusion.md` at line 31 and 1 in `L19_Advanced_Diffusion_Part_2.md`
at line 68** — so Python's text-mode `split('\n')` numbers those files one line differently from
`sed`/`grep -n` for every line past the `\r`. **Any citation tool must read the lecture files in
binary and split on `\n` only.** Nine citations into the two L19 diffusion files were off by one
this way and were corrected on 2026-08-27; a content-verified sweep of all 130 citations across the
two diffusion question files now comes back clean. **The
citations use `grep -n` numbering** — verify them with `sed -n 'Np'`, not with a Python line split.

Environments: `M2-L6` and `M2-L8` are standard library only (Python 3.14.6); `M2-L4` Q3/Q4, `M2-L7`
and `M2-L9` use `torch` 2.13.0 on Python 3.12.13 (CPU, no download, no GPU); Class 5 uses `numpy`
2.5.2 throughout, plus `librosa` 1.0.0 for the Mel question, `jiwer` 4.0.0 for the WER question and
`torch` for the video redundancy question — each the library that material itself calls. Every question's grader notes list the wrong readings that were **implemented and run**, and
name which test case catches each one.

Several cases deliberately reproduce figures the source material prints, which is the strongest
available check that a question matches what was taught: `M2-L4` Q2 (659,456 params per block,
18,464,768 total), `M2-L7` Q3 (calibration zero-points −6 / −15 / 93 / 93), `M2-L8` Q1 and Q3
(112 GB at 7B, 208 GB at 13B, ~1.75 GB on 64 GPUs), `M2-L9` Q4 (60 tokens in 24 target passes), and
across Class 5: the Mel shape `(80, 301)` at 100 frames/second, the WER demo's own three rows, and
the tokenisation cell's 4×4×4 grid of 64 tokens at 1176 numbers each with 6 visible and 58 masked.

**`Torch 2D Tensor` and `Numpy 1D Array` layouts — confirmed against the tool (2026-08-17).** Neither
type had a prior instance in either bank, so both were initially inferred; the generated Input Format
Description has since been read off the UI and **both inferred layouts were correct**, so no `in.txt`
and no expected output changed. The confirmed layouts are:

- `torch_tensor_2d` — `Line 1: R C (rows cols)`, then `Next R lines: C space-separated values each`
- `numpy_1d` — `Line 1: N (array length)`, then `Line 2: N space-separated values`

The Input Format blocks in `M2-L4` Q3/Q4, `M2-L5` Q1, `M2-L7` and `M2-L9` Q3 now quote that wording
verbatim, and the tool's own type spelling is **`torch_tensor_2d`** (not `torch_2d_tensor`). Note
this wording was confirmed for those two types **only** — the `list_float` and `2d_list_int` blocks
elsewhere in this set keep their own wording, since no generated descriptor has been seen for them.

`M2-L4` Q1 is the **only** question in this set that needs the HF Hub at grading time: it loads a
base model and wraps it with `get_peft_model`, which is the hands-on half of that lecture. It uses
tiny `qwen2`-architecture test checkpoints (a few hundred KB, ~1.5 s per case, no GPU) so the taught
module names — `q_proj` … `down_proj` — stay valid; the lecture's own `Qwen/Qwen2.5-1.5B` is a ~3 GB
download and not viable in a grader. It grades only the injected adapters' **structure** (shapes,
names, `alpha / r`), never their randomly-initialised values, so it stays deterministic.

The 4 Module 3 reference solutions were executed on Python 3.14 — all three `M3-L1` questions on
**two** test cases each (`pydantic` 2.13.4), `M3-L2` on **three** (standard library only, and re-run
5× with byte-identical output, since its graded observable includes the order the concurrent calls
finished in). All four are offline: no API key, no live LLM call. Each question's grader notes list
the wrong readings that were run and confirmed to fail, and which case catches each one.

`M3-L1` Q3 is the one question whose expected output is **generated by a library rather than by us**
(`pydantic`'s `model_json_schema()`), so its grader notes require structural dict comparison via
`ast.literal_eval` rather than raw string matching — key insertion order legitimately differs between
a model that declares `extra="forbid"` and one that does not — and name a fallback observable in case
a `pydantic` upgrade ever moves the generated schema text.
