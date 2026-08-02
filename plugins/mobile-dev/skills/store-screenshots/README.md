# store-screenshots

Design high-converting **App Store & Google Play screenshots** as bespoke HTML/CSS, then
render them deterministically to exact store dimensions with headless Chromium — including
photorealistic 3D device mockups. Fully offline, **$0, no image-generation API.**

This README is the **script reference**. For *how the skill runs* (the guided
questionnaire, design guidelines, phases) read `SKILL.md` — or invoke it:

```
/store-screenshots ~/projects/hex_hound/caremate
```

## The core idea

Two things are split cleanly:

- **The pipeline is fixed** (the scripts below): 3D device rendering, the HTML→PNG
  compositor at exact store sizes, bundled fonts, deterministic capture. You drive these,
  never rebuild them.
- **The design is generative** (the skill's job): every screenshot's layout, colour, type
  and composition is authored fresh to match *this* app's brand. Two sets built with this
  skill should look like they came from two different studios. **Match the app, not a
  house template.**

## Requirements

- **Python 3** (stdlib only) + **Chromium** — both from the plugin's nix deps
  (`nix/deps.nix`). No pip installs, no API keys.
- 3D device models are bundled under `assets/models/` (CC-BY-4.0 by DatSketch — see the
  NOTICE there).

## The scripts

**`render.py`** — the compositor. Renders authored screenshot HTML fragment(s) to store
PNGs at exact dimensions, injecting bundled fonts + foundation CSS.
```bash
render.py screenshots/*.html --out-dir screenshots/final          # iPhone 6.7" (1290×2796 default)
render.py 01.html --width 1080 --height 1920                       # Play Store phone
```

**`render_phone.py`** — renders a raw app screenshot onto a photorealistic 3D phone/tablet
model (Three.js/WebGL via SwiftShader), output transparent PNG to drop into a stage.
```bash
render_phone.py raw/01.png --model iphone-12-pro --out shots/dev-01.png
render_phone.py raw/01.png --model s21-ultra --yaw 18 --pitch -6 --out shots/hero.png   # angled hero
render_phone.py raw/01.png --model ipad-pro-12-9 --orient landscape --out shots/dev-01.png
```
Flags: `--model` (bundled name or path to `scene.gltf/.glb`) · `--yaw`/`--pitch` (orbit) ·
`--orient portrait|landscape` · `--scale` · `--width`/`--height`.

**`cdp_shot.py`** — low-level headless-Chromium capture over the DevTools protocol (used by
the two renderers; not usually called directly).

## Directories

| dir | contents |
|---|---|
| `assets/` | bundled fonts + 3D device models (`models/`, with NOTICE) |
| `three/` | Three.js/WebGL runtime for the 3D device renderer |
| `design/` | foundation CSS / design primitives injected at render |
| `examples/` | reference screenshot HTML to learn the fragment format |

## Workflow (see SKILL.md for the full guided version)

1. **Understand the app** — explore the project for what it does, who it's for, and its
   **visual identity** (brand colour, typeface, personality).
2. **Brief** — confirm audience, the single biggest reason to download, differentiators.
3. **Plan the set** — propose the screenshot plan + visual system as text; get approval.
4. **Capture** — user captures the planned raw app screens.
5. **Design & render** — for each: `render_phone.py` (3D device) → author the stage HTML
   bespoke → `render.py` (composite to exact store size). Iterate on PNGs with the user.

Pass matching `--width`/`--height` to **both** `render_phone.py` and `render.py` for a
given target size.

## Notes

- **Dimensions matter:** default 1290×2796 (iPhone 6.7"); use 1080×1920 for Play phone,
  and the iPad sizes for tablet listings. The store rejects mismatched dimensions.
- **The first screenshot does most of the selling** — treat it (and its thumbnail
  legibility) as the priority; see the DESIGN GUIDELINES in SKILL.md.
- Deterministic + offline: same inputs → same PNGs, no network, no per-image cost.
