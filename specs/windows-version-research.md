# Windows Version Research

**Status:** Research, no decision recorded and nothing built
**Created:** 2026-11-27

Nothing here was built or run on Windows. Findings come from reading the code and from web research. Items marked *unverified* still need checking.

## Requirements (from the operator)

- Public download.
- No feature parity with the Mac app required.
- In-app updates, comparable to Sparkle.
- Microsoft Store is not an option.
- Must work on machines without internet.
- Must run on Windows 10.
- Test machine: x86-64 Windows at work. ARM is out of scope.

## Recommendation

Build the Windows version as a separate app in C#/.NET with Avalonia and SkiaSharp, bundling a Windows FFmpeg, with Velopack for installer and updates. Start from build 10 behaviour (single file, MPEG-2 preset) and add later features only as wanted.

Reasons:

- The UI cannot carry over. AppKit today and the planned SwiftUI shell with AppShellKit are both Apple-only.
- The renderer cannot carry over. `CuePicture` is Core Graphics and Core Text, which do not exist on Windows.
- What remains is small (about 1,400 lines), and FFmpeg already does the encoding.
- Avalonia carries its own Skia renderer, so preview and export can share one SkiaSharp renderer, and nothing depends on the Windows version.

## What ports and what does not

| Part | Mac today | Windows |
|---|---|---|
| Encoding | FFmpeg subprocess, raw BGRA over a pipe | Same arguments; only the pipe-writing code is Darwin-specific |
| FFmpeg binary | Copied from Magpie | BtbN or gyan.dev static win64 build |
| Picture | Core Graphics, Core Text, Helvetica Neue | Skia; bundle a font, Helvetica Neue is not on Windows |
| Audio read | `AVAudioFile` on a CAF, `vDSP` peaks | Have FFmpeg write WAV; a plain loop replaces `vDSP` |
| AAC trim | AudioToolbox packet table | No equivalent; test whether FFmpeg's priming handling matches |
| Playback | `AVAudioPlayer` | WASAPI, for example through NAudio |
| Settings, panels, drag and drop | AppKit | Avalonia equivalents |

The picture will not be pixel-identical between platforms.

## Alternative considered: stay in Swift

Swift 6.3 ships official Windows toolchains (x86_64, arm64). swift-cross-ui v0.11.0 has a WinUI backend that "supports most features". Not recommended: the toolkit is 0.x, custom drawing and file drag and drop on Windows are *unverified*, a second renderer is still needed, and without a parity requirement there is little to gain from shared code. The health of swift-winrt and swift-winui is *unverified* (Swift Forums were unreachable).

## Updates and installer

- **Velopack** (recommended): installer and updater in one, delta updates, Avalonia example, per-user install without admin rights. Reading updates directly from GitHub Releases is *unverified*.
- **NetSparkleUpdater**: the Sparkle port for .NET, appcast XML, ready-made Avalonia update window. Choose it for one appcast format on both platforms.

## Offline machines and Windows 10

- Publish self-contained so the .NET runtime ships inside the app.
- `Setup.exe` carries the full app and installs from USB. Running a newer one updates an existing install. Also publish a portable zip.
- The update check must fail silently offline, with a **Check for Updates** menu item for manual use.
- Avalonia and current .NET support Windows 10 (confirm the exact minimum build for the chosen .NET version, *unverified*).
- Test on a real Windows 10 machine or VM before release, especially audio playback and file dialogs.

## Signing

Signing is optional. An unsigned installer runs, with these costs:

- SmartScreen shows "Windows protected your PC" on downloaded files; the user clicks **More info → Run anyway**.
- Prompts say "Unknown publisher".
- Managed machines (AppLocker, Smart App Control) can block unsigned apps.
- Files copied by USB usually carry no download mark, so offline machines are typically unaffected (*unverified*).

Options if signing is added later (prices from memory, *unverified*):

- OV certificate, roughly $200–400 a year, key on a hardware token or cloud service.
- Azure Artifact Signing, about $9.99 a month; individuals only in the USA and Canada, organisations in the EU.
- Certum open-source certificate, or SignPath Foundation for qualifying open-source projects.

A signed new app still gets the SmartScreen warning until it builds reputation. Suggested start: ship unsigned, document the "Run anyway" step, add signing if managed machines block it.

## FFmpeg licence

AVC-Intra uses libx264, which is only in GPL builds. Ship FFmpeg as a separate executable with its licence and a source offer. An MPEG-2-only build could use the LGPL variant. Check the terms before the first public release.

## Suggested order

1. One-day spike on the work machine: SkiaSharp draws one 1920 × 1080 frame, pipes BGRA to a BtbN win64 GPL FFmpeg, and the MXF opens.
2. Port the renderer and export, then the monitor and appearance controls in Avalonia.
3. Add Velopack and a GitHub Actions `windows-latest` job that builds, packs and uploads the release.
4. Decide signing before or after the first public release.

## Open questions

- Sign as a company or as an individual, if at all?
- Same repository or a separate one for the Windows app?

## Sources

- [swift-cross-ui](https://github.com/moreSwift/swift-cross-ui)
- [Swift install for Windows](https://swift.org/install/windows/)
- [swift-winui](https://github.com/thebrowsercompany/swift-winui)
- [BtbN FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds)
- [gyan.dev FFmpeg builds](https://gyan.dev/ffmpeg/builds)
- [Velopack on NuGet](https://nuget.org/packages/velopack)
- [NetSparkleUpdater.UI.Avalonia](https://www.nuget.org/packages/NetSparkleUpdater.UI.Avalonia)
- [Microsoft code signing options](https://learn.microsoft.com/windows/apps/package-and-deploy/code-signing-options)
- [Artifact Signing pricing](https://azure.microsoft.com/pricing/details/artifact-signing/)
- [Avalonia vs WinUI 3](https://avaloniaui.net/winui-compare)
