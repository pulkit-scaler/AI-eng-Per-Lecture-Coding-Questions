# Module 2, Lecture 5 (Part 1) — AI Modalities: Audio

Three coding questions across the runnable half of the audio material: the **frame-level features**
that separate voiced speech from unvoiced (Q1), the **Mel spectrogram** that every modern speech
model actually consumes (Q2), and **Word Error Rate** with the quality band a transcript lands in
(Q3).

Nothing is downloaded and no GPU is needed. Q2 runs the real `librosa` mel pipeline and Q3 the real
`jiwer` aligner, so in both the library — not a formula — produces the graded value. Q1 is `numpy`
on a supplied waveform.

**Scope note.** This file replaces an earlier `M2-L5-ai-modalities.md` written against the previous
version of this lecture. That lecture taught the **Nyquist limit** (`fs/2`), **quantization SNR**
(~6 dB per bit) and **aliasing**; the current one teaches none of them — it introduces sample rate
and bit depth as the two knobs, then moves to RMS/ZCR, Mel spectrograms, Whisper, WER and
translation. Two of the four old questions graded observables that are no longer in scope and have
been retired rather than patched. The superseded file is kept at
`superseded/M2-L5-ai-modalities-pre-2026-08-24.md`.

---

## Q1: Telling Voiced From Unvoiced With Two Cheap Features

**Context:** Before any deep learning touches a waveform, two frame-level features already say a
great deal about it. Chop the signal into short overlapping windows and, for each one, measure how
loud it is and how often it crosses zero. A vowel is a periodic wave — loud, and crossing zero only
as often as its pitch requires. A fricative like "sss" is turbulent airflow — comparable loudness,
but crossing zero constantly. That contrast is enough to separate speech types with a threshold and
no training at all, which is why voice-activity detectors have used it for decades.

**Problem Statement:**

Using `numpy`, write a function
`voiced_unvoiced_report(signal, sample_rate, frame_ms, hop_ms, zcr_threshold)`.

1. Convert the frame length and the hop from milliseconds to whole numbers of samples at
   `sample_rate`, truncating any fraction. Report both.
2. Cut `signal` into frames of that length, advancing by that hop. Frames start at sample `0` and a
   new frame is taken at every hop position **strictly before** `len(signal) − frame_length`; no
   partial frame at the tail is kept. Report how many frames that yields.
3. For each frame compute its **RMS energy** — the square root of the mean of its squared samples —
   and its **zero-crossing rate** — the fraction of adjacent sample pairs within the frame whose
   sign differs. Report the mean RMS across frames and the largest zero-crossing rate any frame
   reached, each rounded to 6 decimal places.
4. A frame counts as **unvoiced** when its zero-crossing rate is strictly greater than
   `zcr_threshold`. Report how many frames are unvoiced, and the index of the first one — or `-1`
   when no frame is.
