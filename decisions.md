# Decisions

## 2026-11-27 · No BBC bmx for EVS output

**Context:** EVS ingest of FFmpeg-made MXF was uncertain. P2toMXF bundles BBC bmx (`bmxtranswrap -t op1a`).
**Alternatives:** rewrap every export with bmx; use FFmpeg only.
**Decision:** use FFmpeg only. The operator's FFmpeg-only AVC-Intra script already ingests on EVS. A local test showed FFmpeg 8.1 writes the RP2027 AVC-Intra 100 1080i label and a single body partition, the one EVS-specific requirement found.
**Consequences:** no extra binaries, dylibs or signing work. Revisit if the EVS ingest test of the 1080i50 preset fails, or for 1080p50, which FFmpeg mislabels.

## 2026-11-27 · Adopt the App Shell Standard with the batch queue

**Context:** the window is plain AppKit (NSStackView, rounded buttons). A queue needs a sidebar, and the standard requires migration.
**Alternatives:** an AppKit drawer; a separate queue window.
**Decision:** a SwiftUI shell using AppShellKit: queue | monitor | inspector in an autosaved HSplitView, flat toolbar, Theme. `MonitorView` stays AppKit inside `NSViewRepresentable`.
**Consequences:** the build 8 Appearance sidebar moves into the inspector. Exact control placement follows the UI changes protocol during planning. Spec: [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md).

## 2026-11-27 · `CueCore` local package for headless tests

**Context:** any `xcodebuild test` is app-hosted and launches Waveform Cue on the operator's desktop.
**Alternatives:** app-hosted XCTest; no automated tests.
**Decision:** models, rendering, analysis and export live in `Packages/CueCore`; the app target keeps the shell and views. Tests run with `swift test --package-path Packages/CueCore`.
**Consequences:** the API the app uses is `public`. Render baselines are SHA-256 hashes pinned to this macOS release.

## 2026-11-27 · Clock base stays 25

**Context:** 1080i50 and 1080p50 render 50 images per second.
**Decision:** `AudioTrack.fps` (25) remains the display and clock base. Render and encode rates come from `VideoStandard`.
**Consequences:** clocks read the same on every preset; 50 Hz positions are fields between 25 Hz frames.

## 2026-11-27 · Appearance sidebar stays AppKit

**Context:** the shell moves to SwiftUI, and raw SwiftUI controls are not allowed outside the toolbar.
**Decision:** `CueAppearanceSidebar` is hosted in the inspector through `NSViewRepresentable`, unchanged.
**Consequences:** no rewrite of a working, already-compliant control panel.
