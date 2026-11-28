# Task 6.2 acceptance pass: Waveform Cue 0.1 (11)

Build under test: `/private/tmp/claude-501/-Users-simpro-ProgrammingProjects-1-macOS-FCPlugins-AudioWaveformDisplay/df864073-9147-4f0b-af6f-7f2efbca5855/scratchpad/rel/dd/Build/Products/Release/Waveform Cue.app` (Info.plist: CFBundleShortVersionString 0.1, CFBundleVersion 11, UIDesignRequiresCompatibility true). Spec: `specs/batch-presets-cue-tools.md`. Date: 2026-11-27.

## Status of this pass: on-screen part not run

The Atlas helper was not usable during this pass, so this build was never opened in it:

1. From the start, `atlas doctor` said `ready: false`: "No action of unknown outcome" failed. The unknown action belonged to another session ("Codex · MousePlus · 19:42", `yours: false`), from a "couldn't press a control in MousePlus" step. Atlas rules forbid `atlas restart` over another session's unknown action. I waited about 25 minutes and the action was never recovered.
2. Then `atlas cleanup --apply` returned `code: stopped`: **the person stopped agents in the helper.** All helper work stopped there.

Effect: no screenshot, no app-made MXF and no helper `ps` check exists from build 11. Fixture copy plans `0713549750b934ac936f9032bad6a34a6e9b1d8d0b416853` and `acddc3893652bb35236ea04106697500563dd01355fbda51` were only **previewed**, never applied. Nothing was copied into the helper and no app was opened there. Both previews may still show in `atlas cleanup` until it can be applied once agents resume.

Synthetic fixtures are ready for a re-run in `/private/tmp/claude-501/-Users-simpro-ProgrammingProjects-1-macOS-FCPlugins-AudioWaveformDisplay/df864073-9147-4f0b-af6f-7f2efbca5855/scratchpad/6.2/fx/`. They are: `folder12/` (12 × 4 s tones with a fade and a 1 s silent tail, plus `notes.txt` and a random-bytes `Broken.wav`), `single/fadeTail.wav` (8 s tone, 2 s fade, 2 s silence), `quiet.wav` (−70 dBFS), `short06.wav` (0.6 s), `trimme.wav` (12 s) and `long40.wav` (40 s). The copy manifest is `/private/tmp/claude-501/-Users-simpro-ProgrammingProjects-1-macOS-FCPlugins-AudioWaveformDisplay/df864073-9147-4f0b-af6f-7f2efbca5855/scratchpad/6.2/manifest.toml`.

### How to read this checklist
- **verified (cited)**: proven by earlier evidence on an earlier build of this round (IMPLEMENTATION_PLAN.md "Evidence" lines; Atlas passes on debug builds) or by the automated suite (247 tests, 0 failures, 0 skips, commit `dada202`). Build 11 itself was **not** exercised on screen.
- **not verified**: either no evidence exists, or the brief requires a re-check on this build because commit `dada202` (task 6.3 fixes) touched it, and that re-check could not run. Prior evidence is still listed.
- **externally gated**: X1 (EVS OSD band sizes), X2 (EVS ingest), X3 (real-track thresholds).

Re-verify list from the brief (items 1–9) → all **not verified** in build 11; see the rows marked ⟲.

---

## A. App Shell migration

| # | Criterion | Status | Evidence |
|---|---|---|---|
| A1 | Hidden title bar, editor toolbar role, dark default, Light/Dark/Match System, AppShellKit Theme, `UIDesignRequiresCompatibility` | verified (cited) | Build 11 Info.plist read with `plutil`: `UIDesignRequiresCompatibility => 1`. Cited: task 1.7 Atlas pass (hidden title bar, flat toolbar, three panes); task 6.3 `/shell-check` 10/10. Caveat from 6.3: `Theme` is the dark-only floor, light ramp pending. |
| A2 | HSplitView three panes, inspector content, autosaved layout, pane toggles remembered | verified (cited) | Cited: task 1.7 Atlas pass (three panes; hidden queue remembered across relaunch); 6.3 shell-check (HSplitView, split autosave). |
| A3 | Flat toolbar button style on all buttons | verified (cited) | Cited: task 1.7 Atlas pass; 6.3 shell-check. |
| A4 | Single-track parity: play, scrub, frame step, title drag, export; preview equals export | verified (cited) | Cited: task 1.7 Atlas pass (500 frames, scrub to 250, Left Arrow to 249, title drag → Custom, MPEG-2 export). Suite: 20 baseline render hashes unchanged; 3.1 decoded frame vs preview mean error 0.10–0.13 (AVC-I). |
| A5 | Monitor is `MonitorView` in `NSViewRepresentable` with `@MainActor` coordinator | verified (cited) | Cited: task 1.7 design and 6.3 review over `b51eee8..HEAD`. Code-structure criterion, not on-screen. |

