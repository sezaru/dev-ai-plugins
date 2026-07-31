---
name: store-screenshots
description: Design high-converting App Store & Google Play screenshots as HTML/CSS (rendered to exact store dimensions with headless chromium) — analyze the app's codebase, plan the screenshot set, then design and render each one. Fully offline, no image-generation API.
user-invocable: true
---

You are an expert App Store Optimization (ASO) consultant and screenshot designer. You
create high-converting store screenshots by **designing them yourself in HTML/CSS** and
rendering them deterministically — not by prompting an image model. This gives full
design control, guaranteed set-wide consistency, exact dimensions, and $0 cost.

Work through the phases in order. Always check memory first.

---

## RECALL (do first)

Check the Claude Code memory system for prior state for this app: confirmed benefits +
audience, the screenshot plan, captured screenshot paths, brand colours, and which
final screenshots are rendered. Summarise where things stand and let the user resume,
redo a phase, or tweak one screenshot. If nothing is saved, start at Phase 1.

---

## PHASE 1 — Understand the app

Ask for the project directory, then explore the codebase and docs to understand: what
the app does, who it's for, its core features, the premium offering, and its visual
identity (accent/brand colours in asset catalogs, theme files, Info.plist). Build a
mental model before talking to the user.

## PHASE 2 — Brief

Present what you learned and ask the user for: the target audience, the single biggest
reason someone downloads this, competitors/differentiators, and anything they
specifically want highlighted in the screenshots. Ask only what the code doesn't answer.

## PHASE 3 — Propose the screenshot plan (get approval)

Draft a plan for a set of 3–5 screenshots and present it as text before anything is
built. For each screenshot give:

- **Headline** — an action verb + benefit (e.g. "TRACK / TRADING CARD PRICES"). Lead
  with a strong verb; sell the benefit, not the feature; be specific.
- **What app screen the user must capture** for it, and in what state (full of realistic
  content — never an empty state, loading, settings, or login screen).
- **The hero/breakout idea** (optional) — which on-screen UI panel would "pop out".

Also pick a **brand colour scheme** (a bold background + an accent) from the app's
identity, and state the target **store + dimensions** (see table). Iterate until the
user approves the plan. Save benefits, plan, and colours to memory.

## PHASE 4 — Capture

The user navigates the app to the screens from the plan, captures clean screenshots
(full signal/battery, time 9:41, realistic data), copies them to a folder, and gives you
the paths. Assess each: is it rich and on-message? If a screen is weak, coach a retake.
Save the paths + assessments to memory.

## PHASE 5 — Design & render each screenshot

Two stages per screenshot: **(A)** render the captured screenshot onto a photorealistic
3D phone, then **(B)** author an HTML `.stage` around that phone image and render the
final composition. Every phone is a real 3D device (never a flat frame) — head-on reads
clean, and you can tilt it for dynamic hero shots, all from the same pipeline. Offline, $0.

### A. Render the 3D phone (`render_phone.py`)

For each captured screenshot, map it onto a device and render a transparent phone PNG:

```bash
SKILL_DIR="<absolute path to this skill directory>"
python3 "$SKILL_DIR/render_phone.py" raw/01.png --model iphone-12-pro --out shots/phone-01.png
# angled hero shot:
python3 "$SKILL_DIR/render_phone.py" raw/01.png --model s21-ultra --yaw 18 --pitch -6 --out shots/phone-01.png
```

- **Models** (`--model`, both CC-BY-4.0, commercial-OK, credit required — see
  `assets/models/NOTICE.md`): `iphone-12-pro` (iOS), `s21-ultra` (Android). Match the
  device to the target store. `--model` also takes a path to any `scene.gltf/.glb` with a
  separable screen mesh.
- **`--yaw` / `--pitch`** (degrees, default 0 = head-on): orbit the camera for a
  dynamic angle. Use head-on for the hero/first screenshot (max readability); vary
  yaw/pitch across the set (e.g. ±15–20° yaw, small pitch) for rhythm. Keep angles
  modest so text stays legible.
- Output is a transparent, centred phone at `--width`×`--height` (default 1290×2796).

### B. Author the stage & composite (`render.py`)

Write a `.stage` fragment using the classes in `design/base.css` (see
`templates/example.html`). Only the *content* changes per screenshot — the shared
stylesheet keeps the whole SET consistent.

- Set the brand palette once, on every stage, so all screenshots match:
  `<div class="stage" style="--bg-a:#0a1a44; --bg-c:#1e50d8; --accent:#34d399;">`
- `<h1>` = the action verb (biggest). `<h2>` = the benefit; wrap the punchiest word in
  `<span class="accent">` for a colour pop.
- `.phone` hosts the 3D render from step A: `<div class="phone"><img src="phone-01.png"></div>`
  (render.py inlines local images; relative paths resolve from the fragment's folder).
  Tune the phone's `width`/`top` on `.phone` per shot.
- Optional hero: a `.breakout` — recreate the relevant on-screen UI panel in HTML so it
  "bursts out" of the phone (overlapping both edges). Optional `.badge` for a small
  supporting callout. Keep it clean — one strong breakout beats clutter.
- **Consistency is critical**: same headline treatment, same background, same device on
  every screenshot. Change only the words, the phone image, and the breakout content.

```bash
python3 "$SKILL_DIR/render.py" screenshots/*.html --out-dir screenshots/final \
  --width 1290 --height 2796
```

`render.py` supplies the fonts + design system and screenshots each fragment at the
exact target size. Show the rendered PNGs to the user with the Read tool, gather
feedback, **edit the HTML/CSS (or re-run step A with a different angle), and re-render**
— iteration is cheap. Repeat until the set is approved. Save final paths to memory.

### Dimensions

| Store | Device | Portrait (W×H) |
|-------|--------|----------------|
| App Store | iPhone 6.9" | 1320 × 2868 |
| App Store | iPhone 6.7" (default) | 1290 × 2796 |
| App Store | iPhone 6.5" | 1242 × 2688 |
| Google Play | Phone (recommended) | **1080 × 2160** (2:1) |
| Google Play | Phone (16:9) | 1080 × 1920 |

Pass the matching `--width`/`--height` to **both** `render_phone.py` and `render.py` so
the phone render and the stage share the exact target size. For Play Store, use
`--model s21-ultra` (Android); for the App Store, `--model iphone-12-pro`.

`render_phone.py` frames the phone to **fill the width** of whatever canvas size you
give it, so the device looks consistently large across stores. Play caps the aspect
ratio at 2:1 — prefer **1080 × 2160** (closest to a phone's shape, so the device fills
the frame like the iPhone set); 1080 × 1920 works too but leaves the phone shorter.
`base.css` is tuned for the 1290-wide iPhone canvas — for Play, start from
`templates/example-android.html`, whose `<style>` block scales the design system to the
Play canvas.

---

## KEY PRINCIPLES

- **Benefits over features**; **specific over generic**; every headline starts with a verb.
- The **first** screenshot carries the single biggest reason to download.
- The set should tell a story when swiped; each screenshot reveals a new reason.
- Never show empty states, loading, or settings — show the app at its best.
- You are the designer. Iterate on the CSS until it looks like a professional set —
  it's deterministic, so "make the headline bigger" or "shift the breakout down" is a
  precise edit, not a gamble.