5. Return a dictionary with exactly these seven keys: `"num_frames"`, `"frame_len"`, `"hop_len"`,
   `"unvoiced_frames"` and `"first_unvoiced_frame"` as integers, and `"mean_rms"` and `"max_zcr"`
   as floats.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: signal (numpy_1d)
    Line 1: N (array length)
    Line 2: N space-separated values
  Argument 2: sample_rate (integer)
    Single line: one integer
  Argument 3: frame_ms (float)
    Single line: one float
  Argument 4: hop_ms (float)
    Single line: one float
  Argument 5: zcr_threshold (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `voiced_unvoiced_report()` on a new line.

**Sample Input:**

```
signal = np.array([0.0, 0.2724, 0.4854, ...])   # 120 samples: a low tone, then noise
sample_rate   = 800
frame_ms      = 25.0
hop_ms        = 10.0
zcr_threshold = 0.15
```

**Sample Output:**

```
{'num_frames': 13, 'frame_len': 20, 'hop_len': 8, 'mean_rms': 0.304009, 'max_zcr': 0.526316, 'unvoiced_frames': 7, 'first_unvoiced_frame': 6}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is loaded and no audio file is read. Sign changes are counted between neighbouring samples *inside*
one frame, so a frame of `L` samples offers `L − 1` pairs to compare — the rate is over those pairs,
not over `L`. The sample rates in the test cases are lower than the 16 kHz speech standard purely to
keep the payload readable; the millisecond-to-sample conversion is unchanged by that.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: voiced_unvoiced_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. signal        → Numpy 1D Array
2. sample_rate   → Integer
3. frame_ms      → Float
4. hop_ms        → Float
5. zcr_threshold → Float
```

(`frame_ms` and `hop_ms` are the material's fixed 25/10 ms configuration — required here so the
conversion is graded rather than assumed. Seven values must come back, so they fold into one
`Dictionary`.)

**Reference Solution:**

```python
import numpy as np


def voiced_unvoiced_report(signal: np.ndarray, sample_rate: int, frame_ms: float,
                           hop_ms: float, zcr_threshold: float) -> dict:
    frame_len = int(frame_ms / 1000 * sample_rate)
    hop = int(hop_ms / 1000 * sample_rate)

    frames = [signal[i:i + frame_len]
              for i in range(0, len(signal) - frame_len, hop)]

    rms = np.array([np.sqrt(np.mean(f ** 2)) for f in frames])
    zcr = np.array([np.mean(np.diff(np.sign(f)) != 0) for f in frames])

    unvoiced = zcr > zcr_threshold

    return {
        "num_frames": len(frames),
        "frame_len": frame_len,
        "hop_len": hop,
        "mean_rms": round(float(rms.mean()), 6),
        "max_zcr": round(float(zcr.max()), 6),
        "unvoiced_frames": int(unvoiced.sum()),
        "first_unvoiced_frame": int(np.argmax(unvoiced)) if unvoiced.any() else -1,
    }
```

**Test Cases —** `in.txt`

```
2
120
0.0 0.0471 0.0939 0.1401 0.1854 0.2296 0.2724 0.3135 0.3527 0.3897 0.4243 0.4562 0.4854 0.5116 0.5346 0.5543 0.5706 0.5834 0.5926 0.5982 0.6 0.5982 0.5926 0.5834 0.5706 0.5543 0.5346 0.5116 0.4854 0.4562 0.4243 0.3897 0.3527 0.3135 0.2724 0.2296 0.1854 0.1401 0.0939 0.0471 0.0 -0.0471 -0.0939 -0.1401 -0.1854 -0.2296 -0.2724 -0.3135 -0.3527 -0.3897 -0.4243 -0.4562 -0.4854 -0.5116 -0.5346 -0.5543 -0.5706 -0.5834 -0.5926 -0.5982 0.0609 -0.208 0.1501 0.1881 -0.3902 -0.2604 0.0256 -0.0632 -0.0034 -0.1706 0.1759 0.1556 0.0132 0.2254 0.0935 -0.1719 0.0738 -0.1918 0.1757 -0.01 -0.037 -0.1362 0.2445 -0.0309 -0.0857 -0.0704 0.1065 0.0731 0.0825 0.0862 0.4283 -0.0813 -0.1024 -0.1628 0.1232 0.2258 -0.0228 -0.168 -0.1649 0.1301 0.1487 0.1086 -0.1331 0.0464 0.0233 0.0437 0.1743 0.0447 0.1358 0.0135 0.0578 0.1263 -0.2914 -0.0639 -0.0941 -0.1278 -0.055 0.299 -0.1732 0.1937
800
25.0
10.0
0.15
200
0.0 0.0353 0.0704 0.1051 0.1391 0.1722 0.2043 0.2351 0.2645 0.2923 0.3182 0.3422 0.3641 0.3837 0.401 0.4157 0.428 0.4376 0.4445 0.4486 0.45 0.4486 0.4445 0.4376 0.428 0.4157 0.401 0.3837 0.3641 0.3422 0.3182 0.2923 0.2645 0.2351 0.2043 0.1722 0.1391 0.1051 0.0704 0.0353 0.0 -0.0353 -0.0704 -0.1051 -0.1391 -0.1722 -0.2043 -0.2351 -0.2645 -0.2923 -0.3182 -0.3422 -0.3641 -0.3837 -0.401 -0.4157 -0.428 -0.4376 -0.4445 -0.4486 -0.45 -0.4486 -0.4445 -0.4376 -0.428 -0.4157 -0.401 -0.3837 -0.3641 -0.3422 -0.3182 -0.2923 -0.2645 -0.2351 -0.2043 -0.1722 -0.1391 -0.1051 -0.0704 -0.0353 -0.0 0.0353 0.0704 0.1051 0.1391 0.1722 0.2043 0.2351 0.2645 0.2923 0.3182 0.3422 0.3641 0.3837 0.401 0.4157 0.428 0.4376 0.4445 0.4486 0.45 0.4486 0.4445 0.4376 0.428 0.4157 0.401 0.3837 0.3641 0.3422 0.3182 0.2923 0.2645 0.2351 0.2043 0.1722 0.1391 0.1051 0.0704 0.0353 0.0 -0.0353 -0.0704 -0.1051 -0.1391 -0.1722 -0.2043 -0.2351 -0.2645 -0.2923 -0.3182 -0.3422 -0.3641 -0.3837 -0.401 -0.4157 -0.428 -0.4376 -0.4445 -0.4486 -0.45 -0.4486 -0.4445 -0.4376 -0.428 -0.4157 -0.401 -0.3837 -0.3641 -0.3422 -0.3182 -0.2923 -0.2645 -0.2351 -0.2043 -0.1722 -0.1391 -0.1051 -0.0704 -0.0353 -0.0 0.0353 0.0704 0.1051 0.1391 0.1722 0.2043 0.2351 0.2645 0.2923 0.3182 0.3422 0.3641 0.3837 0.401 0.4157 0.428 0.4376 0.4445 0.4486 0.45 0.4486 0.4445 0.4376 0.428 0.4157 0.401 0.3837 0.3641 0.3422 0.3182 0.2923 0.2645 0.2351 0.2043 0.1722 0.1391 0.1051 0.0704 0.0353
1600
25.0
10.0
0.10
```

**Test Cases —** `out.txt`

```
{'num_frames': 13, 'frame_len': 20, 'hop_len': 8, 'mean_rms': 0.304009, 'max_zcr': 0.526316, 'unvoiced_frames': 7, 'first_unvoiced_frame': 6}
{'num_frames': 10, 'frame_len': 40, 'hop_len': 16, 'mean_rms': 0.318211, 'max_zcr': 0.051282, 'unvoiced_frames': 0, 'first_unvoiced_frame': -1}
```

**Grader Notes:**

- **Environment:** `numpy` 2.5.2 on Python 3.12.13. Milliseconds per case, no download.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities_Audio.md`:
  - *The two features and what they are for* — **line 110**, verbatim: "**RMS energy** (loudness)
    and **Zero-Crossing Rate** (how often the signal crosses zero) are two cheap frame-level
    features that can already separate speech from noise."
  - *Voiced vs unvoiced* — **lines 101–102**: a periodic wave with detectable pitch against
    "turbulent airflow → looks like random noise, high frequency, no clear period".
  - *The framing* — **lines 128–129**, verbatim:
    `frame_len = int(0.025 * SR); hop = int(0.010 * SR)` and
    `frames = [signal[i:i+frame_len] for i in range(0, len(signal)-frame_len, hop)]`. Steps 1 and 2
    are those two lines stated in prose, including the exclusive upper bound that drops the tail.
  - *The two formulas* — **lines 131–132**, verbatim:
    `rms = np.array([np.sqrt(np.mean(f**2)) for f in frames])` and
    `zcr = np.array([np.mean(np.diff(np.sign(f)) != 0) for f in frames])`. Step 3 is those two
    expressions; the reference reproduces them exactly.
  - *That ZCR is the separating feature, not RMS* — **lines 150 and 157**: "Notice: RMS is similar
    on both sides, but ZCR is much higher for the unvoiced segment." Case 1 reproduces that
    situation, and step 4's threshold is the "simple rules" the next line refers to.
  - **Disclosed, not taught:** thresholding ZCR to *label* frames, and reporting the first labelled
    index. The material plots the two features and states the contrast in words but never applies a
    cut-off; step 4 defines the comparison as strictly-greater and fixes the `-1` sentinel.
- **Determinism.** Pure `numpy` over supplied float64 values. Both cases re-run byte-identical.
- Compare the five integers exactly; `"mean_rms"` and `"max_zcr"` with tolerance `1e-6`.
- **The frequency-to-sample-rate ratio is what matters, not the rate.** A sine's zero-crossing rate
  is ≈ `2 · f / sample_rate`, so the material's 200 Hz at 16 kHz gives ≈ 0.025. Case 1 uses 10 Hz at
  800 Hz and case 2 uses 20 Hz at 1600 Hz — the same ratio — so the voiced frames sit near 0.025 and
  noise near 0.5, and the thresholds separate them exactly as they do at 16 kHz. An earlier draft
  reduced the rate without rescaling the tone; every frame then read as unvoiced. If either case is
  edited, preserve the ratio.
- **What each case is for:**
  - **Case 1** — a low tone followed by noise, so the boundary is real: 7 of 13 frames are unvoiced
    and the first is index 6, which is the first frame whose 20-sample window sits mostly past the
    60-sample joint. This is the case that exercises the labelling.
  - **Case 2** — a pure tone throughout, so **no** frame is unvoiced and the sentinel is returned.
    It also uses a different sample rate, so `frame_len` and `hop_len` differ (40/16 against 20/8)
    and a solution hardcoding either is caught. **Case 2 must stay in any shipped subset.**
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Inclusive frame bound** (`range(0, len(signal) - frame_len + 1, hop)`): `num_frames` 14 / 11,
    and `mean_rms` shifts to 0.301622 / 0.318248 — caught on both.
  - **Framing to the end of the signal** (`range(0, len(signal), hop)`, keeping short tail frames):
    `num_frames` 15 / 13 and a `RuntimeWarning` on the empty tail slice — caught on both.
  - **ZCR over `L` pairs instead of `L − 1`** (`np.mean(np.diff(np.sign(f)) != 0)` replaced by
    `count / len(f)`): `max_zcr` 0.5 / 0.05 against 0.526316 / 0.051282 — caught on both at the
    `1e-6` tolerance.
  - **Counting sign *changes* including zeros as their own sign**: `np.sign` returns 0 at an exact
    zero sample, so a `0 → +` step counts as a change. Case 2's signal contains exact `0.0` samples
    and its `max_zcr` of 0.051282 already includes that effect — a solution filtering zeros out
    returns 0.025641 and is caught by case 2.
  - **Mean RMS as the RMS of the whole signal** (not the mean of per-frame RMS): 0.320019 / 0.318198
    — caught by case 1.
  - **`first_unvoiced_frame` returning 0 instead of `-1`** when nothing is unvoiced: caught by
    case 2, which is the only case with no unvoiced frame.
- **Overlap check:** Q2 of this file consumes a *synthesised* signal and never frames it by hand;
  Q3 is text. Nothing in the topic-organized bank
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`) computes
  RMS or ZCR — its Q7 is log-mel geometry. No shared graded value.
