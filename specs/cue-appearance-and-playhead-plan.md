# Cue appearance and playhead implementation plan

> Execute with the shared `commands/execute.md` procedure when this plan is selected explicitly.
> Task state and evidence are authoritative here. [TASKS.md](../TASKS.md) links here and holds backlog and inbox.

**Progress:** 4/9. E1 and E2 remain open. D1, U2 and helper readiness passed 2026-11-27.
**Status:** Wave 1 complete on `feature/cue-appearance-playhead`. Wave 2 task 2.1 is ready. The operator selected Wave 1 only.
**Task states:** unchecked = pending, implemented-unverified or blocked (name the gate); checked = complete with the required evidence.

## Goal

Give a batch of EVS cues one consistent look while each song keeps its own title, timing and export settings, and make the close-up behave predictably at the first and last beat. The [spec](cue-appearance-and-playhead.md) defines the operator workflow and is authoritative for acceptance.

**Journey:** add five songs → style one → **Apply Appearance to Pending Jobs** from either inspector tab → choose playhead mode, end zoom and shading → preview the first and last beats → export → the decoded MXF shows the same window, fonts, elements and clocks as the preview → **Save as Default** makes the look the start for later imports.

Build 11 keeps its own [acceptance and handoff plan](../IMPLEMENTATION_PLAN.md) and its saved candidate in `04_Exports/0.1-11-rc`.

## Acceptance criteria (spec rows → tasks)

