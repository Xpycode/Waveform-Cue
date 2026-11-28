# Appearance panes Wave 3 verification

On November 28, 2026 the M4 Pro ran Waveform Cue 0.1 (17) in the hidden Atlas helper on macOS 15.8.1. The queue contained synthetic six-second tones. The final Debug build came from source commit `2f03818`.

## Offset controls

| Check | Observed result |
| --- | --- |
| One step | Clicking Full track up changed its field from 0 to +1 px. In a 724 × 406 viewer crop, changed pixels were confined to the Full track band. The package tests check whole-pixel picture geometry at 1920 × 1080. [Before](before.png) · [After](one.png) |
| Native repeat and viewer redraw | On the final build, one 607 ms pointer gesture stayed on the upper half of the stepper. Full track began at +12 px, displayed +13 px before release, and ended at +14 px. Only pixels in the Full track band changed between the three viewer crops. [Start](final-start.png) · [During the hold](final-during.png) · [Release](final-release.png) |
| Deferred queue save | A sampler read the disposable queue's inode and nanosecond modification time every 10 ms. It observed the old file with Full track at 12 and one atomic replacement after release with Full track at 14. The timestamps were 1795879257193742288 and 1795879268359136957. The release screenshot preceded the replacement by 0.576 s. Clocks remained at −8 px throughout. |
| Limits and input | Typing 500 into Full track stopped at +62 px with the title above. Another upward step stayed at +62. Typing −500 into Clocks stopped at the lower frame limit of −42 px. Another downward step stayed there. Both clock readings moved down together. [Neighbour limit](max.png) · [Frame limit](clock-edge.png) |
| Safe zones | EVS OSD reduced the displayed Clocks offset from −42 to −1 px. Restoring None brought −42 px back. On the final build, entering invalid text at −1 and pressing Tab preserved −42 in the queue. After restoring None, Atlas reported the 722 × 404 viewer capture unchanged from before the reserve. Explicitly typing the valid −1 under the reserve committed −1 to the queue. [Before](zones-before.png) · [With reserves](zones-tight.png) · [Restored](zones-restored.png) · [Matched viewer crop](clean-before.png) · [Explicit edit](final-edit.png) |
| Pane move | Move Up placed Clocks between Full track and Close-up. Its field and saved offset remained at −8 px. [After reordering](reordered.png) |
| Accessible controls | Atlas reported a text field and an incrementor for each of the four pane-specific vertical offset labels. Spoken VoiceOver output remains in PX2. |

## Saved jobs and defaults

Apply to All copied the reordered picture and offsets to the second job, which kept its own title. A newly imported tone inherited the same order and offsets. Restore Defaults returned that tone to zero offsets and the factory order, preserving its title. [Second job](apply.png) · [New import](import.png) · [Restore Defaults](reset.png)

The build 17 fixture passed through the real queue store. Saving omitted the old clock position and both title coordinates, and the reloaded job rendered identical pixels. The app source scan returned no uses of the retired API. Tests also changed each shared layout setting independently to check the queue's match indicator.

## Integration

The full package suite passed all 338 tests with zero skips. FFmpeg, both benchmarks, the slate image and all eight EVS sample exports were enabled. The package lane passed 121 focused migration, layout and hit-testing tests. Independent review found a held stepper could continue into a newly selected job. The final build retires its native sender on selection or export lock, and the reviewer verified the correction in source.

The preserved Debug app passed deep, strict ad hoc signature verification. Atlas matched its running executable and Debug library hashes, closed the app and cleaned up the fixture profile. The decoded-MXF comparison belongs to P4.1; live VoiceOver and macOS 27 image verification remain external gates.
