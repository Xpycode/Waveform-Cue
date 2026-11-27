# Waveform Cue tasks

## Active plan

[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md). First ready: 0.2, then 0.3 (0.1 is done). The plan owns task status and evidence.

## Backlog

- Verify a sample export on the operator's EVS ingest configuration. On 2026-11-27 an AVC-I 100 1080i50 conversion imported and played. The app's own MPEG-2 export is still untested, and the EVS OSD covers the clocks (spec section F). Tracked as plan gate X2.
- Measure the EVS OSD bands from a straight-on still of the cue output, for the spec's EVS OSD safe-zone preset (plan gate X1).

## Inbox

- 2026-11-27: Retry gives `Track 01 - Cue 2.mxf` after a cancelled attempt that left no file (Atlas pass, task 2.3). Spec B says "a fresh, non-colliding output name"; decide whether "fresh" should only mean non-colliding with existing files.
- 2026-11-27: Export Selected on a Done job only beeps; `QueueManager` cannot re-queue a Done job. Decide whether re-export is wanted.
