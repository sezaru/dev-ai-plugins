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
import argparse, os, pathlib, shutil, sys, urllib.request

import cdp_shot

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
    p.add_argument("--width", type=int, default=1290)
    p.add_argument("--height", type=int, default=2796)
    args = p.parse_args()

    if not os.path.isfile(args.screenshot):
        sys.exit(f"Screenshot not found: {args.screenshot}")
    model = resolve_model(args.model)
    chromium = find_chromium()

    q = (f"?model={file_url(model)}&shot={file_url(args.screenshot)}"
         f"&yaw={args.yaw}&pitch={args.pitch}&bg=none")
    url = file_url(TEMPLATE) + q
    cdp_shot.capture(chromium, url, os.path.abspath(args.out),
                     args.width, args.height, transparent=True)
    print(f"✓ {args.out} ({args.width}x{args.height}, model={os.path.basename(os.path.dirname(model))})")


if __name__ == "__main__":
    main()
