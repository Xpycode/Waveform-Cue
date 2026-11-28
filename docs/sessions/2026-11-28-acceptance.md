# Task 6.2 acceptance pass (2026-11-27/28, M1 Max)

Debug build of commit `aaa9411` in the Atlas helper (`AppAtlas`), macOS 27.2, Xcode 27.2. Fixtures were synthetic and copied in: 12 tracks of 15 s with a fade to 12 s, plus Silent (−66 dBFS), No Tail (10 s), Short (2 s), Broken (random bytes), Fade Reverb (34 s AAC). Screenshots are in `04_Exports/0.1-11/acceptance-6.2/` on the M1 Max (local, not in Git). Decoded measurements used the bundled FFmpeg 8.1 on files collected from the helper.

**Key:** ✅ verified this pass · ☑️ verified by tests or an earlier Atlas pass (task named), not repeated · ⛔ not met · ⏳ externally gated · ❔ not checked.

## A. App Shell

| # | Result | Evidence |
|---|---|---|
| A1 fresh launch | ✅ | Hidden title bar, dark by default, Appearance menu (shot 01). Editor toolbar role, Theme: `/shell-check` 10/10 |
| A2 three panes | ✅ | Queue, monitor and inspector in an `HSplitView`; inspector hosts Job and Appearance (shots 02, 08) |
| A3 flat toolbar buttons | ⛔ on SDK 27 | Built with the macOS 27.2 SDK, which ignores `UIDesignRequiresCompatibility`: macOS draws glass capsules around the toolbar groups (shot 01). Code uses `FlatToolbarButtonStyle`. See TASKS backlog |
| A4 build 6 parity | ✅ part, ☑️ 1.7 | This pass: Space play and pause, export. Scrub, frame steps and text drag: task 1.7 pass |
| A5 monitor is `MonitorView` | ☑️ code | `MonitorRepresentable` with a `@MainActor` coordinator |

## B. Batch queue

| # | Result | Evidence |
|---|---|---|
| B1 drop 12 / folder | ✅ | Folder opened on the app icon: 12 jobs in order, "Skipped 1 file that is not audio" (shot 02). Drag-and-drop onto the sidebar cannot start in the helper |
| B2 per-job edits, Apply to All | ✅ | Preset 1080p25 applied to all; Track 02's trim stayed its own. Audio track layout is not copied (TASKS inbox) |
| B3 serial in list order | ✅ | Output times 01, 05–12 in order after 02–04 exported singly; row states Pending, Exporting %, Done, Failed, Cancelled seen (shot 03) |
| B4 Cancel | ✅ | Fade Reverb cancelled at about 30 %: row Cancelled, hidden temporary file removed, no partial file |
| B5 Retry | ✅ | Back to Pending; the rerun wrote `Fade Reverb - Cue 2.mxf` beside the first |
| B6 restore | ✅ | Relaunch restored 17 jobs; a job exporting when the app was killed came back Pending. Missing source: ☑️ 2.3 |
| B7 work while running | ☑️ 2.3, 4.1 | Not repeated |
| B8 quit while running | ✅ | "The queue is exporting" with Stop Queue and Quit or Keep Exporting (shot 06). The prompt stays after the queue finishes (shot 07, TASKS inbox) |

## C. Export presets

| # | Result | Evidence |
|---|---|---|
| C1 preset list and readout | ✅ | Four presets incl. "(Experimental)" and "(legacy)"; readout "AVC-Intra 100 · 1080i50 · 115 Mb/s · 2 mono" |
| C2 1080i50 format | ✅ | h264 High 4:2:2 Intra, yuv422p10le, bt709, top first, 1920 × 1080, 25 fps. RP2027 label: ☑️ `ExportIntegrationTests` |
| C3 2/4/8 mono | ✅ count, ☑️ mapping | X2 samples carry 2, 4 and 8 mono 24-bit tracks; channel mapping by integration test; on EVS ⏳ X2 |
| C4 start timecode | ✅ | 10:00:00:00 samples; 23:59:50:00 and 23:59:55:00 pre-roll starts |
| C5 filename, no overwrite | ✅ | `{name} - Cue`, then ` 2`, ` 3` |
| C6 50 images per second | ✅ | Decoded 1080i50 frame shows field weaving on moving labels (shot 10) |
| C7 1080p50 note | ✅ part | Menu marks it Experimental; the note shown on selection ☑️ 4.1 |
| C8 partial-frame padding | ☑️ tests | 4.013 s cases in `ExportIntegrationTests` |

