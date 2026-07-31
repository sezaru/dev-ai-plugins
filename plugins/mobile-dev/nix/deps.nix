# Runtime dependencies for the `mobile-dev` plugin's skills.
# A function `pkgs -> [ derivation ]`. The flake auto-discovers this file and exposes
# `packages.<system>.mobile-dev-deps` from it. Add packages here as skills need them.
pkgs: [
  # store-screenshots: render.py (python3 stdlib) drives headless chromium to render
  # authored HTML to exact store dimensions.
  pkgs.python3
  pkgs.chromium
]
