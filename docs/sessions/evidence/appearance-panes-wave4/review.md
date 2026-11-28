# Build 18 review

## App Shell Standard

All ten checks passed on November 28, 2026. The app uses the shared AppShellKit implementation.

| Check | Evidence |
| --- | --- |
| Compatibility flag | `plutil -extract UIDesignRequiresCompatibility raw -o - 01_Project/Info.plist` returned `true`. |
| Hidden title bar | The main scene in `WaveformCueApp.swift` uses `.windowStyle(.hiddenTitleBar)`. |
| Appearance | The scene defaults to dark, stores the preference and installs AppAppearanceCommands. AppShellKit's AppAppearance.swift applies the selection to NSApplication. |
| Toolbar role | MainWindow applies the editor role to its main content. |
| Navigation | A source search for NavigationSplitView returned no matches. |
| Panes | MainWindow builds the queue, monitor and inspector in an HSplitView. |
| Flat toolbar actions | Add Audio, Start/Stop Queue and Export Selected use FlatToolbarButtonStyle. |
| Theme | MainWindow imports AppShellKit and uses its background colors. |
| Split autosave | MainWindow stores split positions under WaveformCue.Main. |
| Pane toggles | The queue and inspector visibility each have their own AppStorage key. |

The shell check covered the target built with Xcode 26.3 on macOS 15.8.1. The macOS 27 SDK's handling of the compatibility flag is a previously recorded platform difference.

## Findings and regression checks

The independent reviewer inspected the package and app changes from `531e91c` through `34e0b6d`, starting with saved-job migration. Four findings reproduced in the code or tests.

| Finding | Correction and verification |
| --- | --- |
| Startup cleanup matched unrelated files and folders by prefix | Both session-cleanup entry points now recognize the complete generated UUID folder name. Export cleanup recognizes only generated partials and writability probes. Active owners, malformed owner markers and newly created unclaimed folders are preserved. The old sweep failed 14 assertions across three regression cases. All 19 audio and workspace tests passed after the fix in `c4ddecb`. |
| A legacy peaks summary could crash frame-count conversion | A stored duration of 1e20 now drops only the unusable summary. The queue test preserved both neighboring jobs, title and valid detailed analysis through a save and reload. The 24-hour boundary remains valid. All 29 job and queue-store tests passed after `c21f077`. |
| Three-digit minutes could overlap | At 101 minutes elapsed and 101 minutes remaining, both clock-side settings drew 4,377 foreground pixels in the expected gap with narrow margins and Extra large clocks. The renderer now sizes long readings against the clip duration. Both placements leave the gap clear. |
| A music-end marker before trim-in triggered end zoom at the first frame | End zoom now takes the same in-range marker as the timeline. With a 40-second source, a 10-second trim-in and a music end at 5 seconds, the close-up matches the File end target at four test positions. |

The 13 focused clock, zoom and slate tests passed together. The pre-roll comparison also exercised nonzero offsets on all four panes. A suspected stale Reset action was ruled out after tracing the inspector identity and coordinator guards.

A second read-only reviewer checked the four fixes. The final integration run passed all 342 tests. [Release evidence](integration.md#release-handoff)