- Both cases executed against the reference solution.

---

## Q2: The Mel Spectrogram the Model Actually Sees

**Context:** A neural network is not handed 48,000 raw samples and asked to find structure in them.
The waveform is first turned into a two-dimensional image: overlapping short windows along time,
each decomposed into frequencies, those frequencies squashed onto a perceptual scale and
log-compressed. What comes out is a compact matrix — frequency bands down one axis, time frames
along the other — and that matrix, not the waveform, is what a speech encoder consumes. Knowing how
its shape follows from the window and hop settings is how you predict a model's input size and its
memory cost before you run anything.

**Problem Statement:**

Using the `numpy` and `librosa` libraries, write a function
`mel_spectrogram_report(sample_rate, duration_s, tone_hz, n_mels, n_fft, hop_length)`.

1. Synthesise the input waveform: take `sample_rate × duration_s` samples, truncated to a whole
   number, at times `k / sample_rate` for `k = 0, 1, …`; the sample at each time is
   `0.5 · sin(2π · tone_hz · t)`. Report how many samples that is.
2. Compute the Mel spectrogram of that waveform with `librosa`, at `n_mels` bands, an FFT window of
   `n_fft` and a hop of `hop_length`, then convert it to decibels relative to its own maximum.
3. Report the two dimensions of the result — the number of bands and the number of time frames —
   and their product, the number of cells the model receives.
