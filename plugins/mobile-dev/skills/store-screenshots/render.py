#!/usr/bin/env python3
"""
Render authored screenshot HTML to exact app-store PNG dimensions — offline, no API.

You (the LLM) author each screenshot as a small HTML fragment using the classes in
design/base.css (a `.stage` with a headline, an app screenshot, optional breakout).
This script supplies the shared design system + bundled fonts and renders each fragment
with headless chromium at the exact target size, so a whole SET stays consistent.

Usage:
  render.py screenshots/01.html [02.html ...] --out-dir screenshots/final
  render.py screenshots/*.html --width 1290 --height 2796   # iPhone 6.7" (default)
  render.py 01.html --width 1080 --height 1920              # Play Store phone

Fonts (Montserrat Black, Inter) are bundled in assets/fonts and embedded automatically.
Local <img src="…"> files are inlined as data URIs so they always load.
Chromium binary: $CHROMIUM_BIN, else chromium / chromium-browser / google-chrome on PATH.
"""

import argparse
import base64
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BASE_CSS = os.path.join(HERE, "design", "base.css")
FONT_DIR = os.path.join(HERE, "assets", "fonts")
FONTS = [
    ("Montserrat", 900, "Montserrat-Black.ttf"),
    ("Inter", "100 900", "InterVariable.ttf"),
]


def find_chromium():
    if os.environ.get("CHROMIUM_BIN"):
        return os.environ["CHROMIUM_BIN"]
    for name in ("chromium", "chromium-browser", "google-chrome-stable", "google-chrome"):
        p = shutil.which(name)
        if p:
            return p
    sys.exit("No chromium found. Set CHROMIUM_BIN or install chromium.")


def font_face_css():
    blocks = []
    for family, weight, fname in FONTS:
        path = os.path.join(FONT_DIR, fname)
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        blocks.append(
            f"@font-face{{font-family:'{family}';font-weight:{weight};"
            f"src:url(data:font/ttf;base64,{b64}) format('truetype');}}"
        )
    return "\n".join(blocks)


def inline_images(html, base_dir):
    """Replace <img src="local/file"> with a base64 data URI so it always loads."""
    def repl(m):
        src = m.group(2)
        if src.startswith(("data:", "http://", "https://")):
            return m.group(0)
        path = src if os.path.isabs(src) else os.path.join(base_dir, src)
        if not os.path.isfile(path):
            return m.group(0)
        mime = mimetypes.guess_type(path)[0] or "image/png"
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        return f'{m.group(1)}"data:{mime};base64,{b64}"'
    return re.sub(r'(src=)["\']([^"\']+)["\']', repl, html)


def build_document(fragment, base_dir):
    css = font_face_css() + "\n" + open(BASE_CSS).read()
    body = inline_images(fragment, base_dir)
    if "<html" in body.lower():
        # full document — inject our <style> right after <head>
        return re.sub(r"(<head[^>]*>)", r"\1<style>" + css + "</style>", body, count=1,
                      flags=re.IGNORECASE)
    return (f"<!doctype html><html><head><meta charset=utf-8><style>{css}</style>"
            f"</head><body>{body}</body></html>")


def render(chromium, fragment_path, out_path, w, h):
    base_dir = os.path.dirname(os.path.abspath(fragment_path))
    doc = build_document(open(fragment_path).read(), base_dir)
    with tempfile.TemporaryDirectory() as td:
        full = os.path.join(td, "page.html")
        with open(full, "w") as f:
            f.write(doc)
        # Fully isolate chromium from the user's environment: a throwaway profile AND a
        # fresh HOME/XDG so nothing is read from or written to ~/.config, ~/.cache, etc.,
        # and there is never a clash with a running chromium. All state lives in this
        # temp dir and is deleted on exit.
        for sub in ("home", ".config", ".cache", ".local", "profile", "cache", "crash"):
            os.makedirs(os.path.join(td, sub), exist_ok=True)
        env = dict(os.environ)
        env.update({
            "HOME": os.path.join(td, "home"),
            "XDG_CONFIG_HOME": os.path.join(td, ".config"),
            "XDG_CACHE_HOME": os.path.join(td, ".cache"),
            "XDG_DATA_HOME": os.path.join(td, ".local"),
        })
        cmd = [
            chromium, "--headless=new", "--no-sandbox", "--disable-gpu",
            "--disable-dev-shm-usage", "--hide-scrollbars",
            "--no-first-run", "--no-default-browser-check",
            "--disable-extensions", "--disable-sync",
            "--force-device-scale-factor=1", f"--window-size={w},{h}",
            f"--user-data-dir={os.path.join(td, 'profile')}",
            f"--disk-cache-dir={os.path.join(td, 'cache')}",
            f"--crash-dumps-dir={os.path.join(td, 'crash')}",
            f"--screenshot={out_path}", full,
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if not os.path.isfile(out_path):
            sys.exit(f"Render failed for {fragment_path}:\n{r.stderr[-800:]}")


def main():
    p = argparse.ArgumentParser(description="Render screenshot HTML to store PNGs")
    p.add_argument("inputs", nargs="+", help="HTML fragment file(s)")
    p.add_argument("--out-dir", default=None, help="Output dir (default: alongside each input)")
    p.add_argument("--width", type=int, default=1290, help="Target width (default 1290)")
    p.add_argument("--height", type=int, default=2796, help="Target height (default 2796)")
    args = p.parse_args()

    chromium = find_chromium()
    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)
    for inp in args.inputs:
        stem = os.path.splitext(os.path.basename(inp))[0]
        out = os.path.join(args.out_dir or os.path.dirname(os.path.abspath(inp)), stem + ".png")
        render(chromium, inp, out, args.width, args.height)
        print(f"✓ {out} ({args.width}x{args.height})")


if __name__ == "__main__":
    main()
