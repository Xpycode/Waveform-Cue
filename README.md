# Waveform Cue

A small Mac app for turning a music file into an MXF cue clip. The video carries a whole-track waveform, a close-up following the playhead, elapsed and remaining time, and a positionable text overlay. Every frame can be read independently while jogging on a replay server.

## Use

1. Drag one audio file onto the monitor or the app icon, or choose **Open Audio**. The app uses the filename as the initial overlay.
2. Press **Space** to play or pause. Click or drag across the waveform or use the slider to cue. **Left Arrow** and **Right Arrow** step one frame when the text field is inactive.
3. Click **Appearance** in the toolbar to open the right sidebar. Edit **Overlay text**, choose a **Position**, or drag the text in the monitor. Clear the field to remove the overlay.
4. In the same sidebar, set each clock’s color and size, choose independent colors for the full-track and close-up waveforms, and set the close-up zoom window. The preview updates immediately. Your choices apply to each export and are remembered across launches.
5. Click **Export MXF** to save beside the audio, or choose **File → Export MXF to Folder**. Each export gets a new name. Cancellation leaves the previous files intact.

Set **Zoom window** to **Off** to use one enlarged, scrubbable full-track waveform in both the monitor and export. With zoom enabled, the highlighted box in the whole-track waveform marks the close-up below. Auto follows the playhead through a 10-second window, or half the clip for tracks under 20 seconds. Choose 2, 5, 10, 20, 30 or 60 seconds for a fixed window. The window stops at either end and fits within the track. Click the overview to jump anywhere, or drag inside the close-up for a finer cue. The close-up uses a fixed square-root amplitude scale to show quiet fades, with silence drawn as a flat line. Both views are included in the MXF.

In **Appearance**, choose **5 seconds** or **10 seconds** under **Fade to red** to start fading the Remaining digits from their selected color. Set **Solid red at** to **Last frame** (default) or **1 second**. With **1 second**, red holds for the final 25 video frames. The timing follows the clip end, including any silent tail.

Under **End warning**, enable **Fade close-up to red**, **Fade full track to red**, or both. Each selected waveform follows the Remaining clock’s fade timing. Turning zoom off hides the close-up and keeps its selection for later. On a fresh installation the close-up is selected and the fade starts at **Off**. Earlier saved settings retain their original waveform behavior.

The clock reads minutes, seconds and frames at 25 fps. The first frame shows zero elapsed and the full clip duration remaining. The last video frame shows one frame remaining. At the end of preview playback the remaining clock reaches zero.

## Output

The first preset is MXF OP1a with 1920 × 1080 progressive MPEG-2 Long GOP, 8-bit 4:2:2 at 25 fps and 50 Mb/s CBR (Rec. 709, video range, square pixels), and one stereo 24-bit PCM track at 48 kHz. Embedded timecode starts at 00:00:00:00. A partial final frame is padded with silence. Check this preset against the intended EVS ingest configuration.

Import decodes the first audio stream to temporary stereo PCM using the bundled FFmpeg. The monitor, waveform analysis and export all use that same audio. The source file stays intact. The picture uses the same Core Graphics renderer for preview and encoding. The waveform scales to the highest peak for visibility. This affects the picture only.

## Build

Open `WaveformCue.xcodeproj` in Xcode and build the WaveformCue scheme. The local testing build targets macOS 14 or later. The bundled encoder in this build requires Apple silicon.

The build phase in `Scripts/bundle-ffmpeg.sh` copies a self-contained FFmpeg executable into the app. On this Mac it uses the copy supplied with Magpie. To build on another machine, set the Xcode build setting `FFMPEG_EXECUTABLE` to a self-contained macOS FFmpeg with the required audio decoders, MPEG-2 video encoder, PCM encoder, CAF and MXF muxers. A completed app runs independently of Magpie. The build uses ad hoc signing for local testing. `project.yml` is the XcodeGen project definition.
