# Implementation Plan

> **Persists across sessions.** Execute using the shared `commands/execute.md` procedure.
> Repair scheduling errors while preserving task IDs, completed evidence and approved scope.
> Task state/evidence is authoritative here; TASKS links here and holds backlog/inbox.
> Follow the master's `reference/task-state.md` for legacy reconciliation and archival.

**Progress:** 2/24; external acceptance: U1, X1, X2, X3, X4 open (G1 passed 2026-11-27).
**Task states:** unchecked = pending / implemented-unverified / blocked (name gate);
checked = complete with required evidence. Task identity includes this plan path plus ID.

## Goal

Turn Waveform Cue (build 10, single track, MPEG-2 only) into a queue-based App Shell app that exports AVC-Intra 100 cue clips for EVS, with music-end markers, loudness, trim, pre-roll and overlay safe zones.

**Journey (spec → User Flow):** drop a folder of tracks on the queue sidebar → select a job, adjust text, markers, preset; optionally Apply to All → Start Queue → each row reads Done with Show in Finder, and each `.mxf` carries the chosen codec, field layout, track count and start timecode, with the red countdown peaking at the music end.

## Acceptance Criteria

The spec's Given/When/Then criteria are authoritative and are not copied here. Each task names the sections it satisfies.

- [ ] A. App Shell migration (5 criteria) — tasks 0.2, 1.7, 6.3
- [ ] B. Batch queue (8) — 1.6, 2.3, 3.3
- [ ] C. Export presets (8) — 1.1, 3.1, 4.1
- [ ] D. Music-end detection (5) — 1.2, 2.2, 3.2, 4.1
- [ ] E. Loudness, trim and pre-roll (4) — 1.3, 1.5, 2.2, 4.1, 4.3, 5.1
- [ ] F. Safe zones (7) — 1.4, 2.1, 3.2, 4.2
- [ ] Edge cases (4) and error states (3) — 3.1, 3.3, 5.1
- [ ] Performance: a 3-minute AVC-I 100 25 cue exports in under 3 minutes; at most two decoded CAFs exist at once — 0.2 (baseline), 3.1, 3.3, 6.1

## Specs

- `specs/batch-presets-cue-tools.md` — the whole round (sections A–F, edge cases, error states)

---

## Planning findings (2026-11-27)

Facts established while planning that change or sharpen the spec's technical notes. Sources: local runs on the bundled FFmpeg 8.1, FFmpeg n8.1 source (`mxfenc.c`, `libx264.c`, `timecode.c`), x264 `encoder.c`, the EVS XT3 14.00 configuration manual, EBU R 128, and the Directions master.

**Encoder**
- Interlaced chain (verified): input `-f rawvideo -pix_fmt bgra -s 1920x1080 -framerate 50 -i pipe:0`, filter `scale=out_color_matrix=bt709:out_range=tv,format=yuv422p10le,tinterlace=interleave_top,setfield=tff`, plus `-flags +ildct+ilme`. No output `-r` is needed; the MXF comes out at 25 fps with `field_order=tt`.
- `-flags +ildct+ilme` is mandatory. Without it the file is silently progressive.
- `-top 1` is deprecated in 8.1. Drop it; `setfield=tff` does the job. (The spec lists `-top 1`.)
- `-avcintra-class 100` forces its own GOP, bitrate and slices. Do not pass `-b:v`, `-g` or `-preset`.
- The MXF muxer picks the AVC-I label from the first packet's size and the interlaced flag only. 1080p50 and 1080p25 share a frame size, so 1080p50 always gets the 25p label. FFmpeg master has no fix and no 50p entry. 1080p50 stays Experimental.
- The EVS XT3 manual lists AVC-Intra 100 at 1080p 50 Hz, so the format itself is plausible on the server; only the label is in doubt.
- Mono tracks (verified with 8): one graph `[1:a]aresample=48000,apad,atrim=end_sample=N,asplit=K`, then `pan=mono|c0=c0`, `pan=mono|c0=c1`, and `pan=mono|c0=0*c0` for silent tracks. Every track gets an identical sample count. This replaces the spec's `channelsplit` plus `anullsrc` idea, which needs separate length trimming.
- The muxer accepts a stereo stream without complaint, so mono-ness must be asserted in tests.
- Timecode: `-timecode` is 25-based for 1080i50 and 1080p25 and 0–49 for 1080p50. A start before zero is written as `23:59:55:00` and accepted.
- Colour: keep the explicit `scale=out_color_matrix=bt709:out_range=tv` and the three tag options. The bitmap context must stay sRGB.
- Loudness: `-nostats -i <caf> -af ebur128=peak=true:framelog=quiet -f null -`. Parse the text after the last `Summary:` for `I:`, `LRA:` and `Peak:`; handle `-inf`.
- EBU R 128 current values: −23.0 LUFS, ±1.0 LU where the target is not practical, −1 dBTP. The spec's badge rule matches.
- FFmpeg is not the bottleneck: 250 piped 1080p frames encode in 1.3–1.8 s. Core Graphics rendering sets the export speed.

