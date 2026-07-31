# Runtime dependencies for the `mobile-dev` plugin's skills.
# A function `pkgs -> [ derivation ]`. The flake auto-discovers this file and exposes
# `packages.<system>.mobile-dev-deps` from it. Add packages here as skills need them.
pkgs: [
  # python3: render.py (store-screenshots, stdlib only) + Pillow for the legacy
  # aso-appstore-screenshots compositor.
  (pkgs.python3.withPackages (ps: [ps.pillow]))
  # store-screenshots: renders authored HTML to exact store dimensions.
  pkgs.chromium
]
