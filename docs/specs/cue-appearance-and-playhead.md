# Cue appearance and playhead

The [build 17 reconciliation](../decisions.md#2026-11-28--reconcile-wave-4-with-build-17) supersedes the original batch, default and layout rules below.


Direction approved for planning · 2026-11-27 · [Implementation plan](cue-appearance-and-playhead-plan.md)

## Problem

An operator preparing a batch of EVS cues needs to give the songs a consistent look while keeping each song’s title, timing and export settings. On the rehearsal monitor, the EVS timecode crosses the lower edge of the cue clocks even though there is unused space above them. Near a cue boundary the close-up playhead also changes how it moves, just where the operator wants to watch for the first or last beat.

## Proposed workflow

Add five songs, style one and apply its appearance to the other pending songs from either inspector tab. Choose the close-up behaviour, preview the first and last beats, then export. The MXF should show the same waveform position, fonts, elements and clocks seen in the preview. An explicit Save as Default action makes the look available to future jobs.

## Acceptance criteria

| Area | Example to verify |
|---|---|
| Batch appearance | Given a mixed queue, when the operator applies appearance from the shared inspector footer, the other Pending jobs receive the style. Each keeps its title text, export preset, trim, markers, gain and pre-roll timing. Running and completed jobs keep their snapshots. The action shows how many jobs it affects. |
| Defaults and overrides | Given a saved default, new jobs start with a copy. Editing a job marks the changed settings. Reset restores a setting from the default. Saving a new default affects subsequent imports. |
| Fonts and visibility | Title and clock fonts can be chosen independently. Clock digits keep a constant width when jogged. A missing font falls back to a readable default. Hiding a title, clock or waveform frees its space. A hidden waveform has no click target. |
| Feature switches | Disabling a feature retains its configured values for re-enabling. With markers off, countdown uses file end. With loudness analysis off, normalisation is unavailable. Disabling trim/fades, pre-roll or safe zones removes the corresponding effect from the export. Safe-zone guides remain preview-only. |
| Centred close-up | Given a five-second window, the clip starts with the playhead in the centre and 2.5 seconds of empty space to its left. At the out boundary the empty space is on the right. Short clips and trimmed clips show blank space beyond their actual bounds. Scrubbing and decoded export frames agree at whole frames; the preview has 25 positions per second, so second fields of a 1080i50 export are checked from the decoded file. Existing jobs retain the current edge behaviour by default. |
| Close-up shading | Added 2026-11-27. In the close-up, the upcoming audio can be drawn brighter than the played audio, the reverse of build 11. The fade to red follows the brighter side. The full track is unchanged. Saved build 11 jobs keep their look. It is the default for new jobs (decided 2026-11-27). |
| Zoom near end | When enabled, the close-up eases into a shorter window as the selected countdown target approaches. The overview highlight shows the visible portion of the clip. Jogging back to the same frame reproduces the same view. Centred mode keeps the playhead centred through the transition. |
| EVS layout | Given the rehearsal settings (1080i50, five-second zoom, Small Elapsed and Large Remaining), reclaim excess space between the tick labels and clocks before reducing waveform height. Compare with build 11 at identical 11% top and bottom reserves. Check a second export at 11% top and 16% bottom on EVS for clearance above its timecode row. The latter values are a trial. |
| Compatibility | Open a saved build 11 queue and older appearance settings. Existing jobs load with the same values. Compare default renders with the existing reference frames and separately verify the intentional safe-zone layout change. |

## Technical considerations

Use the shared picture layout and timeline for preview, export, overview highlighting and pointer handling. Treat zoom width and playhead position as independent choices. The remote research predates build 11 and suggests holding the window at the end during automatic zoom. That suggestion fits the current edge mode. A fixed centre requires blank space beyond the end. [Next-round research](https://github.com/Xpycode/Waveform-Cue/blob/f5ed7ae3041db8eedf26c94b0f9d4d20542a8498/NEXT_PLAN_RESEARCH.md)

## Open decisions and evidence

- Use a shared **Apply Appearance to Pending Jobs** action and explicit **Save as Default**. Defer live propagation. The plan retains the existing appearance-plus-preset action as a separately labelled compatibility option.
- Confirm safe-zone clearance on the EVS output before selecting preset percentages. The central EVS network indicator is visible over the waveform and sits outside the top and bottom bands.
- Verify Remaining by jogging consecutive fields at the head and tail of clip 413A. If EVS changes its countdown on the second field, decide whether field-matched display is needed for 1080i50. The photographed mismatch alone does not establish a general one-frame correction.

## Scope boundaries

The toolbar divider and filename truncation have a screenshot and a reproduction case in the backlog and can be handled as a small bug fix. Build 11 acceptance and the release handoff stay in the existing [implementation plan](../IMPLEMENTATION_PLAN.md). The filename, slate loudness and large-queue performance observations remain in the [task inbox](../TASKS.md).
