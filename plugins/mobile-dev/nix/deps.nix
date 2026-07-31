# Runtime dependencies for the `mobile-dev` plugin's skills.
# A function `pkgs -> [ derivation ]`. The flake auto-discovers this file and exposes
# `packages.<system>.mobile-dev-deps` from it. Add packages here as skills need them.
pkgs: [
  # store-screenshots: stdlib-only python3 scripts drive headless chromium — render.py
  # composites authored HTML to exact store dimensions, and render_phone.py renders app
  # screenshots onto photorealistic 3D phone models (Three.js/WebGL via SwiftShader,
  # captured over the DevTools protocol by cdp_shot.py). No image-generation API.
  pkgs.python3
  pkgs.chromium
]
