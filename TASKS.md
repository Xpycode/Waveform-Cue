# Waveform Cue tasks

## Active plan

[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md). Progress 21/25; next Wave 6. The plan owns task status and evidence.

## Backlog

- Verify a sample export on the operator's EVS ingest configuration. On 2026-11-27 an AVC-I 100 1080i50 conversion imported and played. The app's own MPEG-2 export is still untested, and the EVS OSD covers the clocks (spec section F). Tracked as plan gate X2.
- Measure the EVS OSD bands from a straight-on still of the cue output, for the spec's EVS OSD safe-zone preset (plan gate X1).

## Inbox

- 2026-11-27: The `{preset}` filename token writes the preset's display name, so files get “·” and, for 1080p50, “(Experimental)”, e.g. `toneA AVC-Intra 100 · 1080p25.mxf` (Atlas pass, task 4.1). Decide whether file names need an ASCII preset label for EVS and other tools.
- 2026-11-27: On a Pending job returned by re-export or Retry, the Job tab's “File:” preview shows the template name, while the queue row writes the reserved name (for example `… 2.mxf`) (Atlas pass, task 5.2). Decide whether the preview should show the reserved name.
- 2026-11-27: With Normalise on, the slate's loudness line shows the source loudness (−42.2 LUFS) rather than the level after the export gain (−23) (Atlas pass, task 5.1). Decide which the operator should see.
- 2026-11-27: `QueueManager.persist()` re-encodes all of `queue.json` on the main actor after every change, including each job's 5 ms `detailPeaks` (about 640 KB per 10-minute track; roughly 32 MB for 50 such jobs). This risks UI stalls on large queues (task 6.3 review). Measure before changing anything.
