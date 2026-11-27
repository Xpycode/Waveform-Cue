# Waveform Cue

Last updated: 2026-11-27

## Now

Building the batch, preset and cue tools round from [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). Build 10 in `04_Exports/0.1-10` is still the last handoff; the build 11 candidate is in `04_Exports/0.1-11-rc`, awaiting acceptance. See the [current handoff](sessions/2026-11-27.md#resume-after-wave-6-block).

**Execution:** 23/25 tasks done (Waves 0–5, 6.1, 6.3). Blocked: 6.2, the Atlas acceptance pass. The helper is stuck on another session's action (operator must recover it). 6.4 (build 11) waits on 6.2. Gates X1–X4 open.

## Recent

- Wave 6 so far: all 247 tests pass with nothing skipped, 3-minute cues export in under 45 s, and a review led to six fixes (temp-file cleanup, quitting, paused progress, the decoded-audio limit). The on-screen acceptance pass is waiting for the Atlas helper.
- Finished Wave 5: the Job tab, trim/fade/pre-roll controls with I and O keys, and safe Retry and re-export naming, all checked on screen with real exports.
- Built Waves 0–4: CueCore package with 227 tests, App Shell window, batch queue with restore, AVC-Intra 100 presets, music-end markers, safe zones, slate and trim engine. Verified on screen in the Atlas helper.
- Planned the batch, preset and cue tools round. Planning research confirmed the AVC-Intra arguments and found that `-top 1` is deprecated and that 1080p50 cannot be labelled correctly by FFmpeg.
- An AVC-Intra 100 1080i50 test file imported and played on EVS. The server's on-screen text covers the clocks, so safe zones were added to the spec.