## B. Batch queue

| # | Criterion | Status | Evidence |
|---|---|---|---|
| B1 | 12 files or folder → 12 jobs in order, unsupported skipped with one line, overlay text = filename | ⟲ not verified | Re-verify item 1; helper unavailable. Cited earlier: task 2.3 Atlas pass (12 Pending in name order, 1 Failed `Broken.wav`, "Skipped 1 file that is not audio"). |
| B2 | Per-job edits; Apply to All copies appearance and preset to Pending only | ⟲ not verified | Re-verify item 8. Cited earlier: 2.3 (job 3 edit left job 4 unchanged); 4.1 (Apply to All changed only the two Pending jobs). |
| B3 | Serial export, row states, toolbar progress, idle-sleep prevention | ⟲ not verified | Re-verify item 1 (6.3 changed progress counting for Paused). Cited earlier: 2.3 serial export of 12; 3.3 `pmset -g assertions` showed "Waveform Cue is exporting a queue" during the run and none after. |
| B4 | Cancel: encoder stops, no partial file, Cancelled, queue moves on; Stop Queue leaves rest Pending | ⟲ not verified | Re-verify item 2. Cited earlier: 2.3 (Start then Stop Queue → Cancelled, no `.mxf` or hidden temp file); 5.2 (cancelled re-export left no file). Suite: queue tests (cancel waits for exporter end, stop). |
| B5 | Retry → Pending with fresh non-colliding name | ⟲ not verified | Re-verify item 2. Cited earlier: 5.2 Atlas pass (Retry plus Start Queue reused `… 2`, not `… 3`). |
| B6 | Relaunch restores queue; interrupted → Pending; missing source → Failed "Source not found" | ⟲ not verified | Re-verify item 5. Cited earlier: 3.3 Atlas pass ("Restored 13 jobs. 1 source not found."; Cue 3 "Failed: Source not found"). |
| B7 | While running, preview and editing of other jobs work; running job locked | verified (cited) | Cited: task 4.1 Atlas pass ("running job locked"); suite lock tests. |
| B8 | Quit while running asks to stop the queue first | ⟲ not verified | Re-verify item 4. **No earlier on-screen evidence**: 3.3 notes "Not exercised on screen: … the Stop-Queue-and-Close sheet". The strings "Stop Queue and Quit" / "Stop Queue and Close" exist in `Sources/`. |
| B-quit | (brief item 3, 6.3 finding) Idle quit right after adding files exits cleanly with no `ffmpeg` left | ⟲ not verified | Re-verify item 3. **No earlier evidence**: 6.3 says "The quit wind-down has no unit test; it is checked on screen in 6.2". This is still open. |

## C. Export presets

