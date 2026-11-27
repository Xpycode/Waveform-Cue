# Waveform Cue

Last updated: 2026-11-27

## Now

Build 10 is the local testing candidate. Its native MPEG-2 export still needs an ingest test on the operator’s EVS. See the [current handoff](sessions/2026-11-27.md#resume-after-build-10).

Next feature round is specified in [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md) and planned in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md): 24 tasks in 7 waves. Funnel: plan complete, ready for build.

**Execution:** not yet requested. Task 0.1 is done: the repository is at https://github.com/Xpycode/Waveform-Cue (public). Next ready are 0.2 (`CueCore` package and baseline tests) and 0.3 (shared types), run serially. Gate U1 (control placement) blocks the tasks that add controls: 2.3, 4.1, 4.2, 5.1.

## Recent

- Researched a Windows version: [specs/windows-version-research.md](specs/windows-version-research.md). Recommends a separate C#/.NET app (Avalonia, SkiaSharp, Velopack). No decision recorded, nothing built.
- Planned the batch, preset and cue tools round. Planning research confirmed the AVC-Intra arguments and found that `-top 1` is deprecated and that 1080p50 cannot be labelled correctly by FFmpeg.
- An AVC-Intra 100 1080i50 test file imported and played on EVS. The server's on-screen text covers the clocks, so safe zones were added to the spec.
- Moved overlay text and positioning to the Appearance sidebar, accessible from the window toolbar.
- Researched and specified the next round: batch queue, AVC-Intra 100 presets, music-end detection, loudness and trim.
- The preview now outlines the entire 16:9 video frame with Appearance open or closed.
- Moved Appearance into a collapsible right sidebar and added a separate close-up waveform warning. Verified preview and MXF with only the close-up selected.
