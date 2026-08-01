---
name: flutter-on-device-ai
description: Use when adding fully offline on-device AI to a Flutter app — OCR (platform ML Kit/Vision + downloadable ONNX PP-OCRv5/TrOCR) and a small local LLM (llama.cpp) for grounded title/keyword generation, with an engine-selection abstraction, runtime model download, and the hard no-cloud/no-token constraints.
---

# On-device AI (offline OCR + small LLM)

Read the user's documents/images and label them **entirely on-device** — content never leaves the
phone, and the user never needs an account or token. Two jobs: **transcription** (full text →
search index) and **title/keywords** (a small grounded LLM). A platform-vs-downloaded engine
abstraction, runtime model download, and hard lessons from shipping this in caremate.

Feeds `flutter-sqlite-ffi-fts5` (OCR text → the FTS index) and
`flutter-file-photo-attachments` (the capture flow that runs it).

## Contents

1. Hard constraints (non-negotiable)
2. Two jobs, two model types
3. The big lesson: don't make one VLM do everything
4. OCR — platform engine + downloadable ONNX
5. LLM — small, grounded, language-matched
6. Runtime model download (never bundle weights)
7. Engine selection & degradation
8. Dependencies & build gotchas
9. Gotchas (learned on-device)

## 1. Hard constraints (non-negotiable)

- **Fully offline.** Document text/images never touch a network. This is a product constraint,
  not a nice-to-have — it rules out any cloud API.
- **No account, no token, ever.** A user must never create a HuggingFace account or paste a
  token. Ship weights by (a) **self-hosting** permissively-licensed models on your own CDN
  (Gemma's and Apache-2.0 licenses permit redistribution), or (b) using **ungated** repos
  (verify `gated: false`). Gated-repo + token flows are dev-only shortcuts, never shippable.

## 2. Two jobs, two model types

- **Transcription** → the *full* text of an image/page, fed to the search index. Needs an **OCR**
  model, not a summarizer.
- **Title + keywords/summary** → a short label in the **device language**, grounded strictly in
  the recognized text (no invented names/dates/dosages). Needs a small **text LLM**.

## 3. The big lesson: don't make one VLM do everything

The tempting design — one vision LLM that OCRs *and* summarizes from the image — **failed on
device**: a 2B VLM ran >5 min/image on a flagship phone. A vision LLM is the wrong tool for OCR.
**Split the pipeline:** a dedicated OCR model for text, then a small text LLM for the label. Each
is fast and swappable.

## 4. OCR — platform engine + downloadable ONNX

Two tiers behind one interface:

- **Platform OCR (always available, bundled, fast, print-good):** Android **ML Kit Text
  Recognition** / iOS **Vision** via a method channel. Also expose the OS **document scanner**
  (ML Kit Document Scanner / VisionKit) for edge-detected capture. Probe support first:
  ```dart
  static Future<bool> isSupported() async {
    try { return await _channel.invokeMethod<bool>('isSupported') ?? false; }
    on PlatformException { return false; } on MissingPluginException { return false; }
  }
  static Future<OcrResult> recognizeImage(String path) async { /* -> {text, blocks} */ }
  ```
- **Downloadable ONNX (better, offline, for handwriting / weak devices):** `onnxruntime` running
  **PP-OCRv5** (fast, ~21 MB, print) or **TrOCR-base-handwritten** (~340 MB, handwriting). Bundle
  only the small **dict/vocab assets**; download the heavy `.onnx` weights at runtime. **Run
  inference in the plugin's `runAsync` isolate** to avoid ANR.

## 5. LLM — small, grounded, language-matched

Use a **small** text LLM via `lib_llama_cpp` (llama.cpp) — e.g. LFM2-700M Q4_0 (~425 MB,
ungated). Feed it OCR text, get `{title, keywords}` back:

- **Size has a floor and a ceiling.** In testing, 350M *hallucinated* content; 700M was the
  smallest that produced faithful titles + real keywords (~6s); 1.2B was 2.4× slower for no gain.
  Pick the smallest model that's faithful.
- **Cap the input.** Handed a full ~3000-char OCR of a dense PDF, the 700M model stopped following
  the output format and looped. **Truncate to ~1500 chars** — the title/keywords live in the
  header/first page anyway.
- **Grounded prompt**, JSON-constrained, matched to the device language: "use only the text below;
  do not invent names, dates, dosages, or results."
- Q4_0 quantization hits ARM i8mm int8 kernels — keep decode fast.

## 6. Runtime model download (never bundle weights)

Multi-GB weights can't ship in the APK/IPA. Download on first use to **app-private storage**,
**resumable**, with **progress**, from **your** HTTPS URL (self-hosted) — anonymous, versioned:

```dart
Future<bool> needsDownload() async =>
    await resolveEngine() == OcrEngine.ppocr && !await OnnxOcrEngine.isInstalled(mode);
Future<void> download({void Function(int percent, String phase)? onProgress}) =>
    OnnxOcrEngine.download(mode, onProgress: onProgress);
```

## 7. Engine selection & degradation

Detect what the device can run, prefer the bundled engine, fall back to the downloadable one — and
optionally let the user choose (the trade-offs — size, RAM, speed, quality — are personal):

```dart
Future<OcrEngine> resolveEngine() async {
  if (forceOnnx) return OcrEngine.ppocr;                     // debug pin
  return await TextRecognizer.isSupported() ? OcrEngine.mlkit : OcrEngine.ppocr;
}
```

**Degrade gracefully:** if no LLM engine is available, search still works on whatever OCR text you
have — just disable title/summary with a "search quality limited" notice. Keep platform OCR as the
always-available default so the core feature never depends on a download.

## 8. Dependencies & build gotchas

```yaml
dependencies:
  onnxruntime: ^1.4.1      # ONNX OCR (PP-OCRv5 / TrOCR)
  lib_llama_cpp: ^0.7.1    # small text LLM (needs a recent Dart SDK)
  image: ^4.8.0            # pre-process frames for the detector
```

- **`onnxruntime` needs `compileSdkVersion 33`** (`com.gtbluesky.onnxruntime`) — ensure the
  Android platform-33 SDK is available or the build fails.
- **`lib_llama_cpp` needs a recent Dart SDK** (≥3.11.x) — it won't resolve on older toolchains;
  bump Flutter/Dart if it fails to pub-get.
- Platform OCR is native: implement the method channel in `MainActivity.kt` (ML Kit) /
  `OcrChannel.swift` (Vision).

## 9. Gotchas (learned on-device)

- **Split OCR from summarization** — one VLM doing both is unusably slow (>5 min/image).
- **Never require a token/account** — self-host or use ungated Apache-2.0 weights; verify
  `gated: false`.
- **Never bundle weights** — download at runtime, resumable, to app-private storage.
- **Run inference off the UI isolate** (`runAsync` / `Isolate`) or you ANR.
- **Cap LLM input (~1500 chars)** — long OCR breaks small-model output format.
- **Pick the smallest faithful model** — too small hallucinates; too big is slow for no quality
  gain. A/B on device.
- **Platform OCR is print-tuned** (ML Kit Latin) — offer TrOCR for handwriting.
- **Don't hard-code an AICore/Gemini-Nano dependency** — the AICore system app is absent on many
  devices; its `prepareInferenceEngine()` fails there. Keep a device-independent llama.cpp path.
- **Ground the prompt + match device language** — no invented names/dates/dosages; that's the
  whole point of an on-device medical/records labeler.
- **Degrade, never block** — no LLM → search still works on OCR text; keep bundled OCR as the
  floor so the feature works with zero downloads.
