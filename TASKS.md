# Waveform Cue tasks

## Active plan

[Cue appearance and playhead plan](specs/cue-appearance-and-playhead-plan.md) is selected. Wave 5 task 5.1 is ready for five-song acceptance and the build 12 Release candidate. The [build 11 acceptance plan](IMPLEMENTATION_PLAN.md) retains its separate 6.2 and 6.4 work.

## Backlog

- Build 11 toolbar, reported during a five-job export: the queue divider crosses the trailing edge of Add Audio, and a long filename truncates the combined filename and format readout. Check both at narrow queue widths and preserve readable format information when the filename is long.
- Next zoom round: offer a fixed centre playhead for the close-up in preview and export. Scroll the waveform beneath it, with empty space before the clip or trim start and after its end. Keep the existing edge behaviour as an option. Check short clips, scrubbing and the planned zoom near end. → plan tasks 1.2 and 3.1.
- Compare the reclaimed clock gap on the operator’s EVS at 11%/11% and 11%/16% once the two exports are ready. Layout implementation is complete in task 2.2. → check E1.
- Verify a sample export on the operator's EVS ingest configuration. On 2026-11-27 an AVC-I 100 1080i50 conversion imported and played. The app's own MPEG-2 export is still untested, and the EVS OSD covers the clocks (spec section F). Tracked as plan gate X2.
- Measure the EVS OSD bands from a straight-on still of the cue output, for the spec's EVS OSD safe-zone preset (plan gate X1).

## Inbox

- EVS clip 413A, build 11, 1080i50, countdown to file end. Three of five photos show matching Elapsed and Remaining. In two, EVS shows a dot after 00:00:00:00 and Remaining 00:24:18 while the burned-in Remaining reads 00:24:19. Check consecutive fields at the head and tail before changing the clock rule.
- 2026-11-27: The `{preset}` filename token writes the preset's display name, so files get “·” and, for 1080p50, “(Experimental)”, e.g. `toneA AVC-Intra 100 · 1080p25.mxf` (Atlas pass, task 4.1). Decide whether file names need an ASCII preset label for EVS and other tools.
- 2026-11-27: On a Pending job returned by re-export or Retry, the Job tab's “File:” preview shows the template name, while the queue row writes the reserved name (for example `… 2.mxf`) (Atlas pass, task 5.2). Decide whether the preview should show the reserved name.
- 2026-11-27: With Normalise on, the slate's loudness line shows the source loudness (−42.2 LUFS) rather than the level after the export gain (−23) (Atlas pass, task 5.1). Decide which the operator should see.
- 2026-11-27: `QueueManager.persist()` re-encodes all of `queue.json` on the main actor after every change, including each job's 5 ms `detailPeaks` (about 640 KB per 10-minute track; roughly 32 MB for 50 such jobs). This risks UI stalls on large queues (task 6.3 review). Measure before changing anything.
