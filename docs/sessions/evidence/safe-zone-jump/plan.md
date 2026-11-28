# Custom safe zones jump between adjacent percentages

Prepared 2026-11-28 from the operator’s screenshots and a read-only inspection of `feature/appearance-panes` at `34e0b6d`. Completed on the integrated Wave 4 handoff at `e7ce4c5`.

## What the operator saw

Use any synthetic audio clip. In Appearance, enable Custom safe zones and show all four panes. Set their order to Title, Clocks, Full track, Close-up. Use a five-second close-up, Small Elapsed on the left, Large Remaining on the right, and zero pane offsets. Set Top to 5% and the side reserves to 0%.

In screenshots 4 and 5 the clip is paused at the same frame. Changing Bottom from 13% to 14% moves the top of the close-up from about y=928 to y=804 in the screenshot. Its height stays about 114 screenshot pixels. One percent reserves only 10–11 rows of the 1080-line output. The title font shown is Gill Sans and the clock family is truncated as “Noto Sans Kan…”. Font metrics can change which percentage crosses the threshold.

Screenshots 6–10 also show little or no movement between some low values. These settings reserve a minimum clear band. The existing 55-pixel vertical margin already covers most of the first 4%, including the 12-pixel padding. Preserve that behavior. The requested correction is the sudden collapse of spacing once the waveforms reach minimum height.

## Cause and scope

In [CueLayout.swift](../../../../01_Project/Packages/CueCore/Sources/CueCore/CueLayout.swift), find the vertical layout branch containing `plan.shrinkGaps(by: shrink)`. It shortens the waveforms to their floors, then charges the full original shortage to the gaps. With both waveforms visible, the close-up can surrender 115 pixels (265 to 150) and Full track can surrender 40 (100 to 60). At the transition this can charge the same 155 pixels twice. [MonitorView](../../../../01_Project/Sources/App/Views/AppKit/MonitorView.swift) and [MXFExport](../../../../01_Project/Packages/CueCore/Sources/CueCore/MXFExport.swift) both consume the appearance layout.

The appearance-panes plan explicitly preserved exportable build 17 geometry. Its checks cover pane clearance, valid ordering, and restoration after changing safe zones. They can pass even with a jump between two valid layouts. See [the compatibility test](../../../../01_Project/Packages/CueCore/Tests/CueCoreTests/Build17LayoutTests.swift).

## Execution

- [x] **SZ1 — Fix the transition and verify it in the picture.** One implementation task owns the layout calculation, a regression in [CueLayoutTests.swift](../../../../01_Project/Packages/CueCore/Tests/CueCoreTests/CueLayoutTests.swift), and any narrowly justified compatibility expectations. Start after Wave 4 hands off its integrated source. Recheck the branch for an intervening fix.

1. **Capture the failure first.** With the reproduction settings above and the standard test fonts, sweep Bottom by one percentage point at a time from 0% to 30%. Record the first transition from waveform compression into gap compression. At adjacent fitting steps around that boundary, compare the actual pane positions and the sum of the gaps. With fixed Top, unchanged clock/title sizes and zero offsets, the bottommost extent should move by at most the change in the reserved band plus a few pixels for rounding. Include the operator’s 13% and 14% values in the sweep. Use the measured transition for the failing assertion so the test also works on Macs with different fonts.
2. **Correct the shortage accounting.** Capture the available waveform reduction before mutating the stack. Apply that reduction, then pass only the remainder of `shrink` to `shrinkGaps`. The capacity getter depends on the current heights and returns zero after they reach their floors. Retain the existing rounding allowance, shrink order, minimum gaps, font-size steps and final fit checks.
3. **Check compatibility deliberately.** Verify the same settings in reverse restore the original rectangles. Run the existing safe-zone margin, pane-order, minimum-gap, offset, blocked-layout and rendering tests. Keep the original build 17 reference data. If corrected compressed layouts differ from that historical reference, identify the specific cases, confirm each follows from the residual shortage, and document the intentional expectations in the comparison. Keep exact comparisons for unaffected cases.
4. **Verify through the normal entry points.** From the repo root, start with `swift test --package-path 01_Project/Packages/CueCore --filter CueLayoutTests`, then run `swift test --package-path 01_Project/Packages/CueCore --filter Build17LayoutTests` and the project’s full CueCore suite with its FFmpeg integration settings. Follow the repo’s testing instructions before building. In a fresh Waveform Cue build in the Atlas helper, use a synthetic clip and capture adjacent steps on either side of the transition. Check a decoded export frame at the corrected setting against the preview’s pane positions. Report the measured before/after displacement in 1920 × 1080 picture coordinates, the test results and screenshot evidence.

## Execution log

SZ1 is complete (1/1). A fresh-context implementation agent owned the layout and regression. The coordinator reviewed the diff, built the Release, exercised the signed Release in Atlas and measured the decoded app export. Source and tests landed in `b392155`.

The default-font boundary on this Mac was 21% to 22%. The 11 additional reserved rows moved the close-up up 165 px before the fix and 10 px after it. The reverse sweep restored every layout. All 23 focused tests, the 320 historical geometry cases and the full 343-test FFmpeg-enabled suite passed. There were zero skips or failures. The compatibility fixture and its exceptions stayed intact. The give-way test now checks whether the prior clock size could fit at minimum gaps, which allows the smaller clock to release space back to the gaps. The actual preview and first decoded MXF frame agree on all four pane positions within screenshot precision. [Measurements, screenshots and decoded frame](README.md)
