# Batch Queue, Export Presets and Cue Tools Specification

**Status:** Draft
**Created:** 2026-11-27
**Last Updated:** 2026-11-27

---

## Problem Statement

### What problem does this solve?

Waveform Cue makes one MXF cue clip from one music file, in one fixed format (MPEG-2 50 Mb/s 1080p25). An operator who prepares a show needs many cues, in the house format the EVS server already ingests (AVC-Intra 100 in practice), and needs the countdown to warn about the point where the *music* ends, not where the file ends. The smallest worthwhile outcome is: drop a folder of tracks, get a set of AVC-Intra 100 cue clips that ingest on EVS without re-work, each with a reliable music-end warning.

### Who has this problem?

The operator (personal/in-house use) preparing music cues for EVS replay servers before a live production.

### How do they solve it today?

One track at a time: open, adjust, export, repeat. Output is MPEG-2 only, while the operator's other EVS material is AVC-Intra, made with an ffmpeg-only script that ingests fine without BBC bmx. The countdown targets the file end, so a fade ahead of a silent tail is only visible by reading the waveform.

---

## Proposed Solution

### One-Liner

A queue of cue jobs in an App Shell window, each exported through a selectable broadcast preset (AVC-Intra 100 first), with detected music-end and loudness, optional trim, fades and a pre-roll slate.

### Key Capabilities

1. **App Shell migration.** SwiftUI shell per the App Shell Standard: queue sidebar, monitor, appearance inspector, flat toolbar.
2. **Batch queue.** Many tracks become jobs. They export one at a time, with per-job status, progress, cancel and retry, and the queue survives a relaunch.
3. **Export presets.** AVC-Intra 100 at 1080i50, 1080p25 and 1080p50 (experimental), plus the existing MPEG-2 50M. Each preset has selectable 2, 4 or 8 mono audio tracks, a start timecode and a filename template.
4. **Music-end detection.** Detect where the music stops before a silent tail and draw a marker. The countdown and fade to red can target the music end instead of the file end.
5. **Loudness, trim and pre-roll.** EBU R128 readout with optional linear normalisation, in and out points with fades, and an optional lead-in slate.
6. **Safe zones for server overlays.** Reserve top and bottom bands, and optionally one side, where the EVS on-screen display (OSD) draws. The title, waveforms and clocks re-lay out inside the remaining area, so nothing important sits under the server's text.

### User Flow

1. **Source/input:** the operator drops several audio files, or a folder, onto the queue sidebar or the app icon. Supported inputs are any audio the bundled FFmpeg decodes.
2. **User action:** select a job to preview it in the monitor. Adjust its overlay text, position, trim, markers and preset. Optionally press **Apply to All** for appearance and preset. Then press **Start Queue**.
3. **Destination/output:** each job writes `<template>.mxf` into its destination folder. The default is beside its source; a queue-wide override folder is available.
4. **Observable outcome:** every row reads **Done** with a **Show in Finder** button. Opening a file shows the chosen codec, frame layout, track count and start timecode. The red countdown peaks at the marked music end. A failed row shows the encoder's reason and a **Retry** button.

### Feasibility check (run 2026-11-27, bundled FFmpeg 8.1, test signal, scratchpad only)

| Preset | Result | MXF coding label | Body partitions | 20 s encode (M-series) |
|---|---|---|---|---|
| AVC-I 100 1080i50 TFF | Works | `…0401020201323102` (AVCI_100_1080i, same as an EVS-generated reference) | none (single partition) | 4.0 s |
| AVC-I 100 1080p25 | Works | `…323104` (1080/25p) | none | 3.8 s |
| AVC-I 100 1080p50 | Encodes, **mislabelled** (25p label on a 50p stream, about 229 Mb/s) | `…323104` | none | 6.8 s |
| MPEG-2 50M 1080p25 (current) | Works | n/a | **2** | 0.9 s |
| 4 × mono PCM 24-bit | Works (`channelsplit` plus silent `anullsrc` maps) | n/a | n/a | n/a |

Conclusions:
- AVC-Intra 100 needs no BBC bmx. Current FFmpeg writes RP2027 labels and a single body partition, which is the one EVS-specific requirement found.
- 1080p50 stays behind an **Experimental** flag until a file ingests on the operator's EVS.
- MPEG-2's body partitions may be why EVS ingest of the current preset was never confirmed.
- Encoding is well above real time. The app's own frame rendering will be the bottleneck, so measure it before optimising.

