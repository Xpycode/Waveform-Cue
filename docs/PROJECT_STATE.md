# Waveform Cue

Last updated: 2026-11-28

## Now

Build 17 is in `04_Exports/0.1-17` on the M1 Max and running on the desktop: the Fade and End tags no longer cover each other at the end of the full track (not yet checked on screen). Build 16's Apply to All change (also Cancelled, Failed and Paused jobs) is operator-confirmed. Next: feedback on build 17, and `/make-plan` for the approved spec [appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md) (Appearance tab as one pane per picture element; pane order is picture order; per-pane Offset; title in its own band). Operator items: X2 details, X3 thresholds, X4 questions and the decisions in [TASKS.md](TASKS.md). See the [current handoff](sessions/2026-11-28.md#resume-5).

**Execution:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- Spec approved for the Appearance tab redesign: one pane per picture element, pane order sets the picture order, a per-pane Offset, the title in its own band, clocks swappable. No code yet.
- Build 17: the Fade and End tags at the end of the full track no longer cover each other (in the viewer and the export); 259 tests.
- Build 16: Apply to All also changes Cancelled, Failed and Paused jobs, never Done or exporting ones; operator confirmed.
- Build 15: Apply to All copies look, title position and export settings (Normalise included) from a footer under both tabs; queue rows show settings, a tick for jobs matching the selection, and one icon button on hover. Atlas-checked; 255 tests.
- End line drawn on the frame grid, so it meets the playhead and the zero on the clock (in build 15; not checked on screen).
