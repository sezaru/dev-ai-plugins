# Runtime dependencies for the `mobile-dev` plugin's skills.
# A function `pkgs -> [ derivation ]`. The flake auto-discovers this file and exposes
# `packages.<system>.mobile-dev-deps` from it. Add packages here as skills need them.
pkgs: [
  # ASO screenshots skill (compose.py / showcase.py) — Pillow-based image compositing.
  (pkgs.python3.withPackages (ps: [ps.pillow]))
]
