# Waveform Cue

Last updated: 2026-11-28

## Now

Build 14 is in `04_Exports/0.1-14` on the M1 Max and running on the desktop; the operator approved the dimmed played audio. The End line now sits on the frame grid (in source, tested, not built yet). Next session: the operator's new visual wishes, then build 15 with the End-line snap. Operator items: X2 details, X3 thresholds, X4 questions and the decisions in [TASKS.md](TASKS.md). See the [current handoff](sessions/2026-11-28.md#resume-2).

**Execution:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- End line drawn on the frame grid, so it meets the playhead and the zero on the clock (not built yet).
- Build 14: "Dim played audio in close-up" (on by default), the red warning swapping with it. Checked in the Atlas helper; 252 tests pass.
- Build 13: close-up centred to both ends with "Center playhead at start/end" toggles (on by default); toolbar as one solid band, pane toggles at the edges and actions in the centre. Checked in the Atlas helper; 249 tests pass.
- Build 12: EVS OSD safe zones set to the operator's measurement (gate X1); toolbar glass capsules hidden as in Penumbra, restoring spec A3 on the macOS 27 SDK. Checked in the Atlas helper.
- Operator confirmed that build 11 AVC-Intra exports ingest and play on EVS (gate X2, partly).
