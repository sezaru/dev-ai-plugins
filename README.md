# dev-ai-plugins

Private Claude Code plugin marketplace — a monorepo of internal development plugins.
Not intended for public distribution.

## Plugins

| Plugin | Purpose |
|--------|---------|
| `mobile-dev` | Flutter-based iOS & Android app development: skills, code guidelines, MCP servers |

More to come (e.g. `elixir-dev` for backend) — each is a self-contained, independently
installable plugin under `plugins/`.

## Install (local)

Add this repo as a marketplace, then install the plugins you want:

```
/plugin marketplace add /home/sezdocs/projects/dev-ai-plugins
/plugin install mobile-dev@dev-ai-plugins
```

## Layout

```
dev-ai-plugins/
  .claude-plugin/marketplace.json   # marketplace index (lists all plugins)
  plugins/
    mobile-dev/
      .claude-plugin/plugin.json    # plugin manifest
      skills/                       # Claude Code skills
      .mcp.json                     # MCP servers bundled with the plugin (empty for now)
  core/                             # provider-neutral knowledge (see core/README.md)
    guidelines/
```

## Provider-neutral by design

The valuable content — code guidelines, patterns, MCP configs — is kept portable in
`core/` and as plain skill markdown. The Claude-Code plugin layer is thin packaging on
top. This keeps the door open to a future adapter for other AI tools (e.g. OpenAI/Codex)
that reuses the same knowledge. See `core/README.md`.

## Dependencies (Nix flake)

Plugin skills often need runtime tools (e.g. the ASO screenshots skill needs Python +
Pillow). Those are provided by the flake, **per plugin**.

Each plugin self-declares its deps in `plugins/<name>/nix/deps.nix`. The flake
auto-discovers them and exposes a `<name>-deps` package — no flake edits needed when you
add a plugin or a dep.

There is no way for a pure flake to detect which Claude plugins you have *installed*
(that's Claude runtime state, not Nix). So **enabling a plugin's deps is opt-in**: you
add its `<name>-deps` package to your own config.

```bash
# Quick shell with every plugin's deps:
nix develop github:.../dev-ai-plugins        # or: nix develop  (from a clone)

# Build just one plugin's deps:
nix build .#mobile-dev-deps

# Everything at once:
nix build .#default
```

In a **devenv / home-manager / NixOS** config, add this repo as an input and pull the
per-plugin package for the plugins you use:

```nix
# inputs.dev-ai-plugins.url = "path:/home/sezdocs/projects/dev-ai-plugins";
packages = [
  inputs.dev-ai-plugins.packages.${system}.mobile-dev-deps
  # inputs.dev-ai-plugins.packages.${system}.elixir-dev-deps   # when it exists
];
```

Selecting which `*-deps` packages you include *is* the per-plugin enable/disable toggle.

## Adding a plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json`.
2. Add skills under `plugins/<name>/skills/<skill>/SKILL.md`.
3. (Optional) Declare MCP servers in `plugins/<name>/.mcp.json`.
4. (Optional) Declare Nix deps in `plugins/<name>/nix/deps.nix` (`pkgs -> [ drv ]`).
5. Register it in `.claude-plugin/marketplace.json` under `plugins`.
