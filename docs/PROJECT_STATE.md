# Waveform Cue

Last updated: 2026-11-28

## Now

Build 13 is in `04_Exports/0.1-13` on the M1 Max and running on the desktop: close-up playhead centred from the first to the last frame (two toggles), and a solid toolbar band with the actions centred. Build 12 brought the measured EVS safe zones (8 % top, 17 % bottom). Next: the operator checks the −60/−40 dB thresholds (X3), answers the open questions (X4) and the decisions in [TASKS.md](TASKS.md).

**Execution:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- Build 13: close-up centred to both ends with "Center playhead at start/end" toggles (on by default); toolbar as one solid band, pane toggles at the edges and actions in the centre. Checked in the Atlas helper; 249 tests pass.
- Build 12: EVS OSD safe zones set to the operator's measurement (gate X1); toolbar glass capsules hidden as in Penumbra, restoring spec A3 on the macOS 27 SDK. Checked in the Atlas helper.
- Operator confirmed that build 11 AVC-Intra exports ingest and play on EVS (gate X2, partly).
- Finished Wave 6: moved to the Directions folder layout, fixed 13 review findings, passed the on-screen acceptance check, and built build 11 with EVS test files.
- Finished Wave 5: the Job tab, trim/fade/pre-roll controls with I and O keys, and safe Retry and re-export naming, all checked on screen with real exports.
- Built Waves 0–4: CueCore package, App Shell window, batch queue with restore, AVC-Intra 100 presets, music-end markers, safe zones, slate and trim engine.
