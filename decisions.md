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

## 2026-11-27 · Retry reuses the name; Done jobs can be re-exported

**Context:** the Atlas pass showed Retry naming a cancelled job's output `… - Cue 2.mxf` although the cancelled attempt wrote nothing, and Export Selected only beeped on a Done job.
**Alternatives:** always pick a fresh name on Retry; forbid re-export.
**Decision (operator):** Retry reuses the previous name when that file does not exist. Export Selected re-exports a Done job under a new, non-colliding name.
**Consequences:** plan task 5.2. An existing output file is never overwritten.

## 2026-11-27 · FFmpeg colour tags through `setparams`

**Context:** FFmpeg 8.1 ignored `-color_primaries` and `-color_trc` for libx264 AVC-Intra output, so files read `bt709/unknown/unknown`.
**Decision:** the AVC-Intra filter chain adds `setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709`. MPEG-2 keeps build 10's arguments.
**Consequences:** AVC-Intra files report all three tags as BT.709; MPEG-2 output stays identical to build 10.

## 2026-11-27 · Appearance defaults and copy scope

Jobs in a batch can share a look while keeping their own preset, title, timing and output reservation. Both inspector tabs now copy appearance to the other Pending jobs. The separate Job action can also copy the preset and releases a reservation only when the preset changes. Each submission captures the current saved default for all tracks in that submission. The operator uses Save as Default to change the starting look for later imports.

## 2026-11-27 · Clock clearance and end zoom

Rehearsal frames showed unused space above the clocks while the waveforms lost height. With clocks below, the layout now reduces that gap to its floor first. The operator's EVS output check still determines the final safe-zone percentages. End zoom has its own Off, 2, 3 and 5-second values. Keeping these separate from the starting zoom preserves the existing close-up choices. [Appearance and playhead plan](specs/cue-appearance-and-playhead-plan.md)