**EVS result (2026-11-27):** the 1080i50 AVC-I 100 test file imported and played on the operator's EVS. The gate for section C has passed. The only problem was the OSD overlap, now covered in section F.

**Stop/replan (historical):** if the 1080i50 preset had failed EVS ingest, stop preset work beyond it and compare against the operator's working script's exact arguments before adding more formats. Only then consider bmx (`bmxtranswrap -t op1a` rewrap, P2toMXF bundling recipe).

---

## Acceptance Criteria

### A. App Shell migration

- [ ] Given a fresh launch, when the window opens, then it uses a hidden title bar, the editor toolbar role, dark appearance by default (Light, Dark or Match System available) and the AppShellKit `Theme`. `UIDesignRequiresCompatibility` is true in `Info.plist`.
- [ ] Given the main window, when the operator resizes panes, then queue sidebar | monitor | inspector use `HSplitView`. The inspector hosts the build 8 Appearance sidebar content plus job settings (preset, trim, markers, loudness). The panes have an autosaved layout, and the toolbar toggles each side pane. The toggle state is remembered.
- [ ] Given the toolbar, when it renders, then every button uses the flat toolbar button style: Open/Add, Start or Stop Queue, Export Selected, Show Inspector, Show Queue.
- [ ] Given the migrated app with one track, when the operator plays, scrubs, steps frames (Left Arrow and Right Arrow), drags the overlay text and exports, then all build 6 behaviour is unchanged. The preview and the exported frame are identical for the same settings.
- [ ] Given the monitor, when it is shown, then it is the existing `MonitorView` wrapped in `NSViewRepresentable` with a `@MainActor` coordinator, not re-drawn in SwiftUI.

### B. Batch queue

- [ ] Given an empty queue, when the operator drops 12 audio files or a folder containing them, then 12 jobs appear in drop order. Unsupported files are skipped with a single summary line, and each job's overlay text defaults to its filename without extension.
- [ ] Given a selected job, when the operator edits text, position, trim, markers or preset, then only that job changes. When they choose **Apply to All**, then appearance and preset copy to every *pending* job, never to Done jobs.
- [ ] Given pending jobs, when the operator presses **Start Queue**, then jobs export one at a time in list order. Each row shows Pending, Preparing, Exporting with percentage, Done, Failed or Cancelled. The toolbar shows overall progress, and idle sleep is prevented until the queue ends.
- [ ] Given a running job, when the operator presses **Cancel** on it, then the encoder stops, no partial file is left at the destination, the row reads Cancelled and the queue moves to the next job. **Stop Queue** cancels the current job and leaves the rest Pending.
- [ ] Given a Failed or Cancelled job, when the operator presses **Retry**, then it returns to Pending with a fresh, non-colliding output name.
- [ ] Given a queue with pending and done jobs, when the app quits and relaunches, then the queue is restored. Interrupted jobs return to Pending, and a job whose source file is missing is marked Failed with "Source not found".
- [ ] Given a running queue, when the operator selects another job, then preview playback and editing of non-running jobs still work. The running job's settings are locked.
- [ ] Given the app is running a queue, when the operator quits, then the app asks to stop the queue first (same rule as the current single export).

### C. Export presets

- [ ] Given the preset picker, when opened, then it lists the following presets, and the selected preset shows codec, frame layout, bitrate class and audio layout in the format readout:
  - AVC-Intra 100 · 1080i50
  - AVC-Intra 100 · 1080p25
  - AVC-Intra 100 · 1080p50 (Experimental)
  - MPEG-2 50 Mb/s · 1080p25
- [ ] Given AVC-Intra 100 · 1080i50, when exported, then the file is MXF OP1a with H.264 High 4:2:2 Intra, 10-bit, 1920 × 1080, top field first, the RP2027 1080i label, a single body partition, Rec. 709 tags and 24-bit 48 kHz mono PCM tracks.
- [ ] Given an audio layout of 2, 4 or 8 mono, when exported, then left is on track 1, right on track 2 and the remaining tracks are digital silence, each the full clip length.
- [ ] Given a start timecode field (default 00:00:00:00, accepts HH:MM:SS:FF at 25 fps), when exported, then the MXF's embedded timecode starts at that value.
- [ ] Given a filename template (default `{name} - Cue`, tokens `{name}`, `{preset}`, `{date}`), when exported, then the file uses that stem and adds ` 2`, ` 3` and so on rather than overwriting.
- [ ] Given 1080i50, when rendering, then the picture is drawn at 50 images per second and woven into fields (cursor and clocks move per field). Given 1080p50, it renders 50 frames per second. In both cases the clocks still read MM:SS:FF on a 25-frame base.
- [ ] Given the 1080p50 preset, when the operator selects it, then a note says it is experimental and must be test-ingested on EVS.
- [ ] Given any preset, when the last video frame is partial, then the audio is padded with silence to a whole frame (1920 samples at 25, 960 at 50), and the remaining clock behaviour matches build 6 (one frame remaining on the last frame).