## D. Music end

| # | Result | Evidence |
|---|---|---|
| D1 detect and draw | ✅ | Music end 0:11.99, fade start 0:11.97 on a fade ending at 12 s; Fade and End drawn (shot 02) |
| D2 edit, Reset | ☑️ 4.1 | Not repeated |
| D3 Countdown to Music end | ☑️ 4.2 | Not repeated; review fix keeps a music end before In from driving it |
| D4 no silent tail | ✅ | No Tail: music end 0:10.00 = file end |
| D5 all below −60 dBFS | ✅ | Silent: "No music detected" (shot 04) |

## E. Loudness, trim, pre-roll

| # | Result | Evidence |
|---|---|---|
| E1 readout and badge | ✅ | −12.3 LUFS, −11.0 dBTP, 10.7 LU, matching FFmpeg ebur128 exactly; R 128 badge (shot 02) |
| E2 Normalise | ☑️ 5.1, tests | Measured on the untrimmed source (TASKS inbox) |
| E3 trim | ✅ typed, ☑️ 5.1 keys and drag | In 0:02 typed and Command-E pressed without leaving the field: 13 s file (189 MB vs 218 MB untrimmed) |
| E4 pre-roll slate | ✅ | 2 s track with 10 s pre-roll: 12 s file, TC 23:59:50:00; slate render (shot 11) |

## F. Safe zones

| # | Result | Evidence |
|---|---|---|
| F1 presets | ✅ | None, EVS OSD, Custom; EVS OSD provisional 10 % / 20 % ⏳ X1 |
| F2 nothing in the bands | ✅ | Exported 1080i50 frame: title below row 108, clocks end near row 700, bottom 216 rows background only (shot 10) |
| F3 give-way order | ✅ | Waveforms shrink first (shot 08); full order ☑️ `CueLayoutTests` |
| F4 clock position | ✅ | Above waveforms moves both clocks (shot 09) |
| F5 guides monitor only | ✅ | Hatched in the monitor (shot 08), absent from the export (shot 10) |
| F6 remembered, copied | ☑️ 4.2 | Not repeated |
| F7 text drag clamped | ❔ | Not checked on screen; ☑️ layout tests |

## Edge cases and error states

| # | Result | Evidence |
|---|---|---|
| Short track | ✅ | 2 s track, 10 s pre-roll exported without a crash |
| Trim under 1 s | ✅ | "Trim range too short…", Export Selected disabled (shot 05) |
| 50 jobs, two CAFs | ☑️ test | `testFiftyJobsNeverHoldMoreThanTwoCAFs`; decoded audio of a killed launch removed at relaunch (new, ✅) |
| Low disk space | ☑️ tests | `DiskSpace` tests incl. unknown free space (review fix) |
| Encoder failure log | ☑️ test | `testEncoderFailureKeepsLast1500CharactersOfLog` |
| Decode failure | ✅ | Broken.wav added as Failed with FFmpeg's reason |
| Unwritable destination | ☑️ 3.3 | Not repeated |

## Review fixes (task 6.3) on screen

- ✅ Typed Trim In kept when Command-E is pressed in the field (E3).
- ✅ Playback stops when the previewed job starts exporting; the playhead held at 147 for 5 s.
- ✅ Space still plays and pauses with the monitor focused. Full Keyboard Access itself was not tried.
- ✅ Decoded audio of a killed launch removed at the next launch.
- ❔ Colour-panel resync, Export Selected to Folder refusal and menu state, "will export in its turn" status, Finder aliases: not checked on screen (native panels and alias creation need the person or Finder automation in the helper).

## Observations (to TASKS inbox)

- The quit prompt stays up after the queue finishes and still says "The queue is exporting" (shot 07).
- A queue row's Cancel reported an Accessibility press but did not cancel; a pointer click did. Possibly the reused table cell; check with VoiceOver.
- Apply to All copies the preset but not the audio track layout.