- [ ] Batch appearance: 1.1, 2.1 (copy scope), 5.1
- [ ] Defaults and overrides: 1.1 (Save as Default), 2.1 (differences and reset), 4.1 (markers and Reset controls), 5.1
- [ ] Fonts and visibility: 1.3, 2.1, 3.1, 4.1
- [ ] Feature switches: 2.1, 3.2, 4.1
- [ ] Centred close-up: 1.2, 2.1 (edge-held stays the default), 3.1
- [ ] Zoom near end: 1.2, 3.1
- [ ] Close-up shading (added 2026-11-27 at the operator's request): 2.1, 3.1, 4.1; upcoming brighter by default (D1)
- [ ] EVS layout: 2.2; clearance on the real output is external check E1
- [ ] Compatibility: 2.1 (older settings and a build 11 queue), 3.1 (reference frames), 2.2 (the intentional safe-zone change)

## Planning findings (verified against the code, 2026-11-27)

Paths: `Core/` = `Packages/CueCore/Sources/CueCore/`, `Tests/` = `Packages/CueCore/Tests/CueCoreTests/`, `App/` = `Sources/App/`.

- **Apply to All today.** `QueueManager.applyToAll(from:)` (`Core/Queue/QueueManager.swift:294`) copies the whole appearance snapshot and the export preset to the other Pending jobs. Title text and position (`labelText`, `labelX`, `labelY` on `CueJob`), trim, markers, normalise, loudness, audio layout, timecode and filename are not copied. The button is "Apply to All" in `App/Views/JobInspector.swift:294`.
- **Defaults today.** Every appearance edit is saved as the import default (`App/EditorModel.swift:814`, key `ClockAppearance.v1` in `UserDefaults.standard`). With no job selected, an edit changes only that default. "Restore Defaults" in the sidebar resets to the factory look, not the saved default (`App/Views/AppKit/CueAppearanceSidebar.swift:251`).
- **Sidebar state.** `CueAppearanceSidebar` keeps a private copy of the settings from its creation and is rebuilt per job and per tab switch. Nothing pushes a changed appearance into a live sidebar, so Reset and Save as Default need an explicit refresh.
- **Close-up window today.** Two calculations exist: whole frames in `CuePicture.closeUp` (`Core/CuePicture.swift:49`, used by `MonitorView` with an `Int` truncation) and fractional in `Window.closeUp` (`:467`, used by `draw`). Both centre the playhead and hold the window against either end of the clip. Dragging holds the whole window, position and width (`heldDetail` in `MonitorView.swift`). `ZoomWindow.frameCount` clamps the width to the clip, and `Window.count` is whole frames; both must change for blank space beyond the clip and for an eased width.
- **Existing zoom choices** are Off, Auto, 2, 5, 10, 20, 30 and 60 seconds (`Core/CueAppearance.swift:54`). There is no 3-second case. Off removes the close-up panel and enlarges the full track. Auto is the smaller of 10 seconds and half the clip, so the starting width depends on the clip.
- **Two different "off"s and two different "fades".** "Zoom Off" below always means the existing setting that hides the close-up. The new end zoom has its own Off. `fadeCloseUp`/`fadeFullTrack` are the fade-to-red picture switches; trim "fades" are the audio fade in and out.
- **Preview and export rates.** The preview timeline always has 25 positions per second. A 1080i50 export draws 50 pictures per second, one per field, 20 ms apart, top field first (ITU-R BT.709; FFmpeg `interlace`). The preview therefore cannot show a second-field position. Preview and export can be compared at whole 25-base frames only; second-field pictures are checked from the decoded export against the window function.
- **Layout.** The give-way order with reserves is waveforms, then gaps, then clocks, then title (`Core/CueLayout.swift:250`), pinned by `CueLayoutTests.testGiveWayOrderAcrossShrinkingArea` and `testWaveformsGiveWayFirst`. At 11%/11% with Small Elapsed and Large Remaining, reading the code gives a close-up of 182 instead of 265 points and a full track of 71 instead of 100, while about 95 points of gap above the clocks stay unused. The layout distinguishes only close-up on or off; the window width does not affect geometry. With clocks above there is no gap below the close-up.
- **Fonts.** Text is created by name in `CuePicture.line` with Helvetica Neue and Menlo literals, including the slate. `CueLayout` is deliberately free of Core Text and uses fixed Menlo and Helvetica measurements (`CueLayout.swift:59`).
- **Shading.** One routine, `paintEnvelope` (`CuePicture.swift:244`), draws both waveforms: played audio in the full colour, upcoming audio at 65% brightness. The fade to red brightens the played side.
- **Feature data.** Trim, fades and pre-roll are in `TrimSettings`, markers in `MusicMarkers`, safe zones in `SafeZones` (all in `Core/CueTypes.swift`, coordinator-owned). `normalise` and `loudness` are on `CueJob`. The loudness pass and the export gain are in the app target (`EditorModel.swift:1071`, `App/Queue/MXFJobExporter.swift:21`), which has no tests. A nil markers value falls back to the detected markers, so "markers off" must pass an explicit empty value and the file-end target.
- **Equality.** `CueAppearance`, `ClockStyle` and `CueColor` are already `Equatable`. The comment at `Core/Queue/CueJob.swift:149` saying otherwise is stale.
- **Decoding hazard.** `ClockStyle` uses synthesized coding and is read with a throwing `decode`. A new required field would make every older appearance fail to load, and `load()` and `AppearanceSnapshot` would then silently fall back to the defaults. Every new stored field is optional and read with `decodeIfPresent`.
- **Tests.** All suites are XCTest. FFmpeg tests read `FFMPEG_EXECUTABLE` and skip when it is unset; the app's bundled copy is not usable from `swift test`. Opt-ins: `CUE_BENCH=1`, `CUE_EXPORT_BENCH=1`, `CUE_SLATE_PNG=<path>`. `CUE_RECORD_BASELINE=1` rewrites the reference hashes and is set only where a task says so. Appearance decoding tests live in `Tests/RenderTests.swift:65–115`.
- **Core Text facts (checked on this Mac and in Apple's documentation).**
  - `CTFontCreateWithName` never fails; an unknown name returns Helvetica. `preventAutoActivation` does not change that. Detect a missing font with `CTFontDescriptorCreateMatchingFontDescriptor`, which returns nil when nothing matches, or by comparing exact PostScript names.
  - Equal-width digits: feature `kNumberSpacingType` (6) with `kMonospacedNumbersSelector` (0), or OpenType `tnum`, through `kCTFontFeatureSettingsAttribute`. Not every font honours it (Georgia and Zapfino do not).
  - `CTFontGetAdvancesForGlyphs` does not see the feature, because features apply during shaping. Measure each digit through a shaped `CTLine`.
- **EVS facts (Multicam 11.01 operating manual, XT3 configuration manual).** The OUT point is excluded and IN and OUT are always on even fields. The manuals give no size or position for the on-screen rows, do not explain a dot after the timecode, and do not say how Remaining counts at the last field. All three need the real server.

## Decisions taken in this plan (the coordinator logs them in `decisions.md` when the task lands)

1. **Explicit Save as Default replaces auto-save.** Editing a job changes that job only.
2. **Feature switches travel with the appearance; their values stay with the song.** Fonts, visibility, playhead mode, end zoom, shading and the on/off switches for markers, loudness analysis, trim and fades, pre-roll and safe zones are stored in `CueAppearance`, so they copy with Apply Appearance and save with Save as Default. Trim points, fade lengths, markers, gain, pre-roll length and title stay per job. This follows the research (section 3.5) and keeps `CueTypes.swift` unchanged.
3. **Zoom Off stays the only way to hide the close-up.** Visibility switches cover the title, each clock and the full track. No saved-settings migration is needed.
4. **Section labels follow the title font; tick labels follow the clock font.**
5. **The safe-zone give-way order changes** to gap above the clocks first, then waveforms. Every job with reserves renders differently; this is the spec's intentional safe-zone layout change.
6. **End zoom is a new setting** (Off, 2, 3 or 5 seconds), separate from the existing zoom choices.

## Control placement (gate U2, approved 2026-11-27)

Required by the UI changes protocol. The operator approved this placement as proposed; tasks build it exactly as tabled. Only AppKit controls are used: `AppKitPushButton` and the other wrappers in `App/Views/AppKit/InspectorControls.swift` outside the sidebar, AppKit controls inside it. No SwiftUI `Button`, `Toggle`, `Picker` or `TextField`.

| Control | Similar existing control and wiring | Proposed location |
|---|---|---|
| Shared footer: **Apply Appearance to N Pending Jobs**, **Save as Default** | "Apply to All", `JobInspector.swift:294` → `EditorModel.applyToAll()` (`:1047`) → `QueueManager.applyToAll` | `App/Views/InspectorPane.swift`, after the tab `switch` (`:30–42`) and before `.frame(width:)` (`:44`), so it shows under both tabs. N is the number of other Pending jobs; the button is disabled at zero. |
| Existing Job-tab action | same | Stays where it is, relabelled **Apply Appearance and Preset to N Pending Jobs**. |
| **Keep playhead centered** (checkbox), **Zoom near end** (pop-up: Off, 2 s, 3 s, 5 s), **Close-up shading** (pop-up: Upcoming brighter, Played brighter) | Zoom pop-up and checkboxes, `CueAppearanceSidebar.swift:19–25`, `:61–65` → `edit(_:)` (`:211`) → `changed` → `AppearanceSidebarRepresentable.swift:35` → `EditorModel.updateAppearance` (`:811`) | New rows directly under the Close-up row (`CueAppearanceSidebar.swift:139–143`). The sidebar is 318 points wide and that row is full, so nothing fits beside it. End-zoom choices not narrower than the current zoom are disabled. |
| Title font and clock font: Family and Style pop-ups | same pop-up pattern | New "Fonts" group in the sidebar above the clock rows. The clock list holds only fonts that pass the equal-width digit check. |
| Visibility checkboxes: Title, Elapsed, Remaining, Full track | `NSButton(checkboxWithTitle:)` in the sidebar | New "Show" group in the sidebar. |
| Feature switches: Markers, Loudness analysis, Trim and fades, Pre-roll | `AppKitCheckbox`, Job tab section headers (`JobInspector.swift:44–47`) | One checkbox in each matching Job-tab section header. Normalise is disabled while Loudness analysis is off. Safe zones gets its checkbox beside the safe-zone preset in the sidebar. |
| Override dot and per-setting Reset | none yet | A small dot before the row label when the job differs from the saved default; a Reset item in the row's context menu. "Restore Defaults" becomes **Reset All to Default** and uses the saved default. |
| No job selected | today: edits change the default | The Appearance tab shows a working copy of the saved default. Save as Default writes it; Apply is disabled. |

U2 is approved, so no task waits on it. A control that turns out not to fit as tabled goes back to the operator before it is built differently.

## Execution schedule and ownership

- **Scope and limits.** The operator selected Wave 1 on 2026-11-27. Work on branch `feature/cue-appearance-playhead` until build 11's task 6.4 is closed, because 6.4 builds Release from the checkout. The coordinator sets `CURRENT_PROJECT_VERSION: "12"` in `project.yml` before 5.1; the Release build goes to `04_Exports/0.1-12-rc`. Pushes and app control keep their own authorization.
- **Coordinator-owned:** `project.yml`, `WaveformCue.xcodeproj` (run `xcodegen generate` after any wave that adds app-target files), `Packages/CueCore/Package.swift`, `Core/CueTypes.swift`, Git, this plan, `PROJECT_STATE.md`, `TASKS.md`, `decisions.md`, `README.md`, `04_Exports/`, reference-hash re-recording, and the Atlas helper (one session at a time).
- **Tests** means `swift test --package-path Packages/CueCore --scratch-path <the worker's own scratch folder> --filter '<SuiteA|SuiteB>'`. FFmpeg suites add `FFMPEG_EXECUTABLE=/Applications/Magpie.app/Contents/Resources/ffmpeg` in front; without it they pass by skipping. A new scratch folder fetches `swift-subprocess` once from the network.
- **Build** means `xcodegen generate && xcodebuild -project WaveformCue.xcodeproj -scheme WaveformCue -configuration Debug -derivedDataPath <folder outside the project> build`. The coordinator runs it after merging each wave, including Wave 2, whose public types the app compiles against. A worktree worker may run it for itself but does not commit `project.pbxproj`. `build` launches nothing.
- **On-screen checks** run in the Atlas helper on the fresh build and need a screenshot. The operator resumed the helper for the Wave 1 inspector and relaunch checks on 2026-11-27. Confirm readiness and the current control scope again for later passes. Relaunch checks are Atlas checks; they cannot run headlessly.

Dependency graph (no cycles):

```
1.1, 1.2, 1.3, 2.2 ready now
1.1, 1.2 → 2.1
1.2, 1.3, 2.1, 2.2 → 3.1      2.1 → 3.2
1.1, 1.3, 3.1, 3.2 → 4.1
4.1, Atlas → 5.1 → E1
```

## Tasks

### Wave 1 (parallel: four tasks, disjoint files)

- [x] **1.1**: Apply appearance alone, and save defaults explicitly
  - Depends on / external gates: none (U2 approved); Atlas helper for the on-screen pass
  - Owns: `Core/Queue/QueueManager.swift`, `Tests/QueueManagerTests.swift`, `App/EditorModel.swift`, `App/Views/InspectorPane.swift`, `App/Views/JobInspector.swift`
  - Detail: add a copy scope to `applyToAll` (appearance only, or appearance and preset). Appearance only leaves the preset and saved output path alone. Remove the auto-save in `updateAppearance`; add `saveAppearanceAsDefault()` using the existing `CueAppearance.save()`. With no job selected, keep a working copy of the default. Add the footer and relabel the Job-tab action per U2. Title position is not copied.
  - Interface: `QueueManager.applyToAll(from:scope:)` returning the changed job IDs; `EditorModel.saveAppearanceAsDefault()`.
  - Success: unit tests for both scopes with zero eligible jobs, mixed statuses (only other Pending jobs change), and other jobs keeping their own title, preset, trim, markers, normalise and pre-roll. Atlas pass: footer under both tabs, count in the button title, Save as Default survives a relaunch and is used by the next import, an edit without Save as Default is not.
  - Backpressure: tests `QueueManagerTests`; Build; Atlas pass.

- [x] **1.2**: Close-up window calculation
  - Depends on / external gates: none
  - Owns: new `Core/CloseUpWindow.swift`, new `Tests/CloseUpWindowTests.swift`
  - Detail: a pure function in seconds. Inputs: fractional playhead time, clip bounds after trim, the effective countdown target, the starting width (already resolved from the zoom setting), `PlayheadMode` (edge-held or centred) and `EndZoom` (off, 2, 3 or 5 seconds). Output: the visible interval and its intersection with the clip.
    - Width: `w = lerp(start, final, smoothstep(progress))`, driven only by time remaining to the target, so a jogged frame always gives the same picture. Timing: the transition starts `0.75 × final + 1 s` before the target and ends `0.75 × final` before it (2 s: 2.5 → 1.5; 3 s: 3.25 → 2.25; 5 s: 4.75 → 3.75). A final width not smaller than the start is no transition.
    - Centred: the interval is `playhead ± w/2`, including blank space outside the clip.
    - Edge-held: interpolate the window's edges, not just its width, from today's window (centred, held against the clip ends) to a window of the final width anchored on the target. The target stays in view from the end of the transition until the playhead passes it; after that the window follows the playhead to the clip end.
    - With end zoom Off and edge-held mode, the interval equals today's `Window.closeUp` for every position.
  - Interface (frozen for 2.1 and 3.1): `PlayheadMode`, `EndZoom`, `CloseUpWindow.interval(...)`.
  - Success: tests over starting widths 2, 5, 10, 20, 30, 60 and Auto on clips of 4, 6, 8, 12 and 30 seconds, File end and Music end with a 10-second silent tail, trimmed clips, half-frame (20 ms) steps and reverse order. Invariants: both edges continuous in playhead time (no step larger than the playhead step times a stated bound), width never grows toward the target, the playhead is always inside the interval, centred mode keeps the playhead exactly central, Off matches today.
  - Stop condition: if edge-held mode cannot satisfy continuity and target-in-view together for some case, stop and return the failing cases for a decision instead of adding special cases.
  - Backpressure: tests `CloseUpWindowTests`.

- [x] **1.3**: Font resolution and metrics (added in review; split from 3.1)
  - Depends on / external gates: none
  - Owns: new `Core/CueFonts.swift`, new `Tests/CueFontsTests.swift`
  - Detail: resolve a saved PostScript name to a font, falling back to Helvetica Neue Medium (title) or Menlo (clocks) when `CTFontDescriptorCreateMatchingFontDescriptor` finds nothing. Apply the equal-width digit feature to clock fonts. Decide whether a font passes by measuring each of `0`–`9` through a shaped `CTLine`, not `CTFontGetAdvancesForGlyphs`. Return the plain numbers the layout needs (ascent, descent, cap height, clock string width) so `CueLayout` stays free of Core Text. List the families and styles for the pop-ups.
  - Interface (frozen for 3.1 and 4.1): `CueFonts.resolve(name:role:)`, `CueFonts.hasEqualWidthDigits(_:)`, `CueFonts.metrics(for:size:)`, `CueFonts.clockCandidates()`.
  - Success: an unknown name falls back; Menlo and Helvetica Neue with the feature pass the digit check and Georgia fails; a nil name gives exactly today's fonts and measurements.
  - Backpressure: tests `CueFontsTests`.

- [x] **2.2**: Reclaim the clock gap before shrinking the waveforms (ID kept from the first draft; ready from the start)
  - Depends on / external gates: none
  - Owns: `Core/CueLayout.swift`, `Tests/CueLayoutTests.swift`. `RenderTests` is run, not edited.
  - Detail: with reserves on and clocks below, give up the gap between the waveform group and the clocks (down to its floor) before shortening either waveform. Before changing anything, pin today's rectangles at 11%/11% with Small Elapsed, Large Remaining and the close-up on as test constants; that is the build 11 comparison. Rewrite `testGiveWayOrderAcrossShrinkingArea`, `testWaveformsGiveWayFirst` and the doc comment at `CueLayout.swift:9–18`.
  - Success: at 11%/11% the close-up is taller than the pinned build 11 value, tick labels and clocks stay separated, nothing but background is inside a reserved band, and geometry with reserves off is identical. Also covered: clocks above (unchanged, since no gap exists below the close-up) and zoom Off.
  - Backpressure: tests `CueLayoutTests|RenderTests|BaselineTests`.

### Wave 2 (single task: the settings model everything later reads)

- [ ] **2.1**: Store the new choices, keep older jobs unchanged, and expose effective settings
  - Depends on / external gates: 1.1 (shares `QueueManagerTests`), 1.2 (`PlayheadMode`, `EndZoom`)
  - Owns: `Core/CueAppearance.swift`, `Core/Queue/CueJob.swift`, `Tests/CueJobTests.swift`, `Tests/CueTypesTests.swift`, `Tests/QueueStoreTests.swift`, the decoding tests in `Tests/RenderTests.swift:65–115`, and one added copy-scope test in `Tests/QueueManagerTests.swift`
  - Detail: add to `CueAppearance`, all optional and read with `decodeIfPresent`: title and clock font names, visibility of title, each clock and the full track, playhead mode, end zoom, close-up shading, and the five feature switches. A missing key in a saved job means today's behaviour: edge-held, end zoom Off, played audio brighter, everything visible and enabled. The factory look, and a saved default that predates this round, use upcoming audio brighter (D1). Add `differences(from:)` (the settings that differ from another appearance) and `resetting(_:to:)`. Fix the stale comment at `CueJob.swift:149`.
  - Interface (frozen for 3.1, 3.2 and 4.1): on `CueJob`, `effectiveAppearance` (countdown target forced to File end with markers off; safe zones None when off), `effectiveMarkers` (explicitly empty when off, never nil), `effectiveTrim` (whole file, no fades, no pre-roll as switched), `shouldMeasureLoudness`, `effectiveGainDB`. Stored values are untouched while a switch is off.
  - Success: a build 10 appearance blob, a build 11 `queue.json` string (inline, like the existing legacy fixtures) and a saved zoom Off all load with identical values and the legacy defaults above. Load, save, load preserves everything. Switching a feature off and on returns the stored values. Apply Appearance copies the new fields and switches, and leaves per-song values alone.
  - Backpressure: tests `CueJobTests|CueTypesTests|QueueStoreTests|RenderTests|QueueManagerTests`; coordinator Build.

### Wave 3 (parallel: two tasks, disjoint through 2.1's interface)

- [ ] **3.1**: Render and hit-test the window, fonts, visibility and shading
  - Depends on / external gates: 1.2, 1.3, 2.1, 2.2
  - Owns: `Core/CuePicture.swift`, `Core/CueLayout.swift`, `App/Views/AppKit/MonitorView.swift`, `Tests/RenderTests.swift`, `Tests/CueLayoutTests.swift`, `Tests/BaselineTests.swift`, `Tests/CloseUpWindowTests.swift`, and the close-up and hit-test call sites in `Tests/CountdownTests.swift` (`:245–279`) and `Tests/TrimPreRollTests.swift` (`:218–236`). Also the `layout` property in `Core/CueAppearance.swift:115`, which 2.1 has finished with; 3.2 reads that file and does not edit it.
  - Detail:
    - Replace both existing window calculations with 1.2's interval, in seconds. Drawing, the overview highlight (real clip portion only), ticks, markers, click and drag-to-seek, and trim handles all read that one interval. Remove the width clamp for centred mode. Dragging keeps holding the window.
    - Fonts and visibility become layout inputs: clock width and text metrics come from 1.3, and a hidden title, clock or full track gives up its space and its click target.
    - Shading: `paintEnvelope` takes the shading choice for the close-up. With upcoming brighter, the fade to red brightens the upcoming side and dims the played side. The full track keeps played brighter.
    - `draw` keeps its signature, so `Core/MXFExport.swift` needs no edit.
  - Success: reference hashes are unchanged for every legacy setting. New hash tests: each hidden element, each shading, centred mode at both clip boundaries (playhead stationary at the centre, 2.5 s blank on the outer side for a 5-second window), end zoom alone, and both together. Preview and export pictures match at whole 25-base frames; second-field export pictures match the window function at 20 ms steps. A hidden waveform returns no hit target. Because D1 makes upcoming-brighter the factory default, the coordinator re-records the affected default hashes once with `CUE_RECORD_BASELINE=1` and names them in the evidence.
  - Backpressure: tests `CloseUpWindowTests|CueLayoutTests|RenderTests|BaselineTests|CountdownTests|TrimPreRollTests` with `FFMPEG_EXECUTABLE`; Build.

- [ ] **3.2**: Apply the feature switches to preview, validation and export
  - Depends on / external gates: 2.1
  - Owns: `App/EditorModel.swift`, `App/Queue/MXFJobExporter.swift`, `App/Views/MonitorPane.swift`, `App/Views/AppKit/MonitorRepresentable.swift`, validation in `Core/Queue/QueueManager.swift`, `Tests/QueueManagerTests.swift`, new `Tests/FeatureSwitchTests.swift`. Edits no file owned by 3.1.
  - Detail: feed 2.1's effective values everywhere the stored ones are read: the monitor inputs (`MonitorPane.swift:16–19`), preview timeline, the I and O keys, the loudness pass (`EditorModel.nextLoudnessJob`), the exporter's measurement and gain, and `QueueManager.blockingReason`. With trim off, pass no trim callback so the handles disappear. Safe-zone guides stay preview-only and hide while safe zones are off.
  - Success: `FeatureSwitchTests` build the timeline from effective values: markers off counts down to file end; trim and fades off uses the whole track; pre-roll off has no slate; safe zones off gives the None layout and validation agrees; `shouldMeasureLoudness` and `effectiveGainDB` are false and zero with analysis off. `RenderTests.testExportHasNoGuidePixels` still passes. Re-enabling restores the saved values. Toggling loudness analysis while a pass is running is an Atlas check in 5.1; the pass and gain code in the app target is otherwise covered only by Build.
  - Backpressure: tests `QueueManagerTests|FeatureSwitchTests|ClipTimelineTests|TrimPreRollTests|LoudnessAnalyzerTests|ExportIntegrationTests` with `FFMPEG_EXECUTABLE`; Build.

### Wave 4 (single task: it edits the inspector files 1.1 and 3.2 changed)

- [ ] **4.1**: Inspector controls, override markers and Reset
  - Depends on / external gates: 1.1, 1.3, 3.1, 3.2 (U2 approved); Atlas helper for the on-screen pass
  - Owns: `App/Views/AppKit/CueAppearanceSidebar.swift`, `App/Views/AppKit/AppearanceSidebarRepresentable.swift`, `App/Views/AppKit/InspectorControls.swift` (only if a wrapper is missing), `App/Views/InspectorPane.swift`, `App/Views/JobInspector.swift`, `App/EditorModel.swift`
  - Detail: add the controls exactly as approved in U2. Push appearance into a live sidebar after Reset, Reset All and Save as Default. Disable Normalise while loudness analysis is off. Disable end-zoom choices that are not narrower than the current zoom.
  - Success (Atlas pass): every new control changes the preview; values survive tab changes, job selection and a relaunch; the override dot appears on an edited setting and clears on Reset; Reset All returns the job to the saved default; a missing saved font shows the fallback without an error.
  - Backpressure: tests `CueJobTests|QueueManagerTests|CueFontsTests`; Build; Atlas pass.

### Wave 5 (acceptance)

- [ ] **5.1**: Five-song acceptance, review and handoff candidate
  - Depends on / external gates: 4.1; Atlas helper ready
  - Owns: acceptance evidence under `sessions/evidence/`, decoded synthetic exports, `README.md` text for the new controls
  - Detail and success:
    - Full suite: `FFMPEG_EXECUTABLE=/Applications/Magpie.app/Contents/Resources/ffmpeg CUE_BENCH=1 CUE_EXPORT_BENCH=1 CUE_SLATE_PNG=<scratch>/slate.png swift test --package-path Packages/CueCore`, with no failures and no skips.
    - Code review of the round's diff and `/shell-check`; fixes land before the build.
    - Version 12 Release build in `04_Exports/0.1-12-rc`, recorded per the app-handoff procedure.
    - In the helper, a synthetic five-job queue: apply from the footer on both tabs, import after Save as Default, toggle and reset a feature, toggle loudness analysis during a running pass, scrub and jog, and export an end zoom in each playhead mode and each shading. Screenshots of the inspector and of both ends of the clip. Compare preview and decoded MXF at the same whole frames, and decoded second fields against the window function.
    - Prepare the two E1 files: 1080i50, 5-second zoom, Small Elapsed, Large Remaining, at 11%/11% and at 11%/16%.
    - Checks that could not run are listed separately, not folded into a pass.
  - Backpressure: the full-suite command above; Release build; Atlas pass.

## External checks

- [x] **D1**: Default close-up shading. Decided by the operator 2026-11-27: upcoming audio brighter for new jobs and as the factory default; saved build 11 jobs keep played-brighter.
  - Consequence: 2.1 sets that default, and 3.1 re-records the default reference hashes once.
- [x] **U2**: Control placement. Approved by the operator 2026-11-27 as tabled above.
- [x] **Atlas helper ready** — on 2026-11-27 the operator resumed agents and the fresh Debug app passed the Wave 1 inspector and relaunch checks.
  - Gates: the on-screen passes of 1.1, 4.1 and 5.1. Code and headless tests proceed.
- [ ] **E1**: Overlay clearance on the EVS output (continues gate X1 of the build 11 plan)
  - Requires: the operator's EVS and a direct output grab of the two files from 5.1, same clip and clock sizes.
  - Gates: the spec's claim that the clocks clear the EVS timecode row, and any change to the EVS safe-zone preset numbers (not a task in this plan). The EVS manuals give no row positions, so only the grab can settle it.
  - While unavailable: every task proceeds; clearance stays unverified.
- [ ] **E2**: Field countdown on clip 413A
  - Requires: the operator's EVS; jog consecutive fields at the head and tail and record the EVS and burned-in values, and what the dot after the timecode marks.
  - Gates: no task here. A changed clock rule would be a follow-up. Known: EVS excludes the OUT point and puts IN and OUT on even fields.

Out of scope: the toolbar divider and filename truncation (separate small fix in the backlog), live propagation of edits across jobs, and a 50-position preview.

## Review record (2026-11-27)

Three independent reviews (code facts, schedule and spec coverage, web facts) found these mistakes in the first draft, all corrected above:

1. No control-placement gate, although 1.1 and 4.1 add controls. Added U2.
2. Wave 3's tasks shared files and an undefined interface. 2.1 now freezes the effective-settings interface and the ownership lists are disjoint.
3. Several 3.2 checks pointed at suites that cannot reach app-target code (`LoudnessTests` runs no analysis). The decisions moved into CueCore as pure functions with their own tests.
4. "Bundled FFmpeg" was wrong; tests need `FFMPEG_EXECUTABLE` and otherwise pass by skipping.
5. The end-zoom timing covered one of three widths and jumped for starting widths under `1.5 × final + 2 s`, for Auto on short clips and for Music end targets. 1.2 now states the formula, an edge interpolation, invariants and a stop condition.
6. "Final widths of 2, 3 or 5 seconds" was presented as part of the existing zoom setting, which has no 3-second case. It is a new setting.
7. Preview and export cannot match at second fields; the preview has 25 positions per second.
8. The font check named an API that cannot see the digit feature, and missing fonts were not detectable as described. Split into 1.3 with the corrected method.
9. Fonts and visibility were not treated as layout inputs although the layout uses fixed Menlo and Helvetica numbers.
10. 2.2 reversed a behaviour pinned by two tests without saying so, cited a five-second close-up that does not affect geometry, and sat in Wave 2 with no prerequisites.
11. 2.1 claimed the copy logic without owning its file, cited suites that do not hold the appearance decoding tests, and left the storage of feature switches open. A required new `ClockStyle` field would have silently reset every older appearance.
12. Missing from every task: safe-zones switch, edge-held as the stored default, override comparison and reset logic, Normalise disabled with analysis off, the fate of "Restore Defaults", and editing with no job selected.
13. Relaunch and on-screen checks sat inside headless tasks.
14. No build number, branch or output folder, with build 11's 6.4 still building from the same checkout.
15. The EVS bullets gated nothing in the plan and no task produced the comparison files.
16. "Put the controls beside the existing zoom setting": that row is full. "Preserve the selected track's title": the selected job is never at risk; the rule is that other jobs keep theirs.

Added at the operator's request: reversed close-up shading.

## Execution log

| Task | Assignment | Validation and evidence | Commit or exception | Next |
|---|---|---|---|---|
| 1.1 | Appearance and queue worker, independent review by fonts worker | 46 queue tests. Applied appearance from both tabs to the other Pending job. After relaunch a third import used the saved five-second zoom and close-up fade. The later full-track fade edit stayed out of the import default. [Appearance](../sessions/evidence/appearance-wave1/appearance.png) · [Job](../sessions/evidence/appearance-wave1/job.png) · [Third import](../sessions/evidence/appearance-wave1/relaunch.png) | `e8f842f` | 2.1 |
| 1.2 | Window worker, independent review by appearance worker | Six tests covering 20 ms jogs in both directions, widths, trim, music-end targets and partial final frames. At 6.01 s the five-second legacy window ends at 6.04 s and its intersection ends at 6.01 s. No continuity or target-hold exception. | `91144a8` | 2.1 and 3.1 |
| 1.3 | Fonts worker, independent review by appearance worker | Four tests cover fallback, default measurements, shaped digits, clock candidates and mixed-digit kerning. American Typewriter and Euphemia UCAS remain available for titles. Clock selection excludes both because their timecodes change width. | `3be2e93` | 3.1 and 4.1 |
| 2.2 | Coordinator, independent review by appearance worker | At 11%/11%, Small Elapsed, Large Remaining and five-second zoom, the full track grew from 71 to 93 px and close-up from 182 to 244 px. Tick-to-clock clearance went from 95.17 to 12.17 px. Raster tests found only background in reserved bands. Larger reserves spend the residual after waveform reduction. Above-clock and no-reserve fixtures passed. | `dcd417e` | 3.1 and E1 |

Wave 3 integration should pass the picture timeline's fractional clock-frame position in source seconds and its physical source range to `CloseUpWindow.interval`. The window may extend through the last padded field. Its intersection clips to the actual source. The end-zoom and font controls are scheduled for Wave 4.

The regenerated Xcode project had no diff. The final Debug app passed deep, strict signature verification and opened in Atlas. Its [empty-selection footer](../sessions/evidence/appearance-wave1/final-build.png) shows the zero-target state. The earlier inspector test used identical task 1.1 code. The helper's original default was restored and its four previous Done rows remained after removing the test jobs.

Final headless integration on the M4 Pro passed all 261 XCTest cases with zero skips. FFmpeg, both benchmarks and the slate image check were enabled. The 180-second AVC-Intra exports took 24.11 s at 1080p25 and 42.95 s at 1080i50. The local build and test transcripts are in `04_Exports/appearance-wave1-debug/`. Wave 2 is ready when selected.