4. Report the ratio of raw samples to cells, rounded to 4 decimal places: how much smaller the
   representation is than the waveform it came from. Report also how many frames the settings
   produce per second of audio, rounded to 4 decimal places.
5. Report which band is loudest overall — the 0-based index of the band whose mean decibel value
   across all time frames is highest.
6. Return a dictionary with exactly these seven keys: `"n_mels"`, `"n_frames"`, `"raw_samples"`,
   `"mel_cells"` and `"loudest_band"` as integers, and `"compression_ratio"` and
   `"frames_per_second"` as floats.

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: sample_rate (integer)
    Single line: one integer
  Argument 2: duration_s (float)
    Single line: one float
  Argument 3: tone_hz (float)
    Single line: one float
  Argument 4: n_mels (integer)
    Single line: one integer
  Argument 5: n_fft (integer)
    Single line: one integer
  Argument 6: hop_length (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `mel_spectrogram_report()` on a new line.

**Sample Input:**

```
sample_rate = 16000
duration_s  = 3.0
tone_hz     = 440.0
n_mels      = 80
n_fft       = 400
hop_length  = 160
```

**Sample Output:**

```
{'n_mels': 80, 'n_frames': 301, 'raw_samples': 48000, 'mel_cells': 24080, 'compression_ratio': 1.9934, 'frames_per_second': 100.0, 'loudest_band': 11}
```

**Note:** The input handling is already in place — you only need to implement the function. Nothing
is downloaded; the waveform is built from the arguments. Leave the mel and decibel conversions at
their library defaults apart from the three settings named above — the frame count in particular is
the library's own, so derive it from the result rather than predicting it. Pass the sample rate to
the mel call: it decides where the perceptual bands sit, and therefore which band comes out loudest.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: mel_spectrogram_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. sample_rate → Integer
2. duration_s  → Float
3. tone_hz     → Float
4. n_mels      → Integer
5. n_fft       → Integer
6. hop_length  → Integer
```

(`n_mels`, `n_fft` and `hop_length` all carry defaults on `librosa.feature.melspectrogram` —
required here and supplied in every test case. Seven values must come back, so they fold into one
`Dictionary`. The waveform is synthesised inside the function rather than passed as an argument
because a 48,000-sample array cannot be carried in a test case.)

**Reference Solution:**

```python
import librosa
import numpy as np


def mel_spectrogram_report(sample_rate: int, duration_s: float, tone_hz: float,
                           n_mels: int, n_fft: int, hop_length: int) -> dict:
    n = int(duration_s * sample_rate)
    t = np.arange(n) / sample_rate
    y = (0.5 * np.sin(2 * np.pi * tone_hz * t)).astype(np.float32)

    S = librosa.feature.melspectrogram(y=y, sr=sample_rate, n_mels=n_mels,
                                       n_fft=n_fft, hop_length=hop_length)
    S_db = librosa.power_to_db(S, ref=np.max)

    n_bands, n_frames = S.shape

    return {
        "n_mels": int(n_bands),
        "n_frames": int(n_frames),
        "raw_samples": n,
        "mel_cells": int(n_bands * n_frames),
        "compression_ratio": round(n / (n_bands * n_frames), 4),
        "frames_per_second": round(sample_rate / hop_length, 4),
        "loudest_band": int(np.argmax(S_db.mean(axis=1))),
    }
```

**Test Cases —** `in.txt`

```
2
16000
3.0
440.0
80
400
160
8000
2.0
300.0
32
256
128
```

**Test Cases —** `out.txt`

```
{'n_mels': 80, 'n_frames': 301, 'raw_samples': 48000, 'mel_cells': 24080, 'compression_ratio': 1.9934, 'frames_per_second': 100.0, 'loudest_band': 11}
{'n_mels': 32, 'n_frames': 126, 'raw_samples': 16000, 'mel_cells': 4032, 'compression_ratio': 3.9683, 'frames_per_second': 62.5, 'loudest_band': 3}
```

**Grader Notes:**

- **Environment:** `librosa` 1.0.0 and `numpy` 2.5.2 on Python 3.12.13, CPU, no network. The first
  `librosa` call in a fresh process costs ~7 s of lazy import; later calls are milliseconds. Budget
  that once per submission.
- **The library produces the graded value.** `n_frames` is `librosa`'s own framing decision (it pads
  by default, giving `n // hop + 1`, not `n // hop`), and `loudest_band` depends on where the mel
  filterbank places its band centres for that sample rate — neither is derivable from the arguments
  by a formula the statement supplies.
- **Case 1 reproduces the material's own printed shape.** The material computes
  `melspectrogram(y=y, sr=SR, n_mels=80, n_fft=400, hop_length=160)` on a 3-second 16 kHz clip and
  prints `Mel spectrogram:   shape = (80, 301)`. Case 1 uses those exact settings and returns
  `n_mels` 80, `n_frames` 301.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities_Audio.md`:
  - *Why a spectrogram at all* — **line 163**: feeding "48,000 raw numbers into a neural network is
    awkward", and **line 180**: the result is "a 2-D matrix of shape **(80 frequency bands × ~100
    time frames per second)** — exactly like a grayscale image. **This is what Whisper and every
    modern speech model sees.**" Step 4's frames-per-second is that parenthetical made exact.
  - *The three construction steps* — **lines 171–178**: a 25 ms slice, sliding 10 ms, "This gives
    ~100 windows/second"; the FFT per window; the Mel filterbank and the log. Case 1's
    `n_fft = 400` and `hop_length = 160` are those two durations at 16 kHz, and its
    `frames_per_second` of 100.0 is the material's own "~100 windows/second".
  - *The calls* — **lines 202–203**, verbatim:
    `S = librosa.feature.melspectrogram(y=y, sr=SR, n_mels=80, n_fft=400, hop_length=160)` and
    `S_dB = librosa.power_to_db(S, ref=np.max)`. Step 2 is those two lines.
  - *Compactness as the reason it is used* — **line 186**: "**Compact:** 80 × 500 for a 5-second clip
    vs 80,000 raw samples". Step 4's ratio is that comparison generalised; note the material's own
    figures give 80,000 / 40,000 = 2.0, which is case 1's 1.9934 to within the padding frame.
  - *The synthetic-waveform-then-mel pattern* — **lines 195–203**, where the material builds a
    signal from a sine and mels it, and again at **line 292** inside the Whisper demo. Step 1 is that
    construction with the amplitude the material uses (`0.5`).
  - **Disclosed, not taught:**
    - The cell count, the compression ratio and the loudest band as *reported numbers*. The material
      prints shapes and displays the spectrogram; it never reduces it to a scalar. Steps 3–5 define
      each reduction.
    - `S_db.mean(axis=1)` as the way to rank bands. Any equivalent reduction over the time axis is
      accepted.
- **Determinism, and why `db_mean` is not graded.** Shape, `mel_cells`, the two ratios and
  `loudest_band` were checked under **three** plausible spellings of step 1's time vector —
  `np.linspace(0, duration_s, n)`, `np.linspace(..., endpoint=False)` and `np.arange(n) / sr` — and
  are **identical** under all three. The *mean* decibel value is not: it drifts by up to 0.32 dB
  between them, so an earlier draft's `"db_mean"` key was removed rather than shipped with a
  tolerance wide enough to hide a real error. Do not add it back.
- Compare the five integers exactly; the two ratios with tolerance `1e-4`.
- **What each case is for:**
  - **Case 1** — the material's own configuration and printed shape.
  - **Case 2** — a different sample rate, band count, window and hop, so `frames_per_second` (62.5)
    and `compression_ratio` (3.9683) both move, and the loudest band shifts to 3. A solution that
    hardcodes 100 frames/second or a ratio of 2 passes case 1 and fails case 2. **Case 2 must stay in
    any shipped subset.**
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Frame count as `n // hop_length`** (dropping the padding frame): 300 / 125 against 301 / 126,
    and the ratios move to 2.0 / 4.0 — caught on both.
  - **Frame count as `1 + (n - n_fft) // hop_length`** (the no-padding convention): 298 / 123 —
    caught on both.
  - **Omitting `sr` from the mel call** (letting it default to 22050): case 1's `loudest_band`
    becomes 8 and case 2's 5, while every shape value stays correct — caught on both, and this is
    the reading the Note's last sentence exists to prevent.
  - **Ranking bands on the power spectrogram instead of the decibel one**: identical on both cases,
    since `power_to_db` is monotonic and `ref=np.max` is a constant shift — an **accepted** route.
  - **`ref=1.0` instead of `ref=np.max`**: also identical for `loudest_band`, for the same reason;
    accepted. It would matter only if a decibel value were graded, which is why none is.
  - **Compression ratio inverted** (cells over samples): 0.5017 / 0.252 — caught on both.
- **Overlap check:** the topic-organized bank's Q7
  (`../../../ai-eng-tests/assessments/coding-questions/advanced-ai-agents-coding-ques.md`) computes
  log-mel *frame geometry and Whisper chunk counts* from integers without calling `librosa`. This
  question runs the real pipeline and grades the filterbank's own output. They are the arithmetic and
  the measurement of the same idea — ship both only if you want the prediction and the measurement
  tested separately.
- Both cases executed against the reference solution.

---

## Q3: Scoring a Transcript and Placing It on the Quality Scale

**Context:** A transcript is not judged by whether it looks right. The standard measure aligns it
against the reference word by word and counts the three ways the two can disagree — a wrong word, an
extra word, a missing word — then divides the total by the length of the reference. The rate alone is
not the whole story: the breakdown says *how* a system is failing, and a rate only becomes actionable
once it is placed against the bands the field uses, which is what separates "ship it" from "needs
post-processing".

**Problem Statement:**

Using the `jiwer` library, write a function `wer_quality_report(reference, hypothesis)`.

1. Align the hypothesis against the reference at word level and count the **substitutions**, the
   **deletions** and the **insertions**.
2. Compute the word error rate — the three counts summed and divided by the number of words in the
   reference — and round it to 4 decimal places. Report also the reference's word count, taking
   words to be whitespace-separated tokens.
3. Report the error total the rate implies for this reference: the rate multiplied by the reference
   word count, rounded to the nearest whole number.
4. Place the transcript on the quality scale by its rate expressed as a percentage: below 5 is
   `"excellent"`, from 5 up to but not including 15 is `"good"`, from 15 up to but not including 30
   is `"fair"`, and 30 or above is `"poor"`. Report the label verbatim, in lower case.
5. Return a dictionary with exactly these seven keys: `"substitutions"`, `"deletions"`,
   `"insertions"`, `"reference_words"` and `"errors"` as integers, `"wer"` as a float, and
   `"quality"` as one of the four strings above.

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

For each test case, print the result of `wer_quality_report()` on a new line.

**Sample Input:**

```
reference  = "the flight departs at nine thirty from terminal two"
hypothesis = "the light departs at nine thirty from terminal to"
```

**Sample Output:**

```
{'substitutions': 2, 'deletions': 0, 'insertions': 0, 'wer': 0.2222, 'reference_words': 9, 'errors': 2, 'quality': 'fair'}
```

**Note:** The input handling is already in place — you only need to implement the function. Each
string arrives on a single line and is already lower-case with no punctuation, so no normalisation is
required. Reach for the library's alignment output rather than its rate alone: the same call that
scores a pair also reports how the errors break down. Round the rate before you report it, but derive
the error total from the unrounded rate.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: wer_quality_report
RETURN TYPE: Dictionary

ARGUMENTS:
1. reference  → String
2. hypothesis → String
```

(Seven values must come back, so they fold into one `Dictionary`.)

**Reference Solution:**

```python
import jiwer

QUALITY_BANDS = [(5.0, "excellent"), (15.0, "good"), (30.0, "fair")]


def wer_quality_report(reference: str, hypothesis: str) -> dict:
    out = jiwer.process_words(reference, hypothesis)
    reference_words = len(reference.split())
    rate = float(out.wer)

    quality = next((name for edge, name in QUALITY_BANDS if rate * 100 < edge), "poor")

    return {
        "substitutions": int(out.substitutions),
        "deletions": int(out.deletions),
        "insertions": int(out.insertions),
        "wer": round(rate, 4),
        "reference_words": reference_words,
        "errors": round(rate * reference_words),
        "quality": quality,
    }
```

**Test Cases —** `in.txt`

```
3
the flight departs at nine thirty from terminal two
the light departs at nine thirty from terminal to
the quick brown fox jumps over the lazy dog
the quick brown fox jumps over the lazy dog
please turn off the lights
please turn off lights
```

**Test Cases —** `out.txt`

```
{'substitutions': 2, 'deletions': 0, 'insertions': 0, 'wer': 0.2222, 'reference_words': 9, 'errors': 2, 'quality': 'fair'}
{'substitutions': 0, 'deletions': 0, 'insertions': 0, 'wer': 0.0, 'reference_words': 9, 'errors': 0, 'quality': 'excellent'}
{'substitutions': 0, 'deletions': 1, 'insertions': 0, 'wer': 0.2, 'reference_words': 5, 'errors': 1, 'quality': 'fair'}
```

**Grader Notes:**

- **Environment:** `jiwer` 4.0.0 on Python 3.12.13. Milliseconds per case, no download.
- **The library produces the alignment.** The S/D/I split is the output of `jiwer`'s edit-distance
  backtrace, not of a formula in the statement. The *rate* could be reconstructed from the counts,
  which is why the counts are the primary graded values.
- **All three cases are the material's own demo rows.** Its WER table prints, for exactly these
  pairs, `Multiple errors (noisy audio) 22.2% 2/9 words wrong`, `Perfect transcript 0.0% 0/9` and
  `One deletion 20.0% 1/5` — matching this question's `wer`/`errors` on cases 1, 2 and 3
  respectively.
- **Scope trace** — against `modules/02-advanced-ai-agents/markdown/L5_AI_Modalities_Audio.md`:
  - *The metric* — **line 392**, verbatim:
    `WER = (Substitutions + Insertions + Deletions) / Total words in reference`.
  - *The three error types* — **lines 396–400**, the table naming substitution ("Wrong word"),
    insertion ("Extra word that wasn't there") and deletion ("Missed a word"). Step 1 is that table.
  - *The quality bands* — **lines 404–409**, verbatim: `< 5%` Excellent, `5–15%` Good, `15–30%` Fair,
    `> 30%` Poor. Step 4 is that table with the boundaries closed explicitly (see below).
  - *The library and the error total* — **lines 418, 451 and 454**: `from jiwer import wer`,
    `score = wer(ex["reference"], ex["hypothesis"])` and
    `errors = round(score * len(ref_words))`. Step 3 is that last line verbatim, which is also why
    the error total is derived from the **unrounded** rate.
  - **Disclosed, not taught (API only):** the material calls `jiwer.wer(...)`, which returns the rate
    alone; the aligned counts come from `jiwer.process_words(...)` in the same library. The *metric*
    is fully in scope and step 1 asks for the counts explicitly; only the one-call-deeper entry point
    is not shown. A hand-rolled Levenshtein backtrace is an accepted alternative.
  - **Disclosed, because the material is ambiguous there:** the band table's edges. `< 5%` and
    `5–15%` leave 5.0 itself in both rows, and `15–30%` against `> 30%` leaves 30.0 in neither.
    Step 4 closes both — 5.0 is `"good"`, 30.0 is `"poor"` — rather than leaving a learner to guess.
    Neither boundary is hit by the shipped cases, so this is a specification for safety, not a
    graded distinction; if a case is ever added at exactly 5% or 30%, this note is the contract.
- **Determinism.** Integer counts plus one rational. Both the counts and the bands are stable across
  runs. Pin `jiwer == 4.0.0`: the counts are a property of the alignment, but the attribute names on
  the returned object are library API.
- Compare the five integers and `"quality"` exactly; `"wer"` with tolerance `1e-4`.
- **The S/D/I split is unambiguous on all three cases.** Equal-cost alignments can in general trade
  one substitution against a deletion-plus-insertion pair, so this was checked rather than assumed: a
  hand-rolled Levenshtein backtrace was run under three tie-break priorities (`s>d>i`, `d>i>s`,
  `i>d>s`) and all three returned `(2,0,0)`, `(0,0,0)` and `(0,1,0)` — identical to `jiwer`. Re-run
  that check if any pair is edited.
- **What each case is for:**
  - **Case 1** — two substitutions, landing in the `"fair"` band; the reference and hypothesis differ
    only in ways that cannot be read as insertions.
  - **Case 2** — an identical pair: rate 0.0, zero errors, and the `"excellent"` band. It is the only
    case that catches a solution which reports a floor of 1 error, or which mislabels 0%.
  - **Case 3** — a single **deletion**, so the count lands in a different one of the three buckets
    than case 1, and its 20% is in the same band as case 1's 22.2% while having a different rate.
- Verified on the shipped cases — each wrong reading below was implemented and run:
  - **Rounding the rate before computing the error total** (`round(round(rate,4) * words)`):
    identical on all three shipped cases — an accepted route here, but it diverges for a rate whose
    4-decimal rounding shifts the product across a `.5` boundary, so the statement pins the order.
  - **Band edges inclusive on the wrong side** (`<= 5` / `<= 15` / `<= 30`): identical on all three,
    since no case sits on an edge — this is why the notes call the boundary a specification rather
    than a graded distinction.
  - **`errors` as the sum of the three counts**: 2 / 0 / 1 — identical on all three shipped cases,
    because insertions cannot make the two disagree unless the hypothesis is longer than the
    reference. Accepted here; note it is *not* the same quantity in general, and the material's own
    line 454 is the rate-based form.
  - **Reference word count from the hypothesis**: case 3 gives 4 instead of 5, and `errors` 1 —
    caught by case 3, the only case where the two lengths differ.
  - **Using `jiwer.wer()` alone and leaving the counts at 0**: caught on cases 1 and 3.
  - **Percentage compared without scaling** (`rate < 5` rather than `rate * 100 < 5`): every case
    becomes `"excellent"` — caught by cases 1 and 3.
- **Overlap check:** this is the only text-scoring question in the module. The previous version of
  this question additionally graded a normalisation step (lower-casing and punctuation stripping);
  the current material's WER demo feeds already-clean strings, so that step was dropped rather than
  kept as an untaught requirement.
- All three cases executed against the reference solution.
