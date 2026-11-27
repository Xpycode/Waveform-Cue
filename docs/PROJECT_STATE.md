# Waveform Cue

Last updated: 2026-11-28

## Now

Build 11 of the batch, preset and cue tools round is ready in `04_Exports/0.1-11` on the M1 Max, with EVS sample files beside it. Waiting on the operator's EVS ingest test (gate X2) and the decisions in [TASKS.md](TASKS.md). See the [current handoff](sessions/2026-11-28.md#resume).

**Execution:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done; awaiting acceptance on gates X1–X4 (EVS measurements and ingest, threshold check, open questions). Spec A3 (flat toolbar) is not met on the macOS 27 SDK.

## Recent

- Finished Wave 6: moved to the Directions folder layout, fixed 13 review findings, passed the on-screen acceptance check, and built build 11 with EVS test files.
- Finished Wave 5: the Job tab, trim/fade/pre-roll controls with I and O keys, and safe Retry and re-export naming, all checked on screen with real exports.
- Built Waves 0–4: CueCore package with 227 tests, App Shell window, batch queue with restore, AVC-Intra 100 presets, music-end markers, safe zones, slate and trim engine. Verified on screen in the Atlas helper.
- Planned the batch, preset and cue tools round. Planning research confirmed the AVC-Intra arguments and found that `-top 1` is deprecated and that 1080p50 cannot be labelled correctly by FFmpeg.
- An AVC-Intra 100 1080i50 test file imported and played on EVS. The server's on-screen text covers the clocks, so safe zones were added to the spec.
