# core/ — provider-neutral knowledge

The canonical, tool-agnostic knowledge base: plain markdown code guidelines, patterns,
and architecture notes with **no Claude-specific packaging**.

Why it's separate: Claude Code plugins (`../plugins/*`) are a Claude-specific format
(marketplace.json, plugin.json, SKILL.md frontmatter). The *content* of that knowledge
is portable. Keeping the substance here means a future adapter for another provider
(e.g. OpenAI/Codex emitting `AGENTS.md`) can reuse the same source without touching the
plugin packaging.

For now, plugin skills embed their own copy of the rules (skills are copied out
standalone when a plugin is installed, so they can't read this path at runtime). This
directory is the human- and cross-tool-facing source of truth; the sync direction is
`core/` → plugin skills.

```
core/
  guidelines/
    flutter.md      # Flutter/Dart conventions (mirrored by mobile-dev's flutter-guidelines skill)
```
