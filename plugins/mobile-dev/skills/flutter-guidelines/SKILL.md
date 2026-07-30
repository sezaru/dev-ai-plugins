---
name: flutter-guidelines
description: Use when writing, reviewing, or structuring Flutter/Dart code for iOS or Android apps — establishes this workspace's project layout, state-management, and code conventions before generating or changing Flutter code.
---

# Flutter Development Guidelines

Apply these conventions whenever working on a Flutter app in this workspace. This is the seed skill for the `mobile-dev` plugin — expand it as real project patterns solidify.

## Project layout

- **Feature-first structure**, not layer-first. Group by feature, then by layer inside:
  `lib/features/<feature>/{data,domain,presentation}/`.
- Shared cross-feature code lives in `lib/core/` (theme, routing, networking, errors).
- One widget per file; file name is `snake_case`, matching the primary class.

## State management

- Default to a single, explicit approach across the app — do not mix paradigms.
  If the project hasn't chosen one, ask before introducing one.
- Keep business logic out of widgets. Widgets render state and dispatch intents; they
  do not fetch data or hold domain rules.

## Code conventions

- `dart format` is the source of truth for formatting — never hand-format.
- Prefer `const` constructors wherever possible (perf + lint).
- No `print` in committed code — use a logger.
- Handle every `Future`; never leave an unawaited async call silently.
- Null-safety is non-negotiable — no `!` bang operator unless the invariant is proven
  and commented.

## Before calling work done

- `flutter analyze` is clean (zero warnings).
- `dart format --set-exit-if-changed .` passes.
- Relevant tests run and pass.

---

See `core/guidelines/flutter.md` in the `dev-ai-plugins` repo for the provider-neutral
source of these rules (the version reused by non-Claude tooling).
