# Waveform Cue tasks

## Active plan

[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md). First ready: 0.2, then 0.3 (0.1 is done). The plan owns task status and evidence.

## Backlog

- Verify a sample export on the operator's EVS ingest configuration. On 2026-11-27 an AVC-I 100 1080i50 conversion imported and played. The app's own MPEG-2 export is still untested, and the EVS OSD covers the clocks (spec section F). Tracked as plan gate X2.
- Measure the EVS OSD bands from a straight-on still of the cue output, for the spec's EVS OSD safe-zone preset (plan gate X1).
- **Next plan, after the current one finishes: fonts and feature checkboxes** (requested 2026-11-27; kept out of the active plan while it runs).
  - Font selection: separate menus for the title and the clocks, listing installed fonts. Clocks need equal-width digits so they don't jitter. A missing saved font falls back to today's (Helvetica Neue Medium for the title, Menlo for the clocks).
  - On/off checkboxes for every feature (music-end markers, loudness check, normalisation, trim and fades, pre-roll, safe zones, safe-zone guides) and every picture element (full-track waveform, close-up, elapsed clock, remaining clock, title).
  - Settings work at two levels: app-wide defaults, which new jobs start with, and per-job overrides with a marker and Reset. Apply to All copies to jobs not yet run; Save as Default updates the defaults. Optional switch "Same settings for all jobs". Done jobs never change.
  - Build 10 settings load unchanged. With every setting at its build 10 value, the export is identical to build 10.
  - Zoom in near the end (requested 2026-11-27): optional, off by default, zoom in only. The close-up narrows to a final window (for example 10 s → 3 s) with an eased transition of about 1 s, measured to the music end when the countdown target is Music end, otherwise to the file end. It depends only on the frame, so every frame still reads on its own when jogged. The highlight box on the full track shrinks with it.
  - Research for all of the above: [NEXT_PLAN_RESEARCH.md](NEXT_PLAN_RESEARCH.md).
