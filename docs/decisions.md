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
**Decision:** models, rendering, analysis and export live in `Packages/CueCore` (now `01_Project/Packages/CueCore`); the app target keeps the shell and views. Tests run with `swift test --package-path 01_Project/Packages/CueCore`.
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

## 2026-11-27 · Directions folder structure

**Context:** the Xcode project, sources and Directions docs all sat at the repository root, unlike the standard layout (`13_folder-structure.md`).
**Decision:** move the Xcode project, `project.yml`, `Info.plist`, `Sources`, `Resources`, `Scripts` and `Packages/CueCore` into `01_Project/`, and the state, plan, tasks, decisions, sessions and specs into `docs/`. The repository stays at the project root.
**Consequences:** the house-package paths (`../../zPackages` in `project.yml`, `../../../../zPackages` in the `CueCore` manifest) now resolve to `1-macOS/zPackages` beside the project. Commands use `01_Project/Packages/CueCore` and `cd 01_Project && xcodegen generate`. Agent worktrees need an ignored `.claude/worktrees/zPackages` symlink instead of `.claude/zPackages`. Older session logs and execution evidence keep their original paths.

## 2026-11-28 · Close-up centred to both ends

**Context:** the close-up window held still for the first and last half-window, so the playhead walked to the panel edge at the start and end of every cue. The operator wants it centred throughout.
**Decision:** `CueAppearance.centerAtStart` and `centerAtEnd` (both on by default, also for saved appearances without the keys) let the window run past the track; the space beyond it is drawn empty, and the full-track box and the tick labels stay inside the track. Two checkboxes under Appearance → Waveform. `CuePicture.closeUp(frame:total:zoom:)` keeps build 10's clamped window when called without the flags.
**Consequences:** exports change in the first and last half-window of the close-up. The render baselines pin build 10's look through the test-only `CueAppearance.build10` (both flags off); `CenteredCloseUpTests` covers the centred default.

## 2026-11-28 · Solid toolbar band with centred actions

**Context:** on the macOS 27 SDK the panes show through the toolbar, so the queue and inspector backgrounds and the split dividers ran up into it (build 12).
**Decision:** as in Penumbra, `.toolbarBackground(Theme.secondaryBackground)` with `.visible`, and every group's shared glass background hidden. Layout changed from U1: the queue toggle stays at the left edge and the inspector toggle at the right edge; Add Audio, the format readout, Start Queue and Export Selected sit together in the centre (`.principal`). Approved by the operator.
**Consequences:** one solid band across the window whatever panes are shown.

## 2026-11-28 · Dim the played audio in the close-up

**Context:** the close-up showed the played audio in full colour and the upcoming audio dimmed. The operator wants the opposite: what is coming up is what matters on air.
**Decision:** `CueAppearance.dimPlayedCloseUp` (on by default, also for saved appearances without the key) swaps the two sides of the close-up cursor, the end-warning red included: upcoming in full colour or full red, played dimmed or dim red. The full track keeps played = bright. Checkbox "Dim played audio in close-up" under the centring checkboxes, disabled with zoom off. Chosen by the operator over a plain swap or an off-by-default toggle.
**Consequences:** exports change in the close-up. The render baselines pin build 10's look through `CueAppearance.build10` (now with this flag off); `DimPlayedCloseUpTests` covers the new default and the red swap.

## 2026-11-28 · End line on the frame grid

**Context:** on build 14 the operator saw the playhead stop a few pixels past the yellow End line at the last frame. The End marker is the detected music end, drawn at its exact time; the clip is rounded up to whole frames and padded with silence, so the last frame ends up to one frame after the music. The Music end countdown already rounds the music end up to a whole frame, so the line and the clock's zero could also sit up to a frame apart.
**Alternatives:** leave the line exact (sample-accurate, as radio playout and Pro Tools keep markers); round to the nearest frame; round down to the last audible frame.
**Decision:** draw the End line, and hit-test it, at `ClipTimeline.musicEndLineFrame`: the music end rounded up to a whole frame on the 25 base (`framesCovering`, shared with `targetClockFrames`), clamped to the clip. The marker keeps its exact seconds; dragging still sets an exact time. Fade stays exact. Research: EVS and CasparCG out points name the last frame played, picture editors put markers on whole frames, and lines that nearly align read as mistakes.
**Consequences:** the line, the playhead and 00:00:00 meet on the same frame, at the file end and at a Music end countdown. A flat stretch of under one frame can show between the waveform's last loud audio and the line. Render baselines are unchanged.

## 2026-11-28 · Apply to All copies every shared setting; queue rows show settings

