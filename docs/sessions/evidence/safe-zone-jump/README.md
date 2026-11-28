# Custom Bottom reserve in the preview and MXF

Waveform Cue on the M4 Pro, macOS 15.8.1. The original signed Release was Wave 4 build 18. The corrected Release uses the same version, with the layout fix applied to the integrated Wave 4 source at `e7ce4c5`.

## Adjacent percentages

The sweep used a 1920 × 1080 picture, standard Helvetica Neue Medium title and Menlo Regular clocks, and a five-second close-up. From top to bottom the panes were Title, Clocks, Full track and Close-up. Elapsed was Small on the left and Remaining was Large on the right. Top was 5%, both sides and all offsets were zero. Coordinates below increase downward from the top of the picture. The last extent includes the tick labels below the close-up.

| Layout | Bottom | Reserved rows | Full-track waveform top | Close-up waveform top | Lowest pane extent | Sum of gaps |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Both | 13% | 141 | 475 | 673 | 925.52 | 242.63 |
| Both | 14% | 152 | 475 | 670 | 914.52 | 242.63 |
| Both | 21% | 227 | 475 | 651 | 839.52 | 242.63 |
| Wave 4 | 22% | 238 | 358 | 486 | 674.52 | 77.63 |
| Corrected | 22% | 238 | 468 | 641 | 829.52 | 232.63 |

At 21% and 22% the full track was 60 px high and the close-up was 150 px high. The original code charged 155 px of waveform reduction a second time against the gaps. With the correction, the 11-row increase in reserve moved the close-up and its lowest extent up 10 px, including placement rounding. Across 13% to 14% the clocks and full track stayed anchored and the close-up top moved up 3 px with either build.

| Atlas preview of the same paused frame | Bottom 21% | Bottom 22% |
| --- | --- | --- |
| Wave 4 | [Before, 21%](before-21.png) | [Before, 22%](before-22.png) |
| Corrected | [After, 21%](after-21.png) | [After, 22%](after-22.png) |

Both builds opened the same six-second synthetic 440 Hz tone in a disposable Atlas profile. The inspector stepper made the change while the clip was paused at frame zero. The visible preview at 21% was pixel-identical between builds in the interior of the picture. The upper edge of the colored close-up waveform moved 62 screenshot pixels in the original app and 4 in the corrected app, equivalent to about 164 and 11 picture pixels at this viewer scale.

## Decoded export at 22%

The corrected app's **Export Selected** command produced an AVC-Intra 100 1080p25 MXF. FFmpeg decoded its first video frame for comparison with the actual on-screen preview. The preview was 724 pixels wide, so a screenshot pixel represented 2.65 picture pixels. The table gives the first visible row center of each landmark in top-down picture coordinates. The waveform rows use the panel background sampled away from the playhead. The text rows use bright glyph pixels. The preview and decoded frame agreed to within 3.4 picture pixels across all four panes. [Corrected preview](after-22.png) · [Decoded frame](export-22.png)

| Landmark | Preview y | Decoded y |
| --- | ---: | ---: |
| Title ink | 87.9 | 84.5 |
| Elapsed digits | 292.0 | 290.5 |
| Remaining digits | 260.2 | 259.5 |
| Full-track panel | 469.7 | 468.5 |
| Close-up panel | 642.1 | 641.5 |

At native resolution both decoded waveform panels begin at exactly the layout's predicted row, 468 and 641. The entire 54-row top and 238-row bottom reserves decoded to uniform RGB (12, 17, 19) at eight bits per channel. The exported file was 87,329,837 bytes, SHA-256 `57a1ea2ef59cf8385ef9e67671af7b6010e613b1007764d0f4d1e8d04106f162`.

## Reproduction on this Mac

The app, MXF and raw verification logs are in `04_Exports/safe-zone-jump/`. The ad-hoc signed Release passed strict code signature verification. The executable SHA-256 was `4f2cbe92dad099316571af686d4c5f6d5bc9608986424a2466a71a79d8f2a842` in both the durable bundle and the running Atlas copy. Atlas confirmed both builds closed. The synthetic inputs and private helper profile were removed after collecting the export.

The regression sweeps Bottom from 0% through 30%, locates the onset of gap compression, checks the adjacent pane extents and gap sums, and reverses all 31 settings. Its original failure recorded 165 px of motion against a 14 px upper bound (11 reserved rows plus three for placement rounding). All 23 focused layout tests passed after the fix. All 320 build 17 fixture rows passed the existing comparison, including its 64 previously documented blocked-preview rounding adjustments.

The complete headless CueCore suite passed 343/343 in 200.19 seconds with zero skips or failures. The run set `FFMPEG_EXECUTABLE=/Applications/Magpie.app/Contents/Resources/ffmpeg`, enabled both render and export benchmarks, supplied `CUE_X2_DIR` and `CUE_SLATE_PNG` in disposable storage and used an isolated SwiftPM scratch directory. Source commit `b392155`. [Completed plan](plan.md)
