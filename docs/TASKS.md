# Waveform Cue tasks

## Active plan

[IMPLEMENTATION_PLAN-appearance-panes.md](IMPLEMENTATION_PLAN-appearance-panes.md) for [specs/appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md). Progress 9/13. Wave 4 starts with P4.1, comparing the viewer against an exported frame and checking render performance. The control placement (PU1) was approved on 2026-11-28. The plan owns task status and evidence. It carries two inbox items of 2026-11-28: swappable positions (the whole plan) and the Color column drift (task P2.2, spec A).

Earlier plan, still open on external gates: [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for [specs/batch-presets-cue-tools.md](specs/batch-presets-cue-tools.md). Progress 26/26; all tasks done. X1 passed, X2 partly passed; X2–X4 still open. The plan owns task status and evidence.

## Backlog

- Finish the EVS ingest check (plan gate X2). On 2026-11-28 the operator confirmed that build 11 AVC-Intra exports ingest and play. Still unreported: 8 mono tracks and channel order, 1080p50 Experimental, the 23:59:55:00 pre-roll start, and the MPEG-2 preset.
- Sweep hidden `.waveform-cue-<UUID>.mxf` temporaries left beside a destination after a crash or power loss during export; they are invisible in Finder and count against the next disk-space check (review 6.3, pre-existing since build 10). The decoded-audio folders in `$TMPDIR` are swept at launch since 6.3.
- Make the monitor accept the same drops as the queue sidebar: today it takes exactly one item and none while the selected job is running (review 6.3).

## Inbox

- Check consecutive fields at the head and tail of EVS clip 413A. In two of five build 11 photos, EVS showed a field dot and Remaining 00:24:18 while the burned-in clock read 00:24:19. The other three matched.
- On a large queue, measure the cost of encoding waveform peaks on the main actor during a queue save. A ten-minute track carries about 640 KB of detail peaks.
- Recheck the build 11 toolbar report at narrow queue widths with a long filename after the build 13 toolbar changes.

- 2026-11-27: The `{preset}` filename token writes the preset's display name, so files get “·” and, for 1080p50, “(Experimental)”, e.g. `toneA AVC-Intra 100 · 1080p25.mxf` (Atlas pass, task 4.1). Decide whether file names need an ASCII preset label for EVS and other tools.
- 2026-11-27: On a Pending job returned by re-export or Retry, the Job tab's “File:” preview shows the template name, while the queue row writes the reserved name (for example `… 2.mxf`) (Atlas pass, task 5.2). Decide whether the preview should show the reserved name.
- 2026-11-27: With Normalise on, the slate's loudness line shows the source loudness (−42.2 LUFS) rather than the level after the export gain (−23) (Atlas pass, task 5.1). Decide which the operator should see.
- 2026-11-27: Loudness, and so the Normalise gain, is measured on the whole untrimmed source. Trim and fades change the clip's real level: a −26 LUFS track whose quiet first minute is trimmed gets +3 dB and lands near −21 LUFS while the slate reads −23.0 (review 6.3, `MXFExport.Snapshot.clipLoudness`, `Loudness.swift`). Decide whether to measure the trimmed clip (one more FFmpeg pass per export) or label the value as source loudness. Goes with the slate loudness item above.
- 2026-11-28: The quit prompt ("The queue is exporting. Stop the queue and quit?") stays up after the queue finishes on its own (task 6.2, shot 07). It should close or change to a plain quit.
- 2026-11-28: A queue row's Cancel reported an Accessibility press without cancelling; a pointer click worked (task 6.2). Possibly a reused table cell. Check with VoiceOver before treating it as a bug.
- 2026-11-28: The Appearance tab's Clock rows put their Color column a little left of the Waveform rows' on some jobs (build 15 screenshot, job 4 selected). Not investigated; check in the Atlas helper. Planned as part of task P2.2 in [IMPLEMENTATION_PLAN-appearance-panes.md](IMPLEMENTATION_PLAN-appearance-panes.md) (one shared colour column).
- 2026-11-28: **Swappable positions: spec approved**, [specs/appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md). One pane per picture element in the Appearance tab, pane order is picture order (grip drag, or Move Up and Move Down), a per-pane Offset stepper, the title in its own band (Left, Center or Right), Elapsed and Remaining swappable. The operator confirmed every choice, the four defaults included. **Planned 2026-11-28:** [IMPLEMENTATION_PLAN-appearance-panes.md](IMPLEMENTATION_PLAN-appearance-panes.md); the grip-drag feasibility check is task P1.3.
- 2026-11-28: Ideas offered, not chosen: Undo for Apply to All; Apply to Selected (multi-select); named saved looks.
