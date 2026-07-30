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

## Adding a plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json`.
2. Add skills under `plugins/<name>/skills/<skill>/SKILL.md`.
3. (Optional) Declare MCP servers in `plugins/<name>/.mcp.json`.
4. Register it in `.claude-plugin/marketplace.json` under `plugins`.
