# Waveform Cue

Last updated: 2026-11-28

## Now

Build 17 is in `04_Exports/0.1-17` on the M1 Max and running on the desktop: the Fade and End tags no longer cover each other at the end of the full track (not yet checked on screen). Build 16's Apply to All change (also Cancelled, Failed and Paused jobs) is operator-confirmed. Next: `/execute` the Appearance panes plan from Wave 0 (the control placement, gate PU1, is approved); and feedback on build 17. The plan for the approved spec [appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md) is written: 13 tasks in five waves, starting with the build 17 reference data and the grip-drag spike. Operator items: X2 details, X3 thresholds, X4 questions and the decisions in [TASKS.md](TASKS.md). See the [current handoff](sessions/2026-11-28.md#resume-6).

**Execution:** selected plan [IMPLEMENTATION_PLAN-appearance-panes.md](IMPLEMENTATION_PLAN-appearance-panes.md), 0/13 tasks; funnel: plan gate passed, ready for build. Ready, execution not yet requested: Wave 0 (P0.1 then P0.2, no prerequisites), then Wave 1 (P1.1, P1.2, P1.3). PU1 (control placement) approved 2026-11-28. External gates open: PX1 (operator acceptance of build 18), PX2 (VoiceOver), PX3 (picture hashes on the M4 Pro).

**Earlier plan:** [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) 26/26 tasks done. X1 passed; X2 partly passed (AVC-Intra exports ingest on EVS); X3 and X4 open.

## Recent

- Plan written for the Appearance tab redesign and its control placement approved (no code yet). Planning found that the spec's Offset number format would reject a typed "12" (the plan uses its own parser), and that all 24 pane orders fit without safe zones by arithmetic.
- Spec approved for the Appearance tab redesign: one pane per picture element, pane order sets the picture order, a per-pane Offset, the title in its own band, clocks swappable. No code yet.
- Build 17: the Fade and End tags at the end of the full track no longer cover each other (in the viewer and the export); 259 tests.
- Build 16: Apply to All also changes Cancelled, Failed and Paused jobs, never Done or exporting ones; operator confirmed.
- Build 15: Apply to All copies look, title position and export settings (Normalise included) from a footer under both tabs; queue rows show settings, a tick for jobs matching the selection, and one icon button on hover. Atlas-checked; 255 tests.
