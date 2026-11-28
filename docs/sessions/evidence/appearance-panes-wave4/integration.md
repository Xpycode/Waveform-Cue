# Viewer, decoded MXF and render timing

On November 28, 2026 the M4 Pro ran the Debug CueCore suite on macOS 15.8.1 with Xcode 26.3. The viewer check used the monitor's rendering and timeline entry points. The export check encoded a synthetic two-second 440 Hz tone as AVC-Intra 1080p25, then decoded frame 35 with FFmpeg.

| Check | Measurement |
| --- | --- |
| Decoded frame against the monitor renderer | Mean absolute RGB error 0.098 levels on a 0–255 scale. The worst 16 × 16 block averaged 6.77 levels, within the test limits of 1 and 9. |
| Picture order and Offset | The red Remaining digits on the left and blue Elapsed digits on the right both ended at y = 760, between Title and Full track. The automatic position was y = 770. The decoded picture measured exactly 10 pixels down from automatic. |
| Visible warning in Waveform Cue | The six-second helper tone began with gold Remaining at left and light Elapsed at right. Remaining turned orange at 00:02:24 and solid red at 00:00:10. The Clocks field showed −10 px throughout. [Start](start.png) · [Fading](fade.png) · [Solid](solid.png) |

The on-screen check used the preserved signed Wave 3 build at `2f03818`. Its app and package sources matched the P4.1 tree. Atlas opened a private copy with a disposable home, a synthetic tone and a seeded queue. The app closed and the temporary profile was removed. The [group scan](groups.json) and [control values](controls.json) retain the accessible names and roles returned by the helper.

The independent same-machine timing reference was the original 6.1 benchmark at `caec91a`, rebuilt into a separate temporary directory. It drew 500 frames at 1920 × 1080 in Debug at 223.7 frames/s. The 6.1 session on the M1 Max recorded 157.5 frames/s. The M4 Pro's comparison floor for a 5% regression was 212.515 frames/s.

The integrated tree at `34e0b6d` rendered at 214.9 frames/s, 3.9% below the same-Mac reference. The suite passed 339/339 in 202 seconds with zero skipped tests. Three-minute AVC-Intra exports finished in 26.63 seconds at 1080p25 and 41.39 seconds at 1080i50. All eight EVS samples were written locally.

```sh
CUE_BENCH=1 CUE_EXPORT_BENCH=1 \
CUE_X2_DIR=/private/tmp/appearance-wave4.WovYdI/samples \
CUE_SLATE_PNG=/private/tmp/appearance-wave4.WovYdI/slate.png \
FFMPEG_EXECUTABLE=/Applications/Magpie.app/Contents/Resources/ffmpeg \
swift test --package-path 01_Project/Packages/CueCore \
  --scratch-path /private/tmp/appearance-wave4.WovYdI/suite \
  --disable-automatic-resolution --skip-update
```

## Three original build 17 title anchors

A disposable XCTest probe loaded the saved build 17 job at top left, top center and top right (legacy y = 1 and x = 0, 0.5 and 1). Separate copies of the original renderer at `2b8f028` and the migrated renderer at `34e0b6d` used the layout-aware overview path and drew frame 375 of the same synthetic track. The two full-frame SHA-256 measurements matched for each anchor on macOS 15.

| Top anchor | SHA-256 in both renderers |
| --- | --- |
| Left | `52f638a6bf43fa0e31fa7fa7918df3de000e45eaf671eabdef5b8c4911873890` |
| Center | `ceb5ce07802d03d5ed4293bee9d4aa565694c183da012713c4762fec9c443b9c` |
| Right | `20c9d9ca6ee0542058f5a14b8da42cf82ae99114aafb5427aa8a9327681f6aba` |

## Release handoff

Build 18 came from `01c158a`. XcodeGen regenerated the project. From the repository root the build ran:

```sh
xcodebuild -project 01_Project/WaveformCue.xcodeproj -scheme WaveformCue \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/appearance-wave4.WovYdI/dd \
  -disableAutomaticPackageResolution -skipPackageUpdates build
```

On the M4 Pro, the durable folder is `/Users/simpro/ProgrammingProjects/1-macOS/FCPlugins/AudioWaveformDisplay/04_Exports/0.1-18`. It contains **Waveform Cue.app**, **EVS clock check.mxf** and the raw build, test and benchmark logs. At 16:43 CET on November 28 the absolute app path passed `codesign --verify --deep --strict`. Its signing identity is ad hoc, bundle version 0.1 (18), executable SHA-256 `67b5afbfa5fd6827dc9f4b9ba84789ab152ad50ef166b4c9ccda1b2e6a9b2edc`.

The final headless suite passed 342 tests with zero skips or failures. Render throughput was 232.6 frames/s against the same-machine 6.1 reference of 223.7. The three-minute progressive and interlaced exports took 28.80 and 42.86 seconds. The rerun used the command above under “Viewer, decoded MXF and render timing” with `final-samples` and `final-slate.png` as its output names.

Atlas showed the release executable running at `/Users/Shared/Atlas/Open/64da2ee031e4165e2db430dd3ee95e8fb87a10d5385d8f35/Waveform Cue.app/Contents/MacOS/Waveform Cue`. Its build number and executable checksum matched the durable copy. A genuine 202-minute synthetic FLAC displayed two separated Extra large readings at exactly 101 minutes with 15% side reserves. [Midpoint in build 18](release-long.png)

The short job exported in the release app with Title, Clocks, Full track and Close-up in order, Clocks at −10 px, Remaining left and EVS OSD selected. In the decoded frame at 5.6 s the entire top 87 and bottom 184 rows were uniform RGB (10, 16, 18). Among rows 100–649 there were 7,206 red warning pixels on the left and zero on the right. The 87,329,837-byte MXF has SHA-256 `9a2d01f78312dfaddb294adf49d51e297345a824d41e8e3fc62146346a61caa9`. The helper confirmed quit and its disposable files were removed. Open the durable app from Finder for desktop acceptance. [Completed helper export](release-export.png)