| # | Criterion | Status | Evidence |
|---|---|---|---|
| C1 | Picker lists the four presets; format readout shows codec, layout, bitrate class, audio | ⟲ not verified | Re-verify item 8. Cited earlier: 4.1 Atlas pass (preset picker, Experimental note); 3.3 (toolbar readout from the job's preset). Suite: preset tests (fixed IDs, `formatReadout`). |
| C2 | AVC-I 1080i50: OP1a, High 4:2:2 Intra 10-bit, 1920 × 1080, TFF, RP2027 1080i label, single partition, Rec. 709, 24-bit 48 kHz mono PCM | ⟲ not verified (on build 11); file facts verified (cited) | Re-verify item 1 (decode of an app-made file). Cited: 3.1 `ExportIntegrationTests` (High 4:2:2 Intra 10-bit, `field_order=tt`, `…31 02` label, no body partition, bt709, mono 24-bit); 3.3 app-made 1080i50 file (High 4:2:2 Intra 10-bit, bt709, top first, 2 mono 24-bit tracks). "Ingests on EVS" for build 11 output is **externally gated (X2)**. |
| C3 | 2/4/8 mono: L on 1, R on 2, rest silent, full length | verified (cited) for files; 4/8-track playback on EVS externally gated (X2) | Cited: 3.1 (N mono tracks of exactly `outputFrames × samplesPerFrame`, tracks 3+ zero); 4.1 export with four mono 24-bit tracks. |
| C4 | Start timecode default 00:00:00:00, HH:MM:SS:FF at 25 fps, embedded TC matches | ⟲ not verified | Re-verify item 1. Cited earlier: 4.1 (TC 10:00:00:00 in file; invalid TC message; `1:2:3:4` → `01:02:03:04`); 7 timecode tests. |
| C5 | Filename template, tokens, ` 2`/` 3` instead of overwrite | verified (cited) | Cited: 4.1 (`{name} {preset}` name); 5.2 (`toneD - Cue 2.mxf`, first file unchanged); 5 filename tests. |
| C6 | 1080i50 renders 50 images/s woven into fields; 1080p50 50 frames; clocks on a 25-frame base | verified (cited) | Cited: 2.1 RenderTests (50 Hz odd positions differ from both neighbours); 3.1 (bottom-first weave rejected); 6.1 (3-min 1080i50 at 226 images/s). |
| C7 | 1080p50 shows Experimental note | ⟲ not verified | Re-verify item 8. Cited earlier: 4.1 Atlas pass ("Experimental note on 1080p50"). Whether EVS accepts 1080p50: **externally gated (X2)**. |
| C8 | Partial last frame padded (1920/960 samples); one frame remaining on last frame | verified (cited) | Cited: 3.1 (exact sample counts, padding); 1.3 (25 tests, identity with build 10 clocks for 13 durations). |

## D. Music-end detection

| # | Criterion | Status | Evidence |
|---|---|---|---|
| D1 | Music end (−60 dBFS) and fade start (peak − 40 dB) stored and drawn on both waveforms | verified (cited); thresholds externally gated (X3) | Cited: 2.2 (generated WAV: music end ≈ 8.0 s, fade start ≈ 7.98 s); 3.2 (dashed blue "Fade" and solid yellow "End" on both waveforms). X3 note: on a linear fade, fade start lands within ~0.1 s of music end. |
| D2 | Drag or type a marker; Reset restores | verified (cited) | Cited: 4.1 Atlas pass (drags, `abc` error, Reset). |
| D3 | Countdown target Music end: fades, threshold and Remaining measured to the marker; holds red 00:00:00 after it | ⟲ not verified (on build 11) | Re-verify item 1 (red at music end in the decoded output). Cited: 3.2 CountdownTests; 3.3 exported frame at 9 s shows Fade/End and Remaining 00:00:00 red; 4.2 (Remaining 00:07:23 instead of 00:10:00). |
| D4 | No silent tail → music end = file end, no visible difference | verified (cited) | Cited: 3.2 CountdownTests ("no tail identical for both targets"); 1.2 tests. |
| D5 | Entirely below −60 dBFS → no marker, "No music detected" | verified (cited) | Cited: 4.1 Atlas pass ("No music detected"). |

## E. Loudness, trim and pre-roll

| # | Criterion | Status | Evidence |
|---|---|---|---|
| E1 | Background loudness: I, TP, LRA; badge outside −23 ±1 LUFS or above −1 dBTP | verified (cited) | Cited: 4.1 Atlas pass (matches FFmpeg ebur128 for −22.1, −42.2, −45.9, silent; badge). |
| E2 | Normalise: single linear gain, peak-limited with note; picture unchanged; no dynamics | verified (cited), peak-limited note on screen not verified | Cited: 4.1 (+19.2 dB gain on screen; export at −23.0 LUFS); 1.5 gain-rule tests. 4.1 lists "peak-limited Normalise line on screen" as not checked. |
| E3 | In/Out by drag or I/O keys; clip covers range; clocks/overview/markers trimmed; fades 0–5 s | ⟲ not verified | Re-verify item 7. Cited earlier: 5.1 Atlas pass (I/O → In 2.00 / Out 7.20; bracket drags; fades); export envelopes rising/falling. |
| E4 | Pre-roll 2/3/5/10 s slate; Elapsed starts on first music frame; TC places music at start TC | ⟲ not verified | Re-verify item 7. Cited earlier: 5.1 (slate showed title, "Starts in 00:03:00", duration, loudness; file TC 09:59:57:00, silent slate −91 dB); 4.3 (TC 09:59:58:00 for 2 s). How a 23:59:55:00 start displays on EVS: **externally gated (X2)**. |

## F. Safe zones for server overlays

| # | Criterion | Status | Evidence |
|---|---|---|---|
| F1 | Presets None / EVS OSD / Custom 0–30 % per side, stored in percent | verified (cited) for the control; EVS OSD values **externally gated (X1)** | Cited: 4.2 Atlas pass (EVS OSD and Custom, steppers 0–30). EVS OSD uses provisional 10 % top / 20 % bottom until X1. |
| F2 | No clock, label, title or waveform pixel in reserved bands | verified (cited) | Cited: 2.1 RenderTests (bands contain only background pixels across EVS OSD, Above, asymmetric, 30 % bottom); 4.2 export with Custom 10/30 kept bottom 30 % empty. |
| F3 | Give-way order; "Safe zones leave too little room" disables export | verified (cited) | Cited: 1.4 tests (give-way order); 4.2 Atlas pass (top 30 + bottom 30 → message, Export Selected disabled). |
| F4 | Clock position Below/Above moves clocks as a pair | verified (cited), on screen not verified | Cited: 3.2 tests ("clocks move as a pair"). 4.2: "Clock position Above was set in tests only". |
| F5 | Guides drawn over the monitor only, never in the MXF | ⟲ not verified (tooltip) | Re-verify item 6 (6.3 changed the tooltip). Tooltip text in source: "Draw the safe zones in the preview only. They are never part of the exported file." Not seen on screen in build 11. Cited: 4.2 hatched guides on screen; 3.2 test "guides never in `CuePicture` output". |
| F6 | Safe-zone setting remembered with appearance; in snapshot; copied by Apply to All | verified (cited) | Cited: 3.3 (relaunch kept Custom 10/30 and guides); 4.2 (per job, kept across relaunch); 4.1 Apply to All. |
| F7 | Dragged text clamped to usable area | verified (cited) | Cited: 1.4/2.1 layout and hit-test tests. Not seen on screen. |

## Edge cases

| # | Criterion | Status | Evidence |
|---|---|---|---|
| EC1 | Track shorter than pre-roll or warning: no crash, build 6 clamping | verified (cited) | Cited: 4.3 (0.6 s track with 3 s pre-roll and 10 s warning exports without a crash). |
| EC2 | Trim under 1 s blocked with "Trim range too short" | ⟲ not verified | Re-verify item 7. Cited earlier: 5.1 Atlas pass (In 4 / Out 4.5 → message, Export Selected disabled). |
| EC3 | 50 jobs × 10 min: decoded PCM only for selected and running job | verified (cited) | Cited: 6.1 performance run (50 real jobs, at most 2 CAFs incl. fast selection; racing case fixed under 6.3); 3.3 cap test. |
| EC4 | Not enough free space → fails before encoding with a disk-space message | ⟲ not verified | Re-verify item 9. **No on-screen evidence ever.** `DiskSpace.preflight` is in `MXFJobExporter`. Planned setup (not run): a small disk image attached in the helper with a source on it, so the beside-source output cannot fit. |

## Error states

| # | Criterion | Status | Evidence |
|---|---|---|---|
| ER1 | Encoder failure: last 1,500 chars of the log in a disclosure; queue continues | verified (cited), partially | Cited: 4.1 (Start Queue failed the bad-TC job with its reason and exported the rest). A real encoder-log disclosure was not shown on screen in any pass. |
| ER2 | Decode failure while adding → job added as Failed with reason | ⟲ not verified | Part of re-verify item 1 (folder drop). Cited earlier: 2.3 (`Broken.wav` added as Failed). |
| ER3 | Destination becomes unwritable mid-queue → same-folder jobs paused, operator asked for a new folder | ⟲ not verified | Re-verify item 9 (6.3 changed this). **No on-screen evidence ever** (3.3: "Not exercised on screen: the unwritable-folder pause prompt"). Covered by unit tests only. Planned setup (not run): `chmod a-w` on the helper's fixture folder with a beside-source destination. |

---

## Counts (44 spec criteria, plus the brief's idle-quit check)

- **verified (cited): 25** spec criteria, from earlier builds of this round or the suite at `dada202`. None was re-checked in build 11. Caveats are noted in the rows (E2 peak-limited line, F4 Above, ER1 log disclosure not seen on screen).
- **not verified: 19** spec criteria plus the idle-quit check. These are the ⟲ rows: B1–B6, B8, C1, C2 (build-11 decode), C4, C7, D3, E3, E4, F5, EC2, EC4, ER2 and ER3. All are blocked by the helper, and all are on the brief's re-verify list. **B8 (quit-while-running prompt), the idle quit with no `ffmpeg` left, EC4 (disk-space preflight) and ER3 (unwritable-folder pause) have never been seen on screen in any build.**
- **externally gated: 0 whole criteria.** Parts are gated: X2 for EVS ingest of C2, 4/8-track playback in C3, 1080p50 in C7 and the 23:59:55 display in E4; X1 for the EVS OSD values in F1; X3 for the D1 thresholds.

## Defects found
None. This build was not exercised on screen, so this pass gives no defect evidence either way.

## To finish 6.2
Once the person resumes agents and the MousePlus session's unknown action is recovered (`atlas doctor` → `ready: true`), run `atlas environment` + `apply` on the manifest above, then run the ⟲ rows in this order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9. Collect one app-made 1080i50 4-track MXF for the decode in C2/C4/D3. Afterwards, roll the copy back and run `atlas cleanup --apply`.
