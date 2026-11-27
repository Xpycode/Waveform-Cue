# Waveform Cue

Last updated: 2026-11-27

## Now

Building the batch, preset and cue tools round from [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Build 10 in `04_Exports/0.1-10` is still the last handoff candidate. See the [current handoff](sessions/2026-11-27.md#resume-after-execution-waves-04).

**Execution:** 18/25 tasks done (Waves 0–3, 4.2, 4.3). 4.1 (Job tab) was in flight in a worktree at close; then 5.1, 5.2 and Wave 6. Gates X1–X4 open; U1 approved.

## Recent

- Built Waves 0–4: CueCore package with 227 tests, App Shell window, batch queue with restore, AVC-Intra 100 presets, music-end markers, safe zones, slate and trim engine. Verified on screen in the Atlas helper.
- Planned the batch, preset and cue tools round. Planning research confirmed the AVC-Intra arguments and found that `-top 1` is deprecated and that 1080p50 cannot be labelled correctly by FFmpeg.
- An AVC-Intra 100 1080i50 test file imported and played on EVS. The server's on-screen text covers the clocks, so safe zones were added to the spec.
- Moved overlay text and positioning to the Appearance sidebar, accessible from the window toolbar.
- Researched and specified the next round: batch queue, AVC-Intra 100 presets, music-end detection, loudness and trim.
