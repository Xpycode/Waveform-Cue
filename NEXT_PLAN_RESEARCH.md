# Next plan research: fonts, feature checkboxes, settings levels, zoom near end

Last updated: 2026-11-27 · Status: research for a plan that starts after the active
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) is finished. Requests are in the
[TASKS backlog](TASKS.md#backlog). Nothing here changes the active plan.

**How this was researched.** I read the build 10 source (`CuePicture.swift`, `CueAppearance.swift`,
`CueAppearanceSidebar.swift`, `MonitorView.swift`, `AudioTrack.swift`, `AppController.swift`) and the
active plan. I checked API behaviour against Apple's Core Text and AppKit documentation. None of it was
run on a Mac, because this research ran in a Linux container. Items marked **verify** need a quick check
on the Mac before the plan relies on them.

**Read this first.** The active plan rewrites the code these features touch:

| Active-plan task | What changes |
|---|---|
| 0.2 | Moves the renderer into `Packages/CueCore` |
| 1.4, 2.1 | Replace the hard-coded rectangles with `CueLayout` |
| 1.3, 2.1 | Make drawing take a `ClipTimeline` position, including 50 Hz fields |
| 3.2 | Adds markers and the Music end countdown target |
| 1.6 | Gives every job its own appearance snapshot |

The next plan has to build on those types, not on the build 10 code. Line references below are to
build 10 and are only there to show where each value comes from today.

---

## 1. Font selection

### Today
- Title: `HelveticaNeue-Medium`, 48 pt. It shrinks to 34 pt to fit the width, then truncates with `…`
  (`CuePicture.caption`).
- Clocks and tick labels: `Menlo`. Section labels ("Full track", "Elapsed" and so on): `HelveticaNeue-Medium`.
- Text is drawn by `CuePicture.line(_:font:size:color:)` with `CTFontCreateWithName`. The preview and the
  export use the same call, so a chosen font looks the same in both.

### Findings
1. **`CTFontCreateWithName` never fails.** For an unknown name it silently returns a substitute font.
   To detect a missing saved font, compare `CTFontCopyPostScriptName(font)` with the requested name,
   and if they differ use the build 10 default. **verify** which substitute macOS returns, because a
   test needs to know.
2. **Listing fonts.** `NSFontManager.shared.availableFontFamilies`, then
   `availableMembers(ofFontFamily:)` for the styles. Each member gives
   `[PostScript name, style name, weight, traits]`.
   - Save the **PostScript name**, for example `HelveticaNeue-Medium`. It identifies one exact style.
   - Two pop-ups, Family and Style, are a better fit than `NSFontPanel`. The panel also sets size,
     and the clock sizes are fixed presets. Pop-ups also follow the project's AppKit control rule.
3. **Clock digits must all be the same width,** or the clock jitters as it counts. Two ways to get
   that:
   - **Monospaced font:** `CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)`.
   - **Equal-width digits in a proportional font:** add the feature `kNumberSpacingType` (6) with
     `kMonospacedNumbersSelector` (0) through `kCTFontFeatureSettingsAttribute`. This is the same as
     OpenType `tnum`, and the system fonts and many others support it.
   - **Robust filter:** whichever way is used, measure it. Get the glyphs for `0`–`9` with
     `CTFontGetGlyphsForCharacters`, then check that `CTFontGetAdvancesForGlyphs` returns equal widths
     with the feature applied. The clock menu lists only fonts that pass. This test is pure, so it can
     be a headless `swift test`.
4. **The layout uses Helvetica and Menlo measurements as fixed numbers.** All of these need to come from
   the chosen font's metrics instead (`CTFontGetAscent`, `CTFontGetDescent`, `CTFontGetCapHeight`):
   - the caption height `adjustedSize + 22` and its baseline offset `+17`;
   - the clock label position `size.points * 0.77 + 26`, where 0.77 is roughly Menlo's cap height.

   A wider clock font at Large or Extra large can also break the "does it fit" check in `CueLayout`
   (plan task 1.4). The clock width must become an input to `CueLayout`.
5. **Saving the choice.** Add `titleFont: String?` and `clockFont: String?` to `CueAppearance`, read with
   `decodeIfPresent`. A missing value (`nil`) means the build 10 font, which is the pattern
   `CueAppearance.init(from:)` already uses. Saved build 10 settings therefore stay identical, and the
   0.2 baseline hashes stay valid.
6. **Showing each font in its own face** in the menu works with `NSMenuItem.attributedTitle`. It may be
   slow with several hundred families, so **verify** the cost and fall back to plain titles if needed.

### Open questions
- Should the section labels and tick labels follow the title font, the clock font, or stay as they are?
  Suggestion: labels follow the title font and ticks follow the clock font.
- What about a font that doesn't cover the title's characters? Core Text substitutes another font for
  missing glyphs automatically. The preview shows the result, so nothing extra is needed.

---

## 2. Feature and picture-element checkboxes

### Elements drawn today (`CuePicture.draw`)
- **Full track:** label, duration, panel, highlight box (when zoom is on), waveform, playhead.
- **Close-up:** label, panel, ticks and tick labels, waveform, playhead and triangle.
- **Clocks:** Elapsed and Remaining, each a label plus digits.
- **Title.**

### Findings
1. **A precedent exists.** Zoom `Off` already hides the close-up and enlarges the full track to fill both
   areas (`overviewRect(for:)`). The README says the close-up's fade setting is kept for later.
   Checkboxes should follow the same rule: **turning a feature off keeps its settings**, so turning it
   back on restores them.
2. **Close-up checkbox versus zoom `Off`.** Having both would give two ways to say the same thing.
   Suggestion: the close-up checkbox replaces `Off` in the zoom menu, and a saved `zoom = .off` loads as
   close-up off with the zoom set to Auto. That change affects the saved-settings format, so it needs a
   loading test with a build 10 settings file.
3. **Hidden elements should give their space to the rest.** That means hiding becomes an input to
   `CueLayout`, not just skipped drawing, the same way zoom Off works today. Clicking must follow:
   `MonitorView.mouseDown` hit-tests `overviewRect` and `detail`, so a hidden waveform must not respond
   to clicks or seeking. With both waveforms hidden, seeking works only with the slider.
4. **Feature checkboxes, and what each one turns off:**

   | Checkbox | When off |
   |---|---|
   | Music-end markers | Countdown target is forced to File end. Marker drawing and dragging are off. |
   | Loudness check | The loudness measurement pass is skipped, which saves time per job. Normalise is disabled. |
   | Normalise | Gain 0 dB |
   | Trim and fades | The whole file is used. In and out points are kept. |
   | Pre-roll | No slate. The setting is kept. |
   | Safe zones | Same as None. The custom values are kept. |
   | Guides | Preview only, as in the active plan |
   | Countdown warning, waveform fades | Already exist as `CountdownWarning.off` and the two fade checkboxes |

   Model: each feature gets an `enabled: Bool` next to its values. Wrapping the value in an optional
   would lose the value when the feature is turned off.
5. **The control already exists in the app.** `NSButton(checkboxWithTitle:)` is used in
   `CueAppearanceSidebar` and follows the control rule. The new checkboxes go through the existing
   `edit(_:)` → `changed(settings)` path.
6. **Proving nothing changed.** With every checkbox at its build 10 value, the 0.2 baseline hashes must be
   unchanged. Add one hash test per element turned off.

---

## 3. Settings: app-wide defaults and per-job overrides

### Findings
1. **App-wide defaults already exist.** Build 10 saves the appearance on every change under the settings
   key `ClockAppearance.v1` (`AppController`, sidebar `changed` closure). In the active plan, each job
   gets its own snapshot of the appearance (task 1.6). So the defaults are what we have today, and
   overrides are the job snapshots.
2. **Copy, don't inherit.** A new job copies the defaults, and an override is any field that differs
   from them. With inheritance, where an empty field means "use the default", changing a default would
   also change jobs already set up, and would risk changing finished jobs. Copying keeps finished jobs
   frozen.
3. **Override markers** come from comparing the job's settings with the defaults field by field. That
   needs `Equatable` on `CueAppearance`, `ClockStyle` and `CueColor`, which they don't have today.
   Compare colours with a tolerance, or keep the exact stored values so they compare equal.
4. **The "Same settings for all jobs" switch** means every edit runs through Apply to All, which the active
   plan already has in task 1.6, and also updates the defaults. The rules stay the same: only jobs not
   yet run change, and the running job stays locked.
5. **What the switch must not copy:** trim, markers, loudness gain and pre-roll timing. These belong to
   each track, and the active plan's open question X4 already limits Apply to All to the appearance and
   the export format. Fonts, picture-element checkboxes and feature checkboxes copy; per-track values
   don't.

---

## 4. Zoom in near the end

### Today
`CuePicture.closeUp(frame:total:zoom:)` returns a whole-frame range centred on the playhead and held
against either end of the track. While you drag in the close-up, the range is held (`heldDetail`).
Waveform detail comes from 5 ms peak buckets (`detailPeaks`), so a 3 s window has about 600 values
across 1,728 px, the same resolution as today's 2 s setting.

### Findings
1. **Centring the narrower window hides the end.** Example: a 10 s window narrowing to 3 s when 5 s
   remain. Today's 10 s window is already held against the end from 5 s remaining. A 3 s window
   centred on the playhead covers 6.5 s to 3.5 s remaining, so the **end leaves the view** until 1.5 s
   remaining, exactly when it matters.

   **Fix: hold the window against the end during and after the zoom.** The window runs from
   `end − L(t)` to `end`, where `end` is the music end when the countdown target is Music end. Add a
   small margin past the end so the marker is visible.
2. **The zoom time follows from the final window.** The playhead must stay inside the window, so the
   remaining time `r` must never exceed the window length `L`. Finishing the zoom at `r = 0.75 × L_end`
   keeps the playhead at least a quarter of the way into the final window. With an eased transition of
   1 s, the zoom starts at `0.75 × L_end + 1 s` remaining:

   | Final window | Zoom starts at | Zoom ends at |
   |---|---|---|
   | 3 s | 3.25 s | 2.25 s |
   | 5 s | 4.75 s | 3.75 s |

   Midway through the 3 s case, about 2.75 s remain and `L` is about 6.5 s, so the playhead stays in view.
   **The menu therefore needs only one new setting, the final window** (Off, 2, 3 or 5 s). No separate
   "when" control is needed, and the operator can't choose a timing that loses the playhead.
3. **The window must use seconds, not whole frames.** At 25 fps, easing 250 frames down to 75 over 25
   frames moves in steps of about 7 frames, and the 50 Hz fields in the active plan need even finer
   steps. Make the window a `ClosedRange<Double>` of seconds, computed from the plan's `ClipTimeline`
   position. The tick labels can stay in whole frames.
4. **Easing:** use smoothstep, `3x² − 2x³`. The zoom depends only on time, so each frame reads on its own
   when jogged and the preview matches the export.
5. **Comes for free:** the highlight box on the full track is drawn from the same window, so it shrinks
   with it.
6. **Things to check in the preview:**
   - The fade to red covers more of the close-up after zooming in.
   - Auto zoom on short tracks uses half the clip, so a final window must be capped at the starting
     window and skipped when it would be larger.
   - Dragging in the close-up during the zoom holds the window, which is fine.
7. **Tests, all headless:**
   - The window length never increases and the playhead is inside the window on every frame.
   - The end stays in view after the zoom.
   - With the option off, every window matches build 10 exactly, so the baseline hashes stay valid.
   - Short tracks and tracks shorter than the final window work.

---

## Suggested shape of the next plan

1. **Settings types.** Add `Equatable`, the font fields, per-feature `enabled` flags, the element
   visibility flags and the final zoom window. Loading must leave build 10 settings unchanged.
   *Pure tests.*
2. **Font helpers.** Resolve the saved font with a fallback, test digit widths, and expose the metrics
   used by the layout. *Pure tests.*
3. **Layout and drawing.** Feed fonts, hidden elements and the end-held zoom window into `CueLayout` and
   `CuePicture`. *Hash tests.*
4. **Clicks in the monitor.** Respect hidden elements and the new zoom window.
5. **Appearance tab controls.** Font pop-ups, checkboxes, the final zoom pop-up and override markers.
6. **Defaults and overrides.** Save as Default, Reset, and the "Same settings for all jobs" switch on top
   of Apply to All.

Items 1–2 and the zoom-window function in item 3 only add new code, so they could start as soon as the
active plan's `CueCore` package exists. Waiting for the active plan to finish avoids conflicts.