**House packages and references**
- `zPackages` is one Swift package (tools 6.2, macOS 14) with products `AppShellKit` and `ProcessKit`. The path from this folder is `../../zPackages`. It pulls `swift-subprocess` from the network on first resolve.
- No existing app consumes AppShellKit through XcodeGen, so task 0.2 is the first to prove that wiring.
- AppShellKit offers `FlatToolbarButtonStyle`, `PaneToggleButton`, `View.autosaveSplitView(named:)`, `AppAppearancePreference` with `View.appAppearance(_:)` and `AppAppearanceCommands`, and `Theme`. It has no window helper; the app sets `.windowStyle(.hiddenTitleBar)` and `.toolbarRole(.editor)` itself.
- ProcessKit cannot write to a child's stdin, and a cancelled stream ends without an exit event. The frame pipe stays on `Process` and `Pipe`. ProcessKit is used only for the loudness pass.
- Conjoyn and Penumbra are not on this Mac. Read-only copies of the reference files are in the planning session's scratchpad and on GitHub (`Xpycode/Conjoyn`, `Xpycode/Penumbra`). Conjoyn's queue uses `ObservableObject`; this plan uses `@Observable` per the spec.
- UI rule: SwiftUI `Button`, `Toggle`, `Picker`, `Slider`, `Stepper`, `ColorPicker`, `TextField` are forbidden outside `.toolbar`. Controls are AppKit wrappers in `Sources/App/Views/AppKit/` with `@MainActor` coordinators.
- Testing rule: any `xcodebuild test` is app-hosted and launches on the operator's desktop, which is excluded. Tests therefore live in a local Swift package and run with `swift test`.

**Decisions taken in this plan** (log to `decisions.md` in task 0.2)
1. **`CueCore` local package.** Models, rendering, analysis and export move to `Packages/CueCore` so they test headlessly. The app target keeps only the shell and views. Cost: `public` on the API the app uses.
2. **Clock base stays 25.** `AudioTrack.fps` remains the display base. Render and encode rates come from `VideoStandard`.
3. **Existing Appearance sidebar stays AppKit** and is hosted in the inspector through `NSViewRepresentable`. It already meets the control rule.

---

## Proposed control placement (gate U1 — awaiting confirmation)

Per the UI changes protocol. Similar existing controls: `CueAppearanceSidebar` (AppKit grid of labelled pop-ups, colour wells and checkboxes, 318 pt, changes flow through its `changed` closure to `MonitorView.cueAppearance` and `CueAppearance.save()`), and the transport row and footer in `AppController.makeWindow()`.

```
┌ toolbar: [Show Queue] [Add]            <job name · format readout>   [Start/Stop Queue] [Export Selected] [Show Inspector] ┐
├ Queue (220–360 pt) ─┬ Monitor ───────────────────────────────┬ Inspector (318 pt min) ─────────────┤
│ row: name           │ MonitorView (AppKit, unchanged)         │ [ Job | Appearance ] segmented       │
│      status · %     │                                         │                                      │
│      Cancel / Retry │                                         │ Job tab:                             │
│      Show in Finder │                                         │  Export: Preset, Audio tracks,       │
│ …                   │                                         │   Start timecode, Filename, note     │
│                     ├─────────────────────────────────────────│  Markers: Music end, Fade start,     │
│ footer: Destination │ [Play] ──────── seek slider ─────────── │   Reset                              │
│  Beside source ▾    │                                         │  Loudness: I / TP / LRA, Normalise   │
│                     │                                         │  Trim: In, Out, Fade in, Fade out    │
│                     │                                         │  Pre-roll                            │
│                     │                                         │  [Apply to All]                      │
│                     │                                         │ Appearance tab: today's sidebar,     │
│                     │                                         │  plus Countdown target, Clock        │
│                     │                                         │  position, Overlay safe zones, guides│
├ bottom bar: status text, or overall progress with percentage while the queue runs ───────────────────┤
```

- Window: `HSplitView` with `.autosaveSplitView(named: "WaveformCue.Main")`. Queue and inspector visibility are `@AppStorage` bools toggled by `PaneToggleButton`.
- Bottom bar: `.safeAreaInset(edge: .bottom)`, replacing today's footer (cookbook 12).
- Menus: File gains Add Audio… (Command-O), Export Selected (Command-E), Export Selected to Folder…, Start Queue (Command-Return). View gains Appearance (Light, Dark, Match System) and the two pane toggles.
- Keys in the monitor: Space, Left Arrow, Right Arrow as today; I and O set in and out points.
- Files: `Sources/App/WaveformCueApp.swift`, `Views/MainWindow.swift`, `Views/QueueSidebar.swift`, `Views/MonitorPane.swift`, `Views/InspectorPane.swift`, `Views/JobInspector.swift`, `Views/AppKit/*.swift`.

Until U1 is confirmed, 1.7 may build the three-pane shell with single-track parity (no new controls). Tasks 2.3, 4.1, 4.2 and 5.1 add controls and wait for U1.

---

## Execution schedule and ownership