**Context:** Apply to All sat at the bottom of the Job tab but also copied the Appearance tab, and it copied only the look and the preset: Normalise, audio tracks and the rest stayed behind. The queue gave no sign of what had been applied, and every row carried a "Pending" word and a Cancel or Retry text button.
**Decision:** Apply to All (`CueJob.adoptSharedSettings`) copies look, title position, preset, audio tracks, Normalise, start timecode, filename pattern, fade in, fade out and pre-roll; title text, trim in and out and the music markers stay per track (operator's choice, title position included). The button and its note sit in a footer under both inspector tabs. A Pending row's second line shows its settings ("AVC-I 100 1080i50 · 2 mono · −23 LUFS"); other states keep their word. A blue tick marks rows with the selected job's shared settings (`sharesSettings`). Cancel, Retry and Show in Finder are one small icon per row, shown on hover or selection; rows are 46 pt, plus a line for Paused and Failed.
**Consequences:** a fresh queue with default settings shows ticks on every row, which is accurate. The ticks follow the selection. The hidden icon is reachable by VoiceOver through the row's custom action.

## 2026-11-28 · Apply to All reaches Cancelled, Failed and Paused jobs

**Context:** build 15 screenshots: with jobs 1 and 3 Cancelled, Apply to All from either skipped the other, so they never matched. The spec limited it to Pending jobs, though its aim was only to protect Done jobs.
**Decision:** Apply to All changes every other job except Done ones (their file is written) and the running one (`QueueManager.takesApplyToAll`). Each keeps its status; as with an edit, a job whose name-relevant settings change chooses its file name again (`outputPath` cleared). Supersedes the "pending only" line of spec acceptance criterion for Apply to All.
**Consequences:** a Cancelled or Failed job picked up by Retry exports with the shared settings. Footer and status text now say "other jobs".

## 2026-11-28 · Picture order follows the Appearance panes; title gets its own band

**Context:** the only layout choice was clocks below or above, and the title floated over the other elements (build 15: over the Full track header, the duration and the close-up time labels). The operator asked for swappable positions with up/down adjustment per pane.
**Alternatives:** up and down arrow buttons for reordering; a title that keeps free drag; Elapsed and Remaining as two panes; a nudge that pushes neighbours or allows overlap; a table view for the panes.
**Decision:** spec [appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md), approved by the operator. The Appearance tab becomes one collapsible pane per picture element (Title, Full track, Close-up, Clocks) above fixed End warning and Overlay safe zones panes. Pane order is the picture's top-to-bottom order, changed by dragging a grip or by Move Up and Move Down. Each movable pane has an Offset stepper that moves only its element and stops 12 pixels from a neighbour or at a safe zone. The title sits in its own band with Left, Center or Right alignment; the nine anchors and the free drag go. One Clocks pane, with a control for which clock is left. The settings live in `CueAppearance`; the sidebar stays an AppKit `NSStackView`.
**Consequences:** `ClockPosition` and the job's `labelX`/`labelY` become migration inputs. The default order must reproduce build 17's pixels. Jobs with a floating title change picture on load, on purpose, and the five `customTitle` render baselines are re-recorded. An empty title keeps its band, a moved pane keeps its Offset, and the left clock is chosen with a two-segment control.

## 2026-11-28 · Plan choices for the Appearance panes

**Context:** planning the approved spec [appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md) turned up four points its technical notes did not settle or got wrong.
**Alternatives:** a `NumberFormatter` with a "+" prefix and " px" suffix for the Offset field (it rejects a typed "12" and then holds the focus); storing only the edited pane's Offset; an `NSButton` subclass for the grip; replacing the batch-round plan file.
**Decision:** (1) The Offset field uses its own `format` and `parse` functions in `CueCore` behind a small `Formatter`. (2) An Offset edit stores the offsets in use of all four panes, so a pane whose stored offset was being limited cannot move when its neighbour is nudged; reordering, clock sizes and safe zones never rewrite stored offsets. (3) The grip is a plain view with its own mouse handling, because macOS 27 routes control clicks through gesture recognizers that a tracking loop bypasses. (4) The work has its own plan file, [IMPLEMENTATION_PLAN-appearance-panes.md](IMPLEMENTATION_PLAN-appearance-panes.md), with `P`-prefixed task IDs, on a `feature/appearance-panes` branch; the batch-round plan stays open on gates X2 to X4.
**Consequences:** the old title and clock-position fields stay compilable until the app stops using them, then go in one task (P3.2). Pixel hashes are per macOS version, so the other Mac re-records its own table (gate PX3); a geometry fixture of build 17's layout covers both Macs.
