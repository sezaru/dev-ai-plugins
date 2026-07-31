#!/usr/bin/env python3
"""
OpenRouter image-edit adapter for the ASO screenshots skill.

Replaces the Gemini-MCP `edit_image` tool: sends one or more reference images plus a
text instruction to an image-capable model via OpenRouter's dedicated images endpoint
(POST /api/v1/images), generates N variations concurrently, then crops+resizes each to
exact App Store Connect dimensions.

Env:
  OPENROUTER_API_KEY   required — your OpenRouter key
  OPENROUTER_MODEL     optional — image-capable model slug (default below)

Example:
  python3 edit_openrouter.py \
    --image screenshots/01-slug/scaffold.png \
    --prompt-file /tmp/p.txt \
    --out-prefix screenshots/01-slug/v --n 3 \
    --width 1290 --height 2796
"""

import argparse
import base64
import concurrent.futures as futures
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request

from PIL import Image

API_URL = "https://openrouter.ai/api/v1/images"
# Image-in/image-out models confirmed on OpenRouter. Default is cheap + capable;
# google/gemini-3-pro-image ("Nano Banana Pro") is the higher-quality option.
DEFAULT_MODEL = "google/gemini-2.5-flash-image"  # override via --model / OPENROUTER_MODEL
REQUEST_TIMEOUT = 240


def data_url(path):
    mime = mimetypes.guess_type(path)[0] or "image/png"
    with open(path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return f"data:{mime};base64,{b64}"


def build_body(model, prompt, image_paths, n=1):
    return {
        "model": model,
        "prompt": prompt,
        "n": n,
        "input_references": [
            {"type": "image_url", "image_url": {"url": data_url(p)}}
            for p in image_paths
        ],
    }


def extract_image_bytes(resp_json):
    """Pull the first returned image out of a /api/v1/images response.

    Documented shape: {"data": [{"b64_json": "...", "media_type": "image/png"}]}.
    Falls back to a url field if a provider returns one instead of base64.
    """
    data = resp_json.get("data")
    if not isinstance(data, list) or not data:
        raise RuntimeError(f"No image in response: {json.dumps(resp_json)[:800]}")

    item = data[0]
    b64 = item.get("b64_json")
    if b64:
        return base64.b64decode(b64)

    url = item.get("url") or (item.get("image_url") or {}).get("url")
    if url:
        if url.startswith("data:"):
            return base64.b64decode(url.split(",", 1)[1])
        with urllib.request.urlopen(url, timeout=REQUEST_TIMEOUT) as r:
            return r.read()

    raise RuntimeError(f"No b64_json/url in data item: {json.dumps(item)[:400]}")


def call_openrouter(api_key, body):
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:800]
        raise RuntimeError(f"OpenRouter HTTP {e.code}: {detail}")


def crop_to_aspect_top(img, tw, th):
    """Crop to target aspect ratio, preserving the TOP edge (where the headline sits)."""
    target = tw / th
    w, h = img.size
    if w / h > target:  # too wide → trim sides, keep full height, center-x
        cw = round(h * target)
        x = (w - cw) // 2
        return img.crop((x, 0, x + cw, h))
    else:  # too tall/narrow → trim bottom, keep full width, preserve top
        ch = round(w / target)
        return img.crop((0, 0, w, ch))


def finalize(raw_bytes, out_path, tw, th, resize=True):
    tmp = out_path + ".raw"
    with open(tmp, "wb") as f:
        f.write(raw_bytes)
    img = Image.open(tmp).convert("RGB")
    if resize:
        img = crop_to_aspect_top(img, tw, th).resize((tw, th), Image.LANCZOS)
    img.save(out_path, "JPEG", quality=95)
    os.remove(tmp)
    return img.size


def one_variation(idx, api_key, body, out_path, tw, th, resize):
    resp = call_openrouter(api_key, body)
    raw = extract_image_bytes(resp)
    size = finalize(raw, out_path, tw, th, resize)
    return idx, out_path, size


def main():
    p = argparse.ArgumentParser(description="OpenRouter image-edit adapter")
    p.add_argument("--image", action="append", required=True,
                   help="Input image path (repeatable; order = scaffold, then style, then approved)")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--prompt", help="Instruction text")
    g.add_argument("--prompt-file", help="File containing the instruction text")
    p.add_argument("--out-prefix", required=True, help="Output prefix; writes <prefix><i>.jpg")
    p.add_argument("--n", type=int, default=3, help="Number of variations (default 3)")
    p.add_argument("--ext", default="jpg", help="Output extension (default jpg)")
    p.add_argument("--width", type=int, default=1290, help="Target width (default 1290 = iPhone 6.7\")")
    p.add_argument("--height", type=int, default=2796, help="Target height (default 2796)")
    p.add_argument("--no-resize", action="store_true", help="Skip crop/resize to App Store dims")
    p.add_argument("--model", default=os.environ.get("OPENROUTER_MODEL", DEFAULT_MODEL),
                   help="OpenRouter image-capable model slug")
    args = p.parse_args()

    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        sys.exit("OPENROUTER_API_KEY is not set.")

    for img in args.image:
        if not os.path.isfile(img):
            sys.exit(f"Input image not found: {img}")

    prompt = args.prompt
    if args.prompt_file:
        with open(args.prompt_file) as f:
            prompt = f.read()

    body = build_body(args.model, prompt, args.image)
    tw, th = args.width, args.height
    resize = not args.no_resize

    outs = [f"{args.out_prefix}{i}.{args.ext}" for i in range(1, args.n + 1)]
    os.makedirs(os.path.dirname(outs[0]) or ".", exist_ok=True)

    print(f"model={args.model}  variations={args.n}  target={tw}x{th}  inputs={len(args.image)}")
    errors = []
    with futures.ThreadPoolExecutor(max_workers=args.n) as ex:
        jobs = [ex.submit(one_variation, i, api_key, body, outs[i - 1], tw, th, resize)
                for i in range(1, args.n + 1)]
        for fut in futures.as_completed(jobs):
            try:
                idx, path, size = fut.result()
                print(f"✓ v{idx}: {path} ({size[0]}x{size[1]})")
            except Exception as e:  # noqa: BLE001 — report per-variation, keep the rest
                errors.append(str(e))
                print(f"✗ variation failed: {e}", file=sys.stderr)

    if errors and len(errors) == args.n:
        sys.exit("All variations failed.")


if __name__ == "__main__":
    main()
