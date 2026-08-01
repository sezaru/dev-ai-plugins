#!/usr/bin/env python3
"""Render an app screenshot onto a photorealistic 3D phone -> transparent PNG.

Stage 1 of the screenshot pipeline: take a raw app screenshot, map it onto a real
phone model's screen, and render it (head-on, or tilted for a dynamic hero shot) over a
transparent background. The resulting PNG drops straight into a `.stage` HTML fragment
(see design/base.css) as the phone element; render.py then composites the full store
screenshot around it. Fully offline, no image-generation API.

Usage:
  render_phone.py shot.png --model iphone-12-pro --out phone.png
  render_phone.py shot.png --model s21-ultra --yaw 18 --pitch -6 --out hero.png
  render_phone.py shot.png --model iphone-12-pro --width 1290 --height 2796 --out phone.png

Models live in assets/models/<name>/scene.gltf. Bundled: iphone-12-pro, s21-ultra (both
CC-BY-4.0 by DatSketch — see assets/models/NOTICE.md). `--model` also accepts a path to
any scene.gltf/.glb with a separable screen mesh.

Chromium binary: $CHROMIUM_BIN, else chromium / chromium-browser / google-chrome on PATH.
"""
import argparse, json, os, pathlib, shutil, struct, sys, urllib.request

import cdp_shot


def png_size(path):
    """(width, height) of a PNG from its IHDR — avoids a Pillow dependency."""
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])

HERE = os.path.dirname(os.path.abspath(__file__))
MODELS = os.path.join(HERE, "assets", "models")
TEMPLATE = os.path.join(HERE, "three", "phone.html")


def find_chromium():
    if os.environ.get("CHROMIUM_BIN"):
        return os.environ["CHROMIUM_BIN"]
    for name in ("chromium", "chromium-browser", "google-chrome-stable", "google-chrome"):
        p = shutil.which(name)
        if p:
            return p
    sys.exit("No chromium found. Set CHROMIUM_BIN or install chromium.")


def resolve_model(model):
    """A bundled name (assets/models/<name>/scene.gltf) or a direct path to a gltf/glb."""
    cand = os.path.join(MODELS, model, "scene.gltf")
    if os.path.isfile(cand):
        return cand
    if os.path.isfile(model):
        return os.path.abspath(model)
    avail = sorted(p.name for p in pathlib.Path(MODELS).iterdir() if p.is_dir()) if os.path.isdir(MODELS) else []
    sys.exit(f"Model '{model}' not found. Bundled: {', '.join(avail) or '(none)'}. "
             f"Or pass a path to a scene.gltf/.glb.")


def file_url(path):
    return "file://" + urllib.request.pathname2url(os.path.abspath(path))


def main():
    p = argparse.ArgumentParser(description="Render a screenshot onto a 3D phone")
    p.add_argument("screenshot", help="raw app screenshot PNG")
    p.add_argument("--model", required=True, help="bundled model name or path to scene.gltf/.glb")
    p.add_argument("--out", required=True, help="output PNG (transparent)")
    p.add_argument("--yaw", type=float, default=0, help="orbit degrees about the vertical axis")
    p.add_argument("--pitch", type=float, default=0, help="orbit degrees about the horizontal axis")
    p.add_argument("--orient", choices=("portrait", "landscape"), default="portrait",
                   help="device orientation (landscape rolls it 90° — for tablets); feed a "
                        "landscape screenshot when using landscape")
    p.add_argument("--scale", type=float, default=1.0,
                   help="how much of the frame the device fills (1.0 = fill width; <1 leaves "
                        "gutters for copy beside it, e.g. 0.6 for a split layout)")
    p.add_argument("--width", type=int, default=1290)
    p.add_argument("--height", type=int, default=2796)
    args = p.parse_args()

    if not os.path.isfile(args.screenshot):
        sys.exit(f"Screenshot not found: {args.screenshot}")
    model = resolve_model(args.model)
    chromium = find_chromium()

    q = (f"?model={file_url(model)}&shot={file_url(args.screenshot)}"
         f"&yaw={args.yaw}&pitch={args.pitch}&orient={args.orient}&scale={args.scale}&bg=none")
    url = file_url(TEMPLATE) + q
    meta = cdp_shot.capture(chromium, url, os.path.abspath(args.out),
                            args.width, args.height, transparent=True)
    print(f"✓ {args.out} ({args.width}x{args.height}, model={os.path.basename(os.path.dirname(model))})")

    if meta:
        side = os.path.splitext(os.path.abspath(args.out))[0] + ".json"
        with open(side, "w") as f:
            json.dump(meta, f, indent=2)
        d = meta.get("device", {})
        print(f"  device box: x={d.get('x')} y={d.get('y')} w={d.get('w')} h={d.get('h')}  "
              f"(place copy clear of this box) → {os.path.basename(side)}")
        # warn if the screenshot's aspect doesn't match the screen — the source of stretch/bars
        exp = meta.get("screen_aspect")
        sz = png_size(args.screenshot)
        if exp and sz:
            got = sz[0] / sz[1]
            if abs(got / exp - 1) > 0.03:
                ideal_w = round(sz[1] * exp)
                print(f"  ⚠ screenshot aspect {got:.3f} ≠ screen {exp:.3f} — it will be stretched. "
                      f"Recapture at ~{ideal_w}×{sz[1]} (or any {exp:.3f} ratio) to fit cleanly.",
                      file=sys.stderr)


if __name__ == "__main__":
    main()
