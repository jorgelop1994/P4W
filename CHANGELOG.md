# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned
- **Update notifications** — the app will notice when a newer release exists and say so, without a server of
  its own: GitHub Releases for the binaries, an appcast for the feed, and no forced installs. Automatic
  replacement will use Sparkle rather than a hand-written updater, because verifying signatures and
  replacing a running binary atomically is not something to write yourself.
- **Code comments in English.** The UI stays in Spanish; the comments are being translated as the project
  goes public.

## [0.1.0] - 2026-09-25

First public release. Everything below is in it.

### Added

- **Native macOS app** (SwiftUI, no Electron, no web view) that is a front-end for the `pi` already
  installed on the machine: it shares `~/.pi/agent/`, so a conversation started in the terminal appears in
  the app and the other way around. No onboarding, no separate config, no separate account.
- **Chat** with streamed markdown — its own GFM tables and code blocks, thinking as a collapsible rail, tool
  calls as chips that expand into their output. Attachments are referenced by path and never copied.
- **Spaces and tabs**: spaces group conversations, each space holds tabs, tabs hold conversations.
  `⌘1…9`, `⌃Tab`, `⌘W`, and multi-key pinning that survives restarts.
- **Full-text search** over every message of every session: SQLite FTS5 with accent folding for Spanish and
  English, `snippet()` extraction and `bm25` ranking. Indexing is incremental — it looks before it reads.
- **Session management**: rename, fork, export to HTML, delete to Trash, all through Pi's own RPC commands.
- **Agent panel** listing every live `pi` process with its real memory footprint, ordered by who needs
  attention first, and never reaping an instance that is busy.
- **Pi settings view**, generated from Pi's own documentation rather than hand-written, so it cannot drift.
- **Topic clustering** of past sessions: local TF-IDF signatures and deterministic agglomerative clustering,
  no model involved (470 conversations in 315 ms). Naming the groups is the one thing a model is asked to do,
  and it is off by default.
- **The cat.** An 8-bit white cat that draws what Pi is doing — resting, thinking, writing, working, waiting
  for you, or trouble — in six configurable positions and three sizes. Every frame is a grid of characters
  with a closed palette, so the art is reviewable in a diff and verifiable: the self-check compares the
  exported PNG against the grid cell by cell. It starts no timer when its state has a single frame, freezes
  while you interact with it, and stops animating when the window is occluded.
- **App icon drawn from the same pixel grids**, and a Dock icon that follows Pi's state for when the window
  is behind something else.
- **Dependency reporting** in three levels — required (`pi`, Node, a configured and selected model),
  recommended (a browser, DeepSeek), optional (web access) — with a blocking panel for the first and a
  dismissible line for the rest. `P4W --check-deps` prints the same report without opening the app.
- **457 self-checks** runnable headlessly (`--self-check`), plus a 27-check suite for the process supervisor
  (`p4w-supervisor`).
- **Self-describing commands**: `--render-cat`, `--render-icon`, `--render-docs`, `--measure-layout`,
  `--check-deps`, `--open-biggest`.

### Notes

- **Universal binary** (arm64 + x86_64), minimum macOS 15.0, verified on both architectures.
- **The user interface is in Spanish.** The project was written for a Spanish-speaking household.
- **The app is not notarized**, so the first launch needs right-click → Open. See the README.
- **Never run on an Intel Mac.** The binary is universal and both architectures report `minos 15.0`, but
  verified is not tested.

### Measured

| | |
|---|---|
| `pi` lean (no extensions) | 122 MB RSS · 77 MB footprint · 0.25 s startup |
| `pi` full | 362 MB RSS · 325 MB footprint · 5.4 s startup |
| P4W idle | **57 MB footprint · 0.0% CPU** |
| Session index | ~470 sessions, 85k messages, 161 MB |
| Warm start | 30 ms |
| Topic clustering | 315 ms for 470 conversations |

[Unreleased]: https://github.com/jorgelop1994/P4W/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jorgelop1994/P4W/releases/tag/v0.1.0
