# Flutter Guidelines (provider-neutral source)

This is the canonical, tool-agnostic version of the Flutter conventions. Plain markdown
with no Claude-specific frontmatter, so it can be reused by other AI tooling (e.g. an
OpenAI/Codex adapter that emits `AGENTS.md`) or read by humans.

Claude plugin skills (`plugins/mobile-dev/skills/*/SKILL.md`) are the packaged,
Claude-Code-facing view of this knowledge. Keep the substance here; keep the packaging
thin.

## Project layout
- Feature-first: `lib/features/<feature>/{data,domain,presentation}/`.
- Shared code in `lib/core/` (theme, routing, networking, errors).
- One widget per file; `snake_case` filenames matching the primary class.

## State management
- One explicit approach app-wide; never mix paradigms.
- Business logic out of widgets — widgets render state and dispatch intents only.

## Code conventions
- `dart format` is the formatting source of truth.
- Prefer `const` constructors.
- No `print` in committed code — use a logger.
- Handle every `Future`; no silent unawaited async.
- Null-safety strict; avoid `!` unless the invariant is proven and commented.

## Definition of done
- `flutter analyze` clean.
- `dart format --set-exit-if-changed .` passes.
- Relevant tests pass.
