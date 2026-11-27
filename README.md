# Waveform Cue

A Mac app that turns music files into MXF cue clips for a replay server such as EVS. Each clip shows the whole-track waveform, a close-up that follows the playhead, Elapsed and Remaining clocks, and a title. Every frame can be read on its own while jogging. Tracks go into a queue and export one at a time.

## Use

1. **Add tracks.** Drop audio files or a folder on the queue sidebar or the app icon, or choose **File → Add Audio…** (Command-O). Each track becomes a job in drop order. A folder adds the audio inside it, sorted by name. Finder aliases are followed. Files that are not audio are skipped and counted in the status bar, and a file that cannot be decoded is added as Failed with the decoder's reason.
2. **Preview a job.** Select it in the queue. Press **Space** to play or pause, click or drag across a waveform to cue, and use **Left Arrow** and **Right Arrow** to step one frame.
3. **Set it up in the inspector.** The **Job** tab holds the export settings, markers, loudness and trim. The **Appearance** tab holds the title, clocks, waveforms, end warning and safe zones. **Apply to All** copies the selected job's appearance and preset to every Pending job.
4. **Export.** **Start Queue** (Command-Return) exports every Pending job in list order. **Export Selected** (Command-E) exports only the selected job; on a Done job it exports again under a new name. Each row shows Pending, Preparing, Exporting with a percentage, Done with **Show in Finder**, Failed with the encoder log, or Cancelled. **Cancel** stops a job and leaves no partial file. **Retry** returns a Failed or Cancelled job to Pending.

The queue is saved as you go and restored at the next launch. A job that was exporting when the app quit returns to Pending. Quitting while the queue runs asks first. Settings of a job that is exporting are locked.

**Destination.** Each job writes beside its source by default. The **Destination** pop-up under the queue sets one folder for the whole queue instead. **File → Export Selected to Folder…** picks a folder for one job. An existing file is never overwritten: the name gains " 2", " 3" and so on.

### Job tab

- **Preset**: AVC-Intra 100 · 1080i50 (default), AVC-Intra 100 · 1080p25, AVC-Intra 100 · 1080p50 (Experimental), and the legacy MPEG-2 50 Mb/s · 1080p25. The line below shows codec, frame layout, bitrate class and audio layout.
- **Audio tracks**: 2, 4 or 8 mono tracks. Left is track 1, right is track 2, and the rest are digital silence.
- **Start TC**: the embedded start timecode, HH:MM:SS:FF at 25 fps (default 00:00:00:00). The music starts on this timecode; a pre-roll starts earlier.
- **Filename**: a template with `{name}`, `{preset}` and `{date}` (default `{name} - Cue`).
- **Markers**: **Music end** is the last point above −60 dBFS before a silent tail, and **Fade start** is the last point above −40 dBFS below the peak. Drag a marker in the monitor or type seconds or M:SS.ff; **Reset** restores the detected value. A track that never rises above −60 dBFS shows "No music detected".
- **Loudness**: Integrated (LUFS), True peak (dBTP) and Loudness range, measured in the background with FFmpeg's EBU R 128 meter. A badge flags values outside −23 ±1 LUFS or above −1 dBTP. **Normalise to −23 LUFS** applies one linear gain on export, reduced if it would push the true peak above −1 dBTP. Loudness is measured on the whole source file, not the trimmed clip.
- **Trim**: **In** and **Out** points (type them, press **I** or **O** at the playhead, or drag the brackets beside the waveform), **Fade in** and **Fade out** (0.5 to 5 s), and **Pre-roll** (2, 3, 5 or 10 s). Pre-roll adds a lead-in slate with title, music duration, loudness and a "Starts in" countdown. A trim range under one second blocks the export with "Trim range too short".

### Appearance tab

- **Overlay text** and **Position**, or drag the text in the monitor.
- **Clocks**: size and colour for Elapsed and Remaining, and **Clock position** (below or above the waveforms).
- **Waveforms**: colours for the full track and the close-up, and the close-up **Zoom window** (Auto, 2 to 60 s, or Off for one enlarged full-track waveform).
- **End warning**: **Fade to red** over the last 5 or 10 seconds, **Solid red at** the last frame or the last second, optional red fades for the close-up and full-track waveforms, and **Countdown to** File end or Music end.
- **Overlay safe zones**: None, EVS OSD (provisional 10 % top and 20 % bottom bands, to be measured on the server) or Custom, so the server's on-screen display does not cover the clocks or title. Elements give way in a fixed order: waveforms shrink, then gaps, then clocks step down a size, then the title. **Show safe-zone guides** hatches the reserved bands in the monitor only; guides never appear in an export.

The clocks read minutes, seconds and frames at 25 fps on every preset. The first frame shows zero elapsed and the full clip duration remaining; the last frame shows one frame remaining.

## Output

MXF OP1a. The AVC-Intra 100 presets write H.264 High 4:2:2 Intra, 10-bit, 1920 × 1080, Rec. 709 video range, with 1080i50 top field first and drawn at 50 images per second, so the playhead and clocks move each field. Audio is 2, 4 or 8 mono tracks of 24-bit PCM at 48 kHz. A partial last frame is padded with silence. FFmpeg labels 1080p50 as 25p, which is why that preset is marked Experimental until it is test-ingested on EVS. The MPEG-2 preset keeps build 10's video format (50 Mb/s CBR Long GOP, 8-bit 4:2:2); its audio follows the selected track layout like the other presets.

Import decodes the first audio stream of each track to temporary PCM with the bundled FFmpeg. Preview, analysis and export all use that audio, and at most two decoded tracks (the selected and the running job) exist at once. The source file is never changed.

## Build

Requires macOS 14 or later and Apple silicon. The Xcode project is in `01_Project/`; `01_Project/project.yml` is its XcodeGen definition, so run `xcodegen generate` in `01_Project` after changing it, then open `WaveformCue.xcodeproj` and build the WaveformCue scheme. The app uses the house packages `AppShellKit` and `ProcessKit` from `zPackages`, which sits beside this project's folder.

The build phase `01_Project/Scripts/bundle-ffmpeg.sh` copies a self-contained FFmpeg into the app. On this Mac it uses the copy supplied with Magpie. Elsewhere, set the build setting `FFMPEG_EXECUTABLE` to a self-contained macOS FFmpeg with the needed decoders, the libx264 and MPEG-2 encoders, PCM, CAF and MXF. The finished app does not need Magpie. Builds are signed ad hoc for local testing.

Models, rendering, analysis and export live in the `CueCore` package, so the tests run headlessly:

```sh
FFMPEG_EXECUTABLE=/path/to/ffmpeg swift test --package-path 01_Project/Packages/CueCore
```

Add `CUE_BENCH=1` to run the benchmarks, including a 3-minute AVC-Intra export at 1080p25 and 1080i50. Project documentation is in `docs/`.