- **Execution scope/limits:** 2026-11-27, "execute next steps": continue through ready waves. Gate U1 still blocks 2.3, 4.1, 4.2, 5.1. Pushes and app control keep their own authorization.
- **Coordinator-owned files/resources:** `project.yml`, `WaveformCue.xcodeproj` (regenerated with `xcodegen generate` after each wave), `Info.plist`, `Packages/CueCore/Package.swift`, `Sources/CueCore/CueTypes.swift` after 0.3, `Scripts/`, Git, `IMPLEMENTATION_PLAN.md`, `PROJECT_STATE.md`, `TASKS.md`, `decisions.md`, `README.md`, `04_Exports/`, and the Atlas helper (one session at a time).
- **Shared build resources:** parallel tasks run `swift test` with their own `--scratch-path` (the task's scratch folder) and a `--filter` for their own test class. Only the coordinator runs the full suite and `xcodebuild build`, using a `-derivedDataPath` outside the project.
- **Interfaces to establish before dispatch:** the shared value types in 0.3, and the frozen signatures named in each task's Interface line.
- **Test fixtures:** synthetic signals generated in tests (sine, fade plus silent tail, click, silence). Integration tests find FFmpeg through the `FFMPEG_EXECUTABLE` environment variable and skip, visibly, when it is unset. On this Mac: `/Applications/Magpie.app/Contents/Resources/ffmpeg`.
- **Effects class of the backpressure commands:** `swift test` is headless and writes only to its scratch path and a per-test temporary folder. `xcodebuild build` launches nothing. Atlas runs happen in the hidden helper only.

Dependency graph (no cycles):

```
0.1 → 0.2 → 0.3 → 1.1 … 1.7
1.4 → 2.1          1.2, 1.5 → 2.2          1.6, 1.7, U1 → 2.3
1.1, 1.3, 2.1, 2.2 → 3.1     2.1, 2.2 → 3.2     2.2, 2.3 → 3.3
3.1, 3.3, U1 → 4.1     3.2, U1 → 4.2     1.3, 3.1, 3.2 → 4.3
4.1, 4.3 → 5.1     all → 6.x
```

## Tasks

### Wave 0 (serial foundations — coordinator; each step changes what the next builds on)

- [x] **0.1**: Create the Git repository and push it to origin
  - Depends on / external gates: **G1**
  - Owns: `.git`, `.gitignore`
  - Detail: this is a re-founding, not a bootstrap. No repository exists on GitHub or on any Mac; all work so far was done on M4 Pro. `git init -b main`, check `.gitignore` (keep `04_Exports/` ignored, add `.build/`, `DerivedData/`, `.swiftpm/`, `*.sync-conflict-*`; confirm `IMPLEMENTATION_PLAN.md` is not ignored), verify identity, snapshot-commit with the history loss stated in the message, `gh repo create … --private --source . --push`, then add a `Repo/git:` line to the project `CLAUDE.md`.
  - Success: `git status -sb` shows `main...origin/main` with nothing ahead; build 10 sources are the first commit.
  - Backpressure: `git fetch && git status -sb | head -1`

- [x] **0.2**: Extract `CueCore`, add the package dependencies and capture the build 10 baseline
  - Depends on: 0.1
  - Owns: `Packages/CueCore/**` (new), `project.yml`, `Info.plist`, `decisions.md`
  - Detail:
    1. Move `AudioTrack`, `PreparedAudio`, `CueAppearance`, `CuePicture`, `MXFExport` into `Packages/CueCore/Sources/CueCore/`, adding `public` where the app needs it. `AppController`, `MonitorView`, `CueAppearanceSidebar`, `main` stay in `Sources/` and `import CueCore`. No behaviour change.
    2. `project.yml`: add local packages `CueCore` (path `Packages/CueCore`) and `zPackages` (path `../../zPackages`, products `AppShellKit`, `ProcessKit`); bump the build number to 11. Add `UIDesignRequiresCompatibility` true to `Info.plist`.
    3. Baseline tests in `CueCoreTests/BaselineTests.swift`: SHA-256 of `CuePicture.draw` output at 1920 × 1080 for a synthetic track at fixed frames (first, middle, 5 s left, 1 s left, last) under default appearance, zoom Off, and a custom title position; `AudioTrack.clock`; `frames` rounding; `CountdownWarning.fraction`; `closeUp` window. These hashes are the "build 6 behaviour unchanged" proof for every later render task.
    4. Benchmark test (skipped unless `CUE_BENCH=1`): frames per second of `CuePicture.draw` at 1920 × 1080. Record the figure under Operational Learnings.
  - Interface: module `CueCore`; `CuePicture.draw(in:rect:track:path:frame:label:appearance:heldRange:)` unchanged.
  - Success: the app builds and behaves as build 10; baseline tests pass; the benchmark number is recorded.
  - Backpressure: `swift test --package-path Packages/CueCore` and `xcodegen generate && xcodebuild -scheme WaveformCue -configuration Debug -derivedDataPath <scratch>/dd build`
  - Evidence (2026-11-27): 7 baseline tests pass in debug and release (benchmark skipped without `CUE_BENCH`); 20 render hashes pinned (4 appearances × 5 frames, including a countdown-warning case); `xcodebuild build` succeeded with `CueCore`, `AppShellKit` and `ProcessKit` linked. Behaviour unchanged by construction (files moved, only `public` and a `CueLabel` init added); no launch was made.

- [ ] **0.3**: Shared value types
  - Depends on: 0.2
  - Owns: `Packages/CueCore/Sources/CueCore/CueTypes.swift`, `CueTypesTests.swift`
  - Detail: small `Codable, Equatable, Sendable` types with tolerant decoding (cookbook 122) that several Wave 1 tasks exchange: `AudioLayout` (2, 4, 8 mono), `MusicMarkers` (detected and edited music end and fade start, in seconds; `noMusic`), `LoudnessMeasurement` (integrated, true peak, range), `TrimSettings` (in, out, fade in, fade out, pre-roll seconds), `SafeZones` (preset none / evsOSD / custom, four percentages 0–30), `ClockPosition`, `CountdownTarget` (file end, music end), `PresetID` (string).
  - Interface: these names and fields are frozen for Waves 1–5; changes go through the coordinator.
  - Success: round-trip and missing-key decoding tests pass.
  - Backpressure: `swift test --package-path Packages/CueCore --filter CueTypesTests`

### Wave 1 (parallel — seven tasks, all new files, disjoint ownership)

- [ ] **1.1**: Presets, argument builder, timecode and filename template (spec C)
  - Depends on / external gates: 0.3; none
  - Owns: `VideoStandard.swift`, `ExportPreset.swift`, `Timecode.swift`, `FilenameTemplate.swift` and their tests
  - Detail: `VideoStandard` (size, encode rate, interlaced, field order, `samplesPerFrame`). Four built-in presets with fixed IDs. `ffmpegArguments(audioPath:outputFrames:layout:timecode:gainDB:audioFilters:output:) -> [String]` following Planning findings (no `-top`, `pan`-based mono graph, explicit colour). `Timecode` parses and formats HH:MM:SS:FF at 25 and 50, and subtracts a pre-roll with wrap past midnight. `FilenameTemplate` expands `{name}`, `{preset}`, `{date}`, strips path separators and resolves collisions with ` 2`, ` 3`. Bitrate estimate per preset for disk preflight.
  - Interface: `ExportPreset.builtIn`, `ExportPreset.preset(for: PresetID)`, the argument builder, `Timecode`, `FilenameTemplate.resolve(…, exists:)`, `ExportPreset.formatReadout`.
  - Success: exact-array argument tests for each preset and each layout; timecode edge cases (invalid frames, wrap); template collision tests; MPEG-2 arguments equal build 10's except the audio graph.
  - Backpressure: `swift test --package-path Packages/CueCore --filter 'ExportPresetTests|TimecodeTests|FilenameTemplateTests'`

- [ ] **1.2**: Music-end detector (spec D, analysis only)
  - Depends on: 0.3
  - Owns: `MusicEndDetector.swift`, `MusicEndDetectorTests.swift`
  - Detail: a pure function over absolute 5 ms bucket peaks: music end is the end of the last run of at least 50 ms above −60 dBFS; fade start uses peak − 40 dB; all-quiet returns `noMusic`; no silent tail returns the file end.
  - Interface: `MusicEndDetector.detect(peaks:bucketSeconds:duration:) -> MusicMarkers`
  - Success: synthetic cases pass: fade plus tail, isolated click in the tail ignored, no tail, all silence, very short track.
  - Backpressure: `swift test --package-path Packages/CueCore --filter MusicEndDetectorTests`

- [ ] **1.3**: `ClipTimeline` (spec E mapping)
  - Depends on: 0.3
  - Owns: `ClipTimeline.swift`, `ClipTimelineTests.swift`
  - Detail: maps output position (at the encode rate, including field positions) to slate or source time; exposes output frame count, elapsed and remaining on the 25 base, countdown frames to file end or music end (holding at zero after the marker), marker positions in the trimmed range, whole-frame padding (1920 or 960 samples), and the audio filter chain (`atrim`, `afade`, `adelay`, `apad`, `atrim=end_sample`). With no trim and no pre-roll at 25p it reproduces today's `frames` and clocks exactly.
  - Interface: `ClipTimeline(duration:trim:markers:target:standard:)`, `outputFrames`, `position(at:)`, `clocks(at:)`, `audioFilters()`, `validate()` ("Trim range too short" under one second).
  - Success: identity case matches the baseline; pre-roll, trim, 50 Hz and short-track clamping tests pass.
  - Backpressure: `swift test --package-path Packages/CueCore --filter ClipTimelineTests`

- [ ] **1.4**: `CueLayout` computation (spec F, geometry only)
  - Depends on: 0.3
  - Owns: `CueLayout.swift`, `CueLayoutTests.swift`
  - Detail: computes every rectangle and size `CuePicture` hard-codes today (overview, detail, clock baseline and sizes, labels, title travel area, margins) from zoom, clock sizes, clock position and safe zones. Give-way order: waveform heights, gaps, clock size (not below Small), title (not below 34 pt), then `fits == false`. EVS OSD preset is provisional: top 10 %, bottom 20 % (see X1).
  - Interface: `CueLayout(appearance inputs…)` with `overview`, `detail`, `clockBaseline`, `elapsedSize`, `remainingSize`, `titleArea`, `usable`, `reserved` bands, `fits`.
  - Success: with safe zones None and clocks below, every value equals today's constants (742/100, 361/265, baseline 100, 96 px margins, 55 px title inset); with reserves, no element rectangle intersects a reserved band; the give-way order and the does-not-fit case are tested.
  - Backpressure: `swift test --package-path Packages/CueCore --filter CueLayoutTests`

- [ ] **1.5**: Loudness parsing and gain rule (spec E, pure part)
  - Depends on: 0.3
  - Owns: `Loudness.swift`, `LoudnessTests.swift`
  - Detail: parse the `ebur128` summary (last `Summary:` block, `-inf` handled); badge rule (outside −23 ±1 LUFS or above −1 dBTP); gain = min(−23 − I, −1 − TP) with the achieved loudness reported.
  - Interface: `Loudness.parse(stderr:) -> LoudnessMeasurement?`, `Loudness.normalisation(for:) -> (gainDB, achievedLUFS, limitedByPeak)`, `Loudness.arguments(input:) -> [String]`
  - Success: tests on the captured 8.1 summary, a silent summary, a peak-limited case and garbage input.
  - Backpressure: `swift test --package-path Packages/CueCore --filter LoudnessTests`

- [ ] **1.6**: Queue core (spec B, logic only)
  - Depends on: 0.3
  - Owns: `Queue/CueJob.swift`, `Queue/QueueStore.swift`, `Queue/QueueManager.swift` and tests, all in `CueCore`
  - Detail: `JobStatus` (pending, preparing, exporting(progress), done(output), failed(reason, log), cancelled, paused). `CueJob` holds the source path, label and position, appearance snapshot, preset ID, layout, start timecode, template, trim, markers, loudness, peaks summary, with explicit coding keys so run state is not saved and tolerant per-job decoding. `QueueStore` saves atomically after every change; an unreadable file is copied to `queue-recovery-<UUID>.json` and writes are blocked if that copy fails. `QueueManager` (`@MainActor @Observable`): add, remove, select, Apply to All (appearance and preset, pending jobs only), serial loop, cancel current, stop queue, retry with a fresh name, restore (interrupted → pending, missing source → Failed "Source not found"), pause jobs sharing an unwritable folder, progress coalescing at about 10 Hz (cookbook 177), cancel the producer and wait for its end (cookbook 154). Work is injected through protocols so tests need no FFmpeg.
  - Interface: `protocol JobExporting { func export(_ job: CueJob, progress:) async throws -> URL }`, `protocol SleepPreventing`, `QueueManager(storageDirectory:exporter:sleep:fileExists:)`.
  - Success: state-transition, ordering, cancel, stop, retry, Apply to All, save-then-reload, corrupt-file recovery, legacy-fixture and pause tests pass.
  - Backpressure: `swift test --package-path Packages/CueCore --filter 'QueueManagerTests|QueueStoreTests|CueJobTests'`

- [ ] **1.7**: App Shell migration with single-track parity (spec A)
  - Depends on / external gates: 0.2; U1 only for anything beyond the parity layout
  - Owns: all of `Sources/` (now the app target): new `Sources/App/**`; deletes `AppController.swift` and `main.swift`; `MonitorView.swift` and `CueAppearanceSidebar.swift` are moved, not edited beyond what hosting needs
  - Detail: `@main` SwiftUI app; `WindowGroup` with `.windowStyle(.hiddenTitleBar)`, `.toolbarRole(.editor)`, `.appAppearance`, dark by default with `AppAppearanceCommands`; `HSplitView` queue placeholder | monitor | inspector with `.autosaveSplitView`; `PaneToggleButton`s and flat toolbar buttons; `MonitorRepresentable` and `AppearanceSidebarRepresentable` with `@MainActor` coordinators; an `EditorModel` (`@MainActor @Observable`) carrying what `AppController` did: load, playback timer, seek, step, scrub, label and position, export beside source or to folder, cancel, reveal, the quit and close guards, the key monitor (which must still ignore keys while a text field or the inspector has focus), and opening a file from Finder or the Dock. Bottom status bar. No raw SwiftUI controls outside the toolbar.
  - Interface: `EditorModel` API used by 2.3 (`load(url:)`, `track`, `label`, `appearance`, `frame`, `isExporting`); `MainWindow` slots for the queue sidebar and the Job tab.
  - Success: spec A criteria 1–5 with one track; baseline hashes unchanged; Atlas screenshots show the three panes, flat toolbar, pane toggles remembered across relaunch, and play, scrub, frame-step, title drag and export working.
  - Backpressure: `xcodebuild … build`; then the coordinator runs the Atlas parity pass on the fresh build.

### Wave 2 (parallel — three tasks; file sets are disjoint)

- [ ] **2.1**: Renderer and hit-testing read `CueLayout`
  - Depends on: 1.4
  - Owns: `CuePicture.swift`, `CueAppearance.swift` (in `CueCore`), `MonitorView.swift`, `RenderTests.swift`
  - Detail: `CueAppearance` gains `safeZones`, `clockPosition`, `countdownTarget`, `showGuides` with `decodeIfPresent` defaults that preserve saved build 10 appearances. `CuePicture.draw`, `caption`, `overviewRect` and `MonitorView` seek, scrub and title drag all take one `CueLayout`; the title's travel is clamped to the usable area. Add a draw entry point that takes a `ClipTimeline` position so 50 Hz field images can be rendered (the playhead and clocks move per field); the old `frame:` call forwards to it.
  - Interface: `CuePicture.draw(…, layout:, position:)`; `CueLayout` is computed once per appearance change and shared by preview and export.
  - Success: all 0.2 baseline hashes unchanged with safe zones None; a decoded-bitmap test shows only background colour inside each reserved band for several reserve settings; a click at a known picture point still seeks to the same frame (hit-test unit test on the mapping function).
  - Backpressure: `swift test --package-path Packages/CueCore --filter 'BaselineTests|RenderTests'`

- [ ] **2.2**: Analysis integration and decoded-audio lifetime
  - Depends on: 1.2, 1.5
  - Owns: `AudioTrack.swift`, `PreparedAudio.swift`, new `JobWorkspace.swift`, `LoudnessAnalyzer.swift`, tests
  - Detail: `AudioTrack.read` keeps the absolute peak and runs `MusicEndDetector` on the 5 ms buckets in the existing pass (no extra decode). `JobWorkspace` owns a job's temporary CAF: created on demand, deleted on release, with a registry the tests can count. `LoudnessAnalyzer` runs the `ebur128` pass in the background through ProcessKit and returns a `LoudnessMeasurement`; cancellable. A track can be rebuilt from stored peaks and markers without re-analysis.
  - Interface: `AudioTrack.read(_:encoder:)` stays source-compatible and gains `markers` and `absolutePeak`; `JobWorkspace.acquire(for:)` / `release`; `LoudnessAnalyzer.measure(_ url:encoder:) async throws`.
  - Success: unit tests on a generated WAV with a fade and a silent tail (needs FFmpeg; skipped with a notice otherwise); the workspace deletes its CAF on release; the loudness of a −23 LUFS reference tone is within 0.5 LU.
  - Backpressure: `FFMPEG_EXECUTABLE=… swift test --package-path Packages/CueCore --filter 'AudioTrackTests|JobWorkspaceTests|LoudnessAnalyzerTests'`

- [ ] **2.3**: Queue sidebar wired to the shell, exporting through the existing engine
  - Depends on / external gates: 1.6, 1.7; **U1**
  - Owns: `Sources/App/Views/QueueSidebar.swift`, `Sources/App/Queue/**` (including `LegacyExportAdapter.swift`), `Sources/App/EditorModel.swift`, toolbar and menu wiring in `MainWindow.swift`
  - Detail: the thin end-to-end slice for B. Drop files or a folder on the sidebar or the app icon (folder contents sorted by name, unsupported files skipped with one summary line, a decode failure added as Failed). Rows show status, percentage, Cancel, Retry, Show in Finder and a log disclosure. Selecting a job loads it into the monitor; the running job's settings are locked while other jobs stay editable. Start Queue, Stop Queue and Export Selected in the toolbar; overall progress in the bottom bar. The exporter is an adapter over today's `MXFExport.run` (MPEG-2).
  - Interface: `LegacyExportAdapter: JobExporting`, replaced by 3.1's adapter.
  - Success: in Atlas, 12 dropped files become 12 jobs in order, the queue exports them one by one, Cancel leaves no partial file, and editing one job changes only that job.
  - Backpressure: `xcodebuild … build`, the full `swift test`, then the Atlas pass.

### Wave 3 (parallel — three tasks)

- [ ] **3.1**: Preset-driven export engine (spec C; first AVC-Intra file from the app)
  - Depends on: 1.1, 1.3, 2.1, 2.2
  - Owns: `MXFExport.swift`, new `Sources/App/Queue/MXFJobExporter.swift` (replaces `LegacyExportAdapter.swift`), `ExportIntegrationTests.swift`, `DiskSpace.swift`
  - Detail: `MXFExport.run(snapshot:preset:timeline:encoder:destination:progress:)`. Frame count and render rate come from the timeline (50 images per second for 1080i50 and 1080p50). Arguments come from the preset builder, including layout, timecode and normalisation gain. Disk preflight before spawning (estimated video plus audio plus the CAF; message names the volume, free and required space). Keep the hidden temporary file and atomic move, `F_SETNOSIGPIPE`, one whole-frame write per frame, and the last 1,500 characters of the log on failure. Do not parallelise rendering unless the 0.2 benchmark shows a 3-minute cue would miss the 3-minute target; if it would, stop and replan with the measured numbers.
  - Interface: `MXFJobExporter: JobExporting`.
  - Success: integration tests export a 4-second signal with each preset and assert via `ffprobe` or `ffmpeg -i` parsing: codec and profile, 10-bit 4:2:2, 1920 × 1080, `field_order=tt` for 1080i50, the RP2027 label bytes (`…31 02` for 1080i50, `…31 04` for 1080p25), no body partition for AVC-I, Rec. 709 tags, N mono 24-bit 48 kHz tracks of identical length with tracks 3+ digitally silent, the start timecode, and whole-frame padding. A decoded frame equals the preview bitmap for the same settings within codec tolerance. Measured export rate recorded under Operational Learnings.
  - Backpressure: `FFMPEG_EXECUTABLE=… swift test --package-path Packages/CueCore --filter ExportIntegrationTests`

- [ ] **3.2**: Markers, countdown target, clock position and guides in the picture (spec D and F rendering)
  - Depends on: 2.1, 2.2
  - Owns: `CuePicture.swift`, `MonitorView.swift`, `RenderTests.swift` (additions), `CountdownTests.swift`
  - Detail: draw music-end and fade-start markers on both waveforms. With Countdown target Music end, the fade to red, the solid-red threshold and both waveform fades measure to the marker, and Remaining holds at 00:00:00 in red after it. Clocks move as a pair above or below the waveforms. Hatched safe-zone guides are drawn by `MonitorView` only, never by `CuePicture`. Markers can be dragged in the monitor.
  - Interface: `MonitorView.onMarkerChanged`; `CuePicture.draw` takes markers through the timeline.
  - Success: baseline hashes unchanged with target File end and no markers; frame tests at fade start, solid-red threshold, the marker and after it; a no-tail track renders identically for both targets; an export contains no guide pixels (bitmap test on `CuePicture` output with guides on).
  - Backpressure: `swift test --package-path Packages/CueCore --filter 'BaselineTests|RenderTests|CountdownTests'`

- [ ] **3.3**: Queue integration: persistence, lifetime and failure handling (spec B, edge cases, error states)
  - Depends on: 2.2, 2.3
  - Owns: `Sources/App/Queue/**` except the exporter adapters, `QueueSidebar.swift`, `Queue/QueueManager.swift` and its tests, `SleepAssertion.swift`
  - Detail: store at `~/Library/Application Support/Waveform Cue/queue.json`; restore on launch; `IOPMAssertionCreateWithName` for the whole batch; quit and close ask to stop the queue first; queue-wide destination override in the sidebar footer; jobs sharing an unwritable folder pause and the operator is asked for a new folder; workspaces acquired only for the selected job and the running job; stored peaks and markers mean a restored job needs no re-analysis until it is selected or run.
  - Interface: none new; consumes `JobWorkspace` and `QueueManager`.
  - Success: unit tests for the workspace cap (50 jobs, never more than two CAFs), restore rules and pause-on-unwritable; Atlas pass: quit with pending and done jobs, relaunch, queue restored; a missing source reads "Source not found".
  - Backpressure: full `swift test`, `xcodebuild … build`, then the Atlas pass.

### Wave 4 (parallel — three tasks)

- [ ] **4.1**: Job tab: export settings, markers, loudness, Apply to All (spec C, D, E controls)
  - Depends on / external gates: 3.1, 3.3; **U1**
  - Owns: `Sources/App/Views/JobInspector.swift`, `InspectorPane.swift`, `Sources/App/Views/AppKit/**`
  - Detail: AppKit-wrapped pop-up, text field, checkbox and button components. Preset picker with the format readout and the Experimental note for 1080p50; audio tracks; start timecode with validation; filename template; marker time fields with Reset; loudness readout with the badge and Normalise to −23 LUFS (shows achieved loudness when peak-limited); Apply to All; "No music detected" state.
  - Success: Atlas pass over each control; an exported file reflects the chosen preset, tracks, timecode and name; Apply to All never changes a Done job.
  - Backpressure: `xcodebuild … build`, full `swift test`, Atlas pass.

- [ ] **4.2**: Appearance tab additions (spec D and F controls)
  - Depends on / external gates: 3.2; **U1**
  - Owns: `CueAppearanceSidebar.swift`
  - Detail: Countdown target, Clock position, Overlay safe zones (None, EVS OSD, Custom with four 0–30 % steppers), Show safe-zone guides, and the "Safe zones leave too little room" message, which also disables export for that job. Settings persist with the appearance and are part of the job snapshot.
  - Success: Atlas pass: each control updates the preview at once; relaunch keeps the settings; the too-little-room case disables Export Selected.
  - Backpressure: `xcodebuild … build`, Atlas pass.

- [ ] **4.3**: Trim, fades and pre-roll through the timeline (spec E engine)
  - Depends on: 1.3, 3.1, 3.2
  - Owns: `CuePicture.swift` (slate drawing, trimmed overview), `MonitorView.swift` (in and out handles), `MXFExport.swift` (audio chain and pre-roll timecode), `TrimPreRollTests.swift`
  - Detail: preview and export both read the job's `ClipTimeline`. The slate shows title, music duration, loudness and "Starts in" over silent audio. Elapsed starts at zero on the first music frame. The embedded timecode puts the music start at the job's start timecode. Fades apply to audio only. Single-task ownership of three shared files is the reason this runs beside the UI tasks rather than beside 3.1 or 3.2.
  - Interface: `MonitorView.onTrimChanged`; `EditorModel` playback confined to the trimmed range (owned here only where it lives in `CueCore`; app wiring is 5.1).
  - Success: integration tests: clip length equals pre-roll plus trimmed range, rounded up to a whole frame; the first music frame's timecode equals the start timecode; audio is silent during the slate and the fade envelopes measure correctly; a track shorter than the pre-roll or the warning interval exports without a crash.
  - Backpressure: `FFMPEG_EXECUTABLE=… swift test --package-path Packages/CueCore --filter 'TrimPreRollTests|BaselineTests'`

### Wave 5 (single task — it edits the Job tab that 4.1 creates and consumes 4.3's engine)

- [ ] **5.1**: Trim, fade and pre-roll controls and keys
  - Depends on / external gates: 4.1, 4.3; **U1**
  - Owns: `JobInspector.swift`, `EditorModel.swift`, key handling in `MainWindow.swift`
  - Detail: In and Out fields, fade pop-ups (0, 0.5, 1, 2, 5 s), pre-roll pop-up (Off, 2, 3, 5, 10 s); I and O keys at the playhead; playback and scrubbing confined to the trimmed range; starting a job with under one second of trim is blocked with "Trim range too short".
  - Success: Atlas pass: set in and out by key and by drag, export, and the file covers only that range with the slate first.
  - Backpressure: `xcodebuild … build`, full `swift test`, Atlas pass.

### Wave 6 (verification and handoff)

- [ ] **6.1**: Full integration run and performance record
  - Depends on: 5.1
  - Owns: evidence in the Execution Log; `PerformanceTests.swift`
  - Success: the whole suite passes with FFmpeg present (no skipped integration tests); a 3-minute AVC-I 100 1080p25 and 1080i50 export each finish in under 3 minutes, times recorded; the 50-job CAF cap test passes.
  - Backpressure: `FFMPEG_EXECUTABLE=… CUE_BENCH=1 swift test --package-path Packages/CueCore` with zero failures and zero skips

- [ ] **6.2**: Acceptance pass in the Atlas helper
  - Depends on: 5.1
  - Owns: screenshots and notes linked from the Execution Log
  - Success: every spec criterion in A–F, the edge cases and the error states is marked verified, not verified, or externally gated, each with a screenshot or a decoded-file measurement. Fixtures are copied into the helper; no live project or operator file is used.
  - Backpressure: the criterion checklist in the session log, with no unexplained gaps

- [ ] **6.3**: Review
  - Depends on: 5.1
  - Owns: review report; findings return to the owning task
  - Success: `/shell-check` reports no violations; a code review of the diff since 0.1 has its confirmed findings fixed and the affected tests re-run.
  - Backpressure: shell-check output and the re-run test results

- [ ] **6.4**: Build 11 handoff and documentation
  - Depends on: 6.1, 6.2, 6.3
  - Owns: `README.md`, `decisions.md`, `PROJECT_STATE.md`, `TASKS.md`, `04_Exports/0.1-11/`
  - Success: Release build in `04_Exports/0.1-11` with digest and signature check per `reference/log/app-handoff.md`; README describes the queue, presets, markers, loudness, trim, pre-roll and safe zones; test files for X2 are prepared for the operator.
  - Backpressure: `xcodebuild -configuration Release … build`, `codesign --verify --deep --strict`

## External checks

- [x] **G1**: Confirm creating a GitHub repository for this project
  - Result (2026-11-27): confirmed as public, named Waveform Cue. GitHub names cannot contain spaces, so it is `Xpycode/Waveform-Cue`.
  - Gates: 0.1 and therefore every commit. Nothing may be committed before it.
  - While unavailable: no implementation starts; planning documents stay uncommitted on this Mac.

- [ ] **U1**: Confirm the control placement proposed above
  - Requires: the operator's approval or changes
  - Gates: 2.3, 4.1, 4.2, 5.1, and any part of 1.7 beyond the parity layout
  - While unavailable: Wave 0, 1.1–1.6, the parity part of 1.7, 2.1, 2.2, 3.1, 3.2 and 4.3 can proceed.

- [ ] **X1**: Measure the EVS OSD bands
  - Requires: a straight-on still or grab of the cue output with OSD on, ideally over a plain background
  - Gates: the final numbers of the EVS OSD safe-zone preset (spec F, first criterion). Code proceeds with the provisional 10 % top and 20 % bottom; 6.4 or a follow-up sets the measured values.
  - Note: the XT3 manual documents "OSD on outputs" Yes/No under Operation → OSD Settings, but gives no positions or sizes.

- [ ] **X2**: EVS ingest of files made by build 11
  - Depends on: 6.4
  - Requires: the operator's EVS
  - Gates: the claims "ingests on EVS" for the app's own 1080i50 and 1080p25 output; that 4 and 8 mono tracks appear and play on the right channels; whether 1080p50 with the 25p label is accepted (keeps or drops the Experimental preset); how a `23:59:55:00` pre-roll start and 50p timecode display; whether the MPEG-2 preset is worth keeping.
  - While unavailable: all code tasks proceed; these claims stay unverified and 1080p50 stays Experimental.

- [ ] **X3**: Check the −60 and −40 dB thresholds on five real tracks with fades and reverb tails
  - Depends on: 3.2
  - Gates: the default thresholds only. They are constants in `MusicEndDetector`.

- [ ] **X4**: Remaining open questions, proceeding on the spec's defaults
  - Defaults in force: start timecode 00:00:00:00 with the music at the start timecode; Apply to All copies appearance and preset only; the filename is the clip name; the slate shows "Starts in" and clocks start at the first music frame; MPEG-2 kept as the legacy preset.
  - Gates: nothing in this plan. A changed answer becomes a small follow-up task.

---

## Operational Learnings

- `-top 1` is deprecated in FFmpeg 8.1; `setfield=tff` plus `-flags +ildct+ilme` is what makes the stream interlaced.
- 1080p50 AVC-I cannot be labelled correctly by FFmpeg at any version checked.
- `xcodebuild test` would launch the app on the operator's desktop; `swift test` on `CueCore` is the only automated test path.
- `~/ProgrammingProjects` is mode 700, so Atlas fixtures must be copied into the helper.
- `CuePicture.draw` renders 254 frames/s at 1920 × 1080 in release on M4 Pro (`CUE_BENCH=1`, 500 frames, 180 s track). A 3-minute 1080i50 cue needs 9,000 images, about 35 s of rendering, so the 3-minute target needs no parallel rendering.
- Render hashes match between debug and release builds.
- This Mac is M4 Pro (label in `~/.config/directions/this-mac`; `~/.claude/this-mac` is absent). The app signs ad hoc, so the missing Apple Development certificate does not matter here.

## Blocked Tasks

- 2.3, 4.1, 4.2, 5.1 — waiting on U1.

---

## Execution Log

| Wave / task IDs | Assignments or serial reason | Validation / evidence | Commits or exception | Remaining gates / next action or stop reason |
|---|---|---|---|---|
| 0.1 | Coordinator, serial | `git status -sb` → `## main...origin/main`; https://github.com/Xpycode/Waveform-Cue (public) | `b51eee8` | Next: 0.2, then 0.3; execution not yet requested |
| 0.2 | Coordinator, serial (foundation every later task builds on) | `swift test --package-path Packages/CueCore` 7 tests, 0 failures, 1 skip (benchmark); release run with `CUE_BENCH=1` 254 frames/s; `xcodebuild … build` succeeded | see commit "Extract CueCore" | Next: 0.3 |

---
*Keep active while required work or acceptance is incomplete. On completion, archive with execution
evidence and update incoming links before retiring the active copy.*