### D. Music-end detection

- [ ] Given a loaded track, when analysis finishes, then the app stores *music end* (last point above −60 dBFS) and *fade start* (last point above −40 dBFS relative to the track's peak). It draws both as markers on the full-track and close-up waveforms.
- [ ] Given detected markers, when the operator drags a marker or types a time, then that job uses the edited value. **Reset** restores the detected value.
- [ ] Given **Countdown target: Music end** in Appearance, when the playhead passes the fade start, the solid-red threshold or the optional waveform fades (`fadeCloseUp`/`fadeFullTrack`), then all are measured to the music-end marker, and Remaining shows time to music end. After the marker, Remaining holds at 00:00:00 in red until the clip ends.
- [ ] Given a track with no silent tail, when analysed, then music end equals the file end and the target setting makes no visible difference.
- [ ] Given a track that is entirely below −60 dBFS, when analysed, then no marker is set and the job shows "No music detected".

### E. Loudness, trim and pre-roll

- [ ] Given a loaded track, when loudness analysis finishes in the background, then the job shows Integrated (LUFS), True peak (dBTP) and Loudness range. A badge marks values outside −23 ±1 LUFS or above −1 dBTP.
- [ ] Given **Normalise to −23 LUFS** on, when exported, then a single linear gain is applied. If that gain would push true peak above −1 dBTP, the gain is reduced to the peak limit and the job notes the achieved loudness. The picture and the waveform scale are unchanged. Dynamic processing is never applied.
- [ ] Given in and out points set by drag or by I and O keys on the playhead, when exported, then the clip covers only that range. Clocks, duration, waveform overview and markers refer to the trimmed range, and optional fade-in and fade-out (0, 0.5, 1, 2 or 5 s) are applied to the audio.
- [ ] Given **Pre-roll** of 2, 3, 5 or 10 s, when exported, then the clip begins with a slate showing title, music duration, loudness and a "Starts in" countdown over silent audio. Elapsed starts at 00:00:00 on the first music frame. The embedded timecode places the music start at the job's start timecode, so the pre-roll starts earlier.

### F. Safe zones for server overlays

Observed on 2026-11-27, on the operator's EVS output with OSD on, while playing the AVC-I test file:
- **Bottom:** a timecode line and a clip line ("312A Rehearsal cu") cover the Elapsed and Remaining clocks.
- **Top:** "\*PLAY\* FULL CTRL" sits in the top band, just above the title.
- **Waveform:** a "Net" status icon appears inside it, right of centre.

- [ ] Given Appearance → **Overlay safe zones**, when opened, then it offers these presets. The bands are stored in percent of picture height, so they hold for every preset resolution:
  - **None**, today's layout.
  - **EVS OSD**, a measured default.
  - **Custom**, with Top, Bottom, Left and Right reserves from 0–30 % in 1 % steps.
- [ ] Given a bottom reserve of N %, when a frame is exported, then no clock, clock label, title or waveform pixel falls inside the bottom N % of the 1920 × 1080 picture. Only the background colour remains there. The same holds for the top, left and right reserves.
- [ ] Given reserves that shrink the usable area, when the layout is computed, then elements give way in this order:
  1. The close-up and full-track waveform heights shrink.
  2. Gaps shrink.
  3. Clocks step down a size (never below Small).
  4. The title shrinks (never below its current minimum, 34 pt).

  If the content still does not fit, Appearance shows "Safe zones leave too little room" and the export button is disabled for that job.
- [ ] Given **Clock position: Below waveforms** (default) or **Above waveforms**, when chosen, then the Elapsed and Remaining clocks move as a pair. The operator can then keep the clocks away from whichever band the server uses for timecode.
- [ ] Given **Show safe-zone guides** in the preview, when on, then the reserved bands are drawn as a hatched tint over the monitor only. Guides never appear in the exported MXF.
- [ ] Given a safe-zone setting, when the app relaunches or a job is queued, then the setting is remembered with the appearance. It is part of the job's appearance snapshot and copied by **Apply to All**.
- [ ] Given the overlay text is dragged to a custom position, when safe zones are on, then its travel is clamped to the usable area.

### Edge cases

- [ ] Given a track shorter than the pre-roll or warning interval, when exported, then nothing crashes and the clamping rules from build 6 apply.
- [ ] Given a trim range under one second, when the operator tries to start the job, then it is blocked with "Trim range too short".
- [ ] Given 50 queued jobs of 10 minutes each, when the queue runs, then decoded PCM exists only for the selected job and the running job (no tens of gigabytes of temp files).
- [ ] Given a destination folder with less free space than the estimated output (about 115 Mb/s for AVC-Intra 100 25, 230 Mb/s for 50p, plus audio), when a job starts, then it fails before encoding with a disk-space message.

### Error states

- [ ] Given an encoder failure, when a job fails, then the row shows the last 1,500 characters of the encoder log in a disclosure. The queue continues with the next job.
- [ ] Given a decode failure while adding, when it happens, then the job is added as Failed with the decoder's reason rather than silently dropped.
- [ ] Given the destination becomes unwritable mid-queue, when a job fails for that reason, then remaining jobs that use the same folder are paused (not failed) and the operator is asked to choose a new folder.

---

## Technical Considerations

### Dependencies

- **Bundled FFmpeg 8.1** (already in `Contents/Helpers`):
  - Uses: `libx264` with `-avcintra-class`, `mpeg2video`, the `mxf` muxer, and the `channelsplit`, `anullsrc`, `ebur128`, `afade` and `volume` filters.
  - It is a GPL build with x264, copied from Magpie. That is fine for personal use; redistribution needs licence review.
- **AppShellKit** from `1-macOS/zPackages` beside this project (`.package(path: "../../zPackages")` from `01_Project/`): Theme, AppAppearance, FlatToolbarButtonStyle, split-view autosave.
- **ProcessKit** (zPackages): optional. It cannot write to a child's stdin, so the raw-frame pipe stays on `Process` and `Pipe` unless ProcessKit gains stdin support. Analysis passes (`ebur128`) can use it.
- **No BBC bmx.** The decision is recorded under Decisions below.
- **XcodeGen** `project.yml` gains the package dependency.

### Architecture Notes

- **Video standard.** Introduce a `VideoStandard` (width, height, `fieldRate`/`frameRate`, interlaced, field order) and replace the hard-coded `AudioTrack.fps = 25`:
  - Picture time stays on a 25-frame clock base for display.
  - Render and encode rate come from the preset.
  - `samplesPerFrame = 48000 / encodeRate`.
  - Interlaced output renders 50 images per second and uses `tinterlace=interleave_top,setfield=tff` with `-flags +ildct+ilme -top 1`.
- **Preset model.** `ExportPreset` (Codable): id, name, codec family, `VideoStandard`, audio track count, experimental flag, `ffmpegArguments(input:audio:timecode:output:)`. Shape it like Penumbra's `ExportTemplate`. Built-in presets only; user-editable presets are out of scope.
  - Verified AVC-I arguments: `-c:v libx264 -avcintra-class 100 -pix_fmt yuv422p10le -colorspace bt709 -color_primaries bt709 -color_trc bt709 [-flags +ildct+ilme -top 1] -c:a pcm_s24le -timecode TC -f mxf`. Pass `-avcintra-class` directly; via `-x264opts` it produces the wrong codec ID.
  - Mono tracks: `channelsplit=channel_layout=stereo[L][R]`, then one `-map` per track. Silent tracks come from `anullsrc=r=48000:cl=mono` and are trimmed to `frames × samplesPerFrame`.
- **Queue.** A `QueueManager` (`@MainActor`, `@Observable`) modelled on Conjoyn's:
  - Job states: pending, preparing, exporting(progress), done, failed(reason), cancelled.
  - Saved to `~/Library/Application Support/Waveform Cue/queue.json` after every change. An unreadable file is copied to a recovery file rather than wiped.
  - A serial processing loop; idle sleep is prevented with `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep)` for the whole batch.
  - Each job stores the source path, its edited settings (label, position, trim, markers, fades, preset, appearance snapshot) and analysis results (peaks summary, markers, loudness), so re-opening needs no re-analysis.
- **Decoded audio lifetime.** `PreparedAudio` (temporary CAF) belongs to a job workspace, created on demand for preview or export and deleted after export or deselection. A recovered job re-decodes from its source. Disk preflight includes the CAF.
- **Export engine.** Keep `MXFExport.run` pure: it takes a job snapshot plus a preset. The current function already takes track, label and appearance, so the queue calls it per job. Write to a hidden temporary file and move it into place, as today.
- **Music end.** Compute it in Swift during the existing `AudioTrack.read` sample pass (no extra FFmpeg pass):
  - Keep the absolute peak before normalising so thresholds are in dBFS.
  - Use the 5 ms buckets already produced for `detailPeaks`. Music end is the last bucket above −60 dBFS. Fade start is the last bucket above (peak − 40 dB).
  - Ignore isolated clicks: a run must stay above the threshold for at least 50 ms.
- **Loudness.** A background FFmpeg pass `-af ebur128=peak=true -f null -` on the decoded CAF, parsing the stderr summary (I, LRA, True peak). Normalisation is `volume=<gain>dB`, with gain = −23 − I, capped by −1 − TP. Do not use `loudnorm`; it can fall back to dynamic processing.
- **Trim and pre-roll in the timeline.** One `ClipTimeline` maps output frames to source time:
  - Pre-roll frames come first, then the trimmed range.
  - The renderer, clocks, markers and audio filter chain (`atrim`, `afade`, `adelay` or `apad`) all read from it, so preview and export cannot drift.
- **Layout from safe zones.** `CuePicture` hard-codes its rectangles today: `wave` at y 742, `detail` at y 361, the clock baseline at 100, the title travel 55 px from the edges, and the margins of 96 px.
  - Replace them with a `CueLayout` computed once per job from `CueAppearance` (zoom, clock sizes, clock position, safe zones).
  - The preview, the export, `MonitorView` hit-testing (seek, scrub, title drag) and the guides all read the same `CueLayout`, so a click still lands on the right frame.
  - Do this before the 50 Hz render work, because both touch `CuePicture.draw`.
- **Rendering cost.** Measure frames per second of `CuePicture.draw` at 1920 × 1080 before parallelising. Encoding is about 5× real time, so rendering will dominate. A 50 Hz render doubles the cost.
- **UI changes follow the UI changes protocol.** The spec fixes layout intent only. Exact control placement is proposed and confirmed during planning.

### Performance

- A 3-minute AVC-I 100 25 cue should export in well under 3 minutes on the build Mac. Record the measured rate in the plan.
- Analysis (decode, peaks, music end) must finish before the job is preview-ready. Loudness may finish later without blocking.
- 50 jobs must not hold more than two decoded CAFs at once.

### Security

- Not sandboxed, as today. Paths are stored as plain paths, with no bookmarks needed outside the sandbox.
- No network.
- Encoder arguments are built as an argument array, never a shell string. Overlay text never reaches FFmpeg because it is drawn by Core Graphics.

### Prerequisites

- **Create a Git repository and push it to origin before implementation.** The project has none, and this is multi-step, risky work across Macs.
- **Baseline is build 10.** It adds a native toolbar (filename, format, Open Audio, Appearance) and moves overlay text and position into the top of the Appearance sidebar. Build 8 already has `SolidRedThreshold` (Last frame or 1 second), `fadeCloseUp`/`fadeFullTrack` and the collapsible AppKit `CueAppearanceSidebar` (318 pt). Section D extends those countdown rules, and section A turns that sidebar into the inspector pane. Re-read `Sources/` before planning.
- **Add a unit-test target** for preset argument building, timecode parsing, `ClipTimeline` mapping, music-end detection on synthetic signals, and queue state transitions and recovery.

---

## Out of Scope

- BBC bmx, AS-11/AS-10, RDD9 and OP-Atom/Avid output.
- AVC-Intra 50, 200 and XAVC-I. Add later as presets if EVS needs them.
- DNxHD, ProRes and H.264 proxy presets. Removed from this round to keep the scope on EVS AVC-I; candidates for the next spec.
- User-defined or editable presets.
- Parallel export of several jobs.
- 720p and 59.94/29.97 standards.
- Watch folders.
- Transparent (alpha) graphics output.
- Hit-point, vocal-in and segue markers beyond music end and fade start. These are noted as a future idea from radio playout tools.
- Audio beeps baked into the countdown.
- Redistribution, signing and notarisation.

---

## Open Questions

| Question | Status | Answer |
|----------|--------|--------|
| Does the operator's EVS ingest AVC-I 100 1080i50 from this FFmpeg without errors? (Gate for presets.) | Resolved 2026-11-27 | **Yes.** A 1080i50 AVC-I 100 file with 4 mono tracks (converted from a build 2 MPEG-2 cue) imported and played. EVS OSD overlap found; see section F. |
| What are the exact EVS OSD band sizes on the operator's outputs (top line, bottom two lines, status icons) and do they differ per output or multiviewer? | Open | Estimated from a phone photo: bottom 17–20 %, top 8–10 %. Measure from a straight-on still or a grab of the OSD on a plain background, then set the EVS OSD preset. |
| Should the operator simply switch off OSD on the cue output in the EVS setup instead? | Open | Safe zones still help where OSD must stay on (multiviewer, operator monitor) |
| Did all four mono tracks appear and play correctly on EVS? | Open | Not reported yet |
| Does EVS accept 1080p50 AVC-I with FFmpeg's 25p coding label, or should 1080p50 be dropped or replaced (e.g. DNxHD)? | Open | Experimental until tested |
| What exact arguments does the operator's working AVC-I script use (track count, timecode, `-top`, clip naming)? Match them as the default. | Resolved 2026-11-27 | Script not available on this Mac. Defaults follow the locally verified arguments and the VRT AVC-I 100 spec: top field first, mono 24-bit tracks, single partition. The EVS ingest test confirms them. |
| Default start timecode: 00:00:00:00 (as today) or 10:00:00:00? With pre-roll and 00:00:00:00, the slate would start at 23:59:55:00. Is that acceptable, or should the pre-roll start at the start timecode instead? | Open | Spec default 00:00:00:00, music at start TC |
| Does EVS read an MXF clip name or material-package name, or only the filename? | Open | Filename template assumed |
| Should Apply to All also copy trim and fades, or only appearance and preset? | Open | Spec: appearance and preset only |
| Is −60 / −40 dBFS right for the operator's library? | Open | Check on 5 real tracks with fades and reverb tails |
| With pre-roll, should Remaining show music remaining during the slate or the full clip remaining? | Open | Spec: slate shows "Starts in"; clocks start at the first music frame |
| Is the MPEG-2 preset still needed if AVC-I works? Its 2 body partitions may block EVS ingest. | Open | Keep it, labelled as the legacy preset |
| Is FFmpeg's PCM wrapping (WAVE vs AES3) an issue for EVS? | Open | Covered by the ingest test |

---

## Decisions

- **2026-11-27 · No BBC bmx.** The operator's FFmpeg-only AVC-I script already ingests on EVS. The local test confirmed FFmpeg 8.1 writes the RP2027 AVC-I label and a single body partition. Revisit only if the EVS ingest test fails.
- **2026-11-27 · Migrate to the App Shell Standard** as part of the queue work. A queue sidebar needs split panes anyway.

---

## Related

- Backlog: [TASKS.md](../TASKS.md). The EVS ingest check gates section C.
- Session: [2026-11-27](../sessions/2026-11-27.md)
- Reference designs:
  - Conjoyn `Services/QueueManager*.swift` and `Models/ConversionJob.swift` (queue)
  - Penumbra `Models/ExportTemplate.swift` (presets)
  - P2toMXF `Services/BundledToolResolver.swift` (only if bmx returns)
- Directions:
  - `47_project-ui-conventions.md` and `cookbook/00-app-shell.md` (shell)
  - `36_ui-changes-protocol.md` (UI placement)
  - cookbook 12 (activity progress), 29 (disk-space preflight), 85 (FFmpeg watchdog), 122 (tolerant Codable migration), 154 (cancel the producer), 177 (progress coalescing)
- Research sources:
  - EVS reference AVC-I file and single-partition requirement: https://ffmpeg.org/pipermail/ffmpeg-user/2017-February/035139.html
  - VRT AVC-Intra 100 delivery spec (mono tracks, TFF, single partition): https://vrt.be/nl/assets/files/2024-09/Gouden_standaard_AS-VRT-AVC-intra_100-Core_v1_0.pdf
  - EBU R128 s1 (short-form): https://tech.ebu.ch/docs/r/r128s1.pdf
