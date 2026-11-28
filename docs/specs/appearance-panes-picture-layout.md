# Appearance Panes and Picture Layout Specification

**Status:** Approved
**Created:** 2026-11-28
**Last Updated:** 2026-11-28

---

## Problem Statement

### What problem does this solve?

The operator cannot arrange the cue picture. The only layout choice is clocks below or above the waveforms, and the title floats freely over everything else: on build 15 it covered the Full track header at Center, the duration at Middle right and the close-up time labels at Bottom right. The Appearance tab does not help either. It is one long list in which settings for the same picture element sit in different places (the close-up's colour, zoom and playhead options are split across three groups), so it gives no picture of what is where.

The smallest worthwhile outcome: the operator arranges the four picture elements from the Appearance tab, the viewer and the export follow, and no element can cover another.

### Who has this problem?

The playout operator preparing cue files for EVS servers, who fits the picture around the server's on-screen display and wants the element they watch most in the place they look.

### How do they solve it today?

- **Clocks:** the Clock position pop-up (Below waveforms or Above waveforms). Elapsed is always left and Remaining always right.
- **Title:** nine anchor positions or a free drag in the viewer. Only the default (Top left) sits in space the layout keeps for it; every other position draws over other elements.
- **Fine placement:** not possible. Safe zones move the whole stack, never one element.

---

## Proposed Solution

### One-Liner

The Appearance tab becomes one pane per picture element; the order of the panes is the top-to-bottom order of the picture, and each pane has an Offset control that nudges its element up or down.

### Key Capabilities

1. **Panes.** Four movable panes (Title, Full track, Close-up, Clocks) hold every setting of their element. Two fixed panes (End warning, Overlay safe zones) and Restore Defaults follow them. Panes collapse.
2. **Order.** Dragging a pane by its grip, or choosing Move Up or Move Down, reorders the panes. The viewer and the export stack the elements in the same order.
3. **Offset.** Each movable pane has an Offset stepper, in picture pixels, that moves only its element, within the free space around it.
4. **Title band.** The title gets its own band in the stack, with Left, Center or Right alignment. It can no longer cover another element.
5. **Clock sides.** A control in the Clocks pane chooses which clock is on the left.

### User Flow

1. **Source/input:** a job is selected and the inspector shows the Appearance tab. The picture is in the default order: Title, Full track, Close-up, Clocks.
2. **User action:** the operator drags the Clocks pane by its grip above Full track, sets Left clock to Remaining, and steps the Clocks Offset down by 10.
3. **Destination/output:** the job's appearance, shown at once in the viewer and written into the exported MXF. Apply to All copies it to the other jobs.
4. **Observable outcome:** in the viewer the clocks sit between the title and the full track, 10 pixels lower than their automatic position, with Remaining on the left. The exported file shows the same picture on the EVS, and nothing is inside the OSD bands.

### Sidebar layout

```
┌ Job | Appearance ───────────────┐
│ ▾ ≡ Title                       │   ≡ grip: drag to reorder,
│     Text      [______________]  │     click for Move Up / Move Down
│     Alignment [Left|Center|Right]│   ▾ disclosure triangle
│     Offset    [   0 px] [▲▼]    │
│ ▾ ≡ Full track                  │
│     Color     [■]               │
│     Offset    [   0 px] [▲▼]    │
│ ▾ ≡ Close-up                    │
│     Zoom window [Auto      ▾]   │
│     Color     [■]               │
│     ☑ Center playhead at start  │
│     ☑ Center playhead at end    │
│     ☑ Dim played audio          │
│     Offset    [   0 px] [▲▼]    │
│ ▾ ≡ Clocks                      │
│     Elapsed   [Medium ▾] [■]    │
│     Remaining [Medium ▾] [■]    │
│     Left clock [Elapsed|Remaining]│
│     Offset    [   0 px] [▲▼]    │
│ ▾ End warning          (fixed)  │
│ ▾ Overlay safe zones   (fixed)  │
│   [Restore Defaults]            │
├─────────────────────────────────┤
│ [Apply to All]                  │
└─────────────────────────────────┘
```

The control labels are a proposal. The exact placement is confirmed under `36_ui-changes-protocol.md` before implementation.

### Feasibility check

- **Uncertainty (technical):** whether a grip drag inside the existing `NSStackView`, hosted in SwiftUI inside a scroll view, feels reliable with panes of very different heights. AppKit has no stock reorder handle, so the drag is custom.
- **Smallest check:** a grip on two panes of the real sidebar, an insertion line while dragging, the move on mouse-up, and the same move from the grip's menu. Run it in the Atlas helper.
- **Observable result:** a pane lands where the insertion line showed it, ten times out of ten, including when the list is scrolled and when the pointer leaves the sidebar. The contrary result is a pane that lands elsewhere, a drag that sticks, or controls that lose their values.
- **Agreed limit:** half a session, sidebar code only, no layout engine work.
- **Stop/replan:** if the drag is unreliable within the limit, ship Move Up and Move Down from the grip's menu alone and record drag as a follow-up. The layout engine (sections B to E) does not depend on the result.
- **Result:** not run.

---

## Acceptance Criteria

Picture positions are in picture pixels of the 1920 × 1080 frame. "Automatic position" means the position before any Offset.

### A. Panes in the Appearance tab

- [ ] Given the Appearance tab, when it opens, then it shows the panes Title, Full track, Close-up and Clocks in the job's order, followed by End warning, Overlay safe zones and Restore Defaults, at the current 318 pt width.
- [ ] Given a pane, when it is open, then it holds every setting of its element as listed in the sidebar layout above, and no picture-element setting appears outside its pane.
- [ ] Given the End warning pane, when it is open, then it holds Fade to red, Solid red at, Countdown to, Fade close-up to red and Fade full track to red. Given the Overlay safe zones pane, then it holds the preset, the four custom values, Show safe-zone guides and the "Safe zones leave too little room" message.
- [ ] Given any pane header, when its disclosure triangle or name is clicked, then the pane collapses to its header or opens again, and the picture does not change.
- [ ] Given panes left collapsed, when the app is relaunched or another job is selected, then the same panes are collapsed. Collapse state belongs to the app, not to the job, and Apply to All and Restore Defaults leave it alone.
- [ ] Given the Clock position pop-up and the nine-anchor Position pop-up of build 17, when the redesign ships, then neither exists; pane order and Alignment replace them.
- [ ] Given the Color wells in the four movable panes, when all panes are open, then the wells share one column. This closes the Color column drift logged on 2026-11-28.
- [ ] Given a job that is exporting, when the Appearance tab is shown, then the panes are dimmed and ignore clicks and drags, as the sidebar does today.

### B. Pane order is picture order

- [ ] Given the default order (Title, Full track, Close-up, Clocks), Elapsed left, all offsets 0 and Left alignment, when the picture is drawn, then every element is at exactly its build 17 position with the same settings.
- [ ] Given a movable pane, when the operator drags its grip, then an insertion line shows where the pane will land among the four movable panes, and releasing the mouse moves the pane there. The fixed panes are never a drop position.
- [ ] Given a drag in progress, when the operator presses Escape or releases outside any valid position, then the order is unchanged.
- [ ] Given a movable pane, when the operator clicks its grip or right-clicks its header, then a menu offers Move Up and Move Down, and choosing one moves the pane one place. Move Up is dimmed on the first movable pane and Move Down on the last.
- [ ] Given a new order, when the pane lands, then the viewer shows the elements in that order from top to bottom within the same edit, and an export of the job has the same picture.
- [ ] Given any of the 24 orders, when safe zones are None, then the layout fits at every clock size and zoom setting ("Safe zones leave too little room" never shows).
- [ ] Given any order and any safe zones, when the picture is drawn, then no element is inside a reserved band and no two elements are closer than 12 pixels, measured between everything they draw (labels, tick labels, cursor marks and the title shadow included).
- [ ] Given an order that cannot fit between the reserved bands, when it is chosen, then the existing give-way order applies (waveform heights, gaps, clock sizes, title size) and, if that is not enough, the message "Safe zones leave too little room" shows and the job cannot be exported, as today.
- [ ] Given a pane was moved, when VoiceOver is on, then it announces the pane and its new place, for example "Clocks, 2 of 4", and Move Up and Move Down are available as actions on the pane.

### C. Offset per pane

- [ ] Given a movable pane, when the operator steps its Offset up by one, then its element moves up 1 pixel in the viewer and the export, and no other element moves. Holding the stepper repeats.
- [ ] Given an Offset field, when it shows a value, then it reads as whole pixels with a sign, for example "+12 px", "0 px" or "−8 px". Positive is up.
- [ ] Given an Offset field, when the operator types a whole number and commits, then the element moves to that offset, or to the nearest allowed offset if the number is outside the free space.
- [ ] Given an element 12 pixels from its neighbour, or at the edge of the frame the layout keeps clear of the picture edges and reserved bands, when the operator steps further that way, then the value stays where it is.
- [ ] Given the Clocks pane, when its Offset changes, then Elapsed and Remaining move together and stay on one baseline.
- [ ] Given offsets that no longer fit (after a reorder, a clock size change or a safe-zone change), when the picture is drawn, then each element uses the nearest offset that still fits, the fields show the offsets in use, and the criteria of section B still hold.
- [ ] Given offsets reduced by a safe-zone change, when the operator sets the safe zones back without editing any Offset, then the earlier picture returns.
- [ ] Given a pane is moved to another place in the order, when it lands, then it keeps its Offset, limited to the free space at its new place.
- [ ] Given the same appearance, when the picture is drawn in the viewer and in an export, then the offsets in use are the same in both.
- [ ] Given an Offset stepper and field, when VoiceOver reads them, then both carry the pane's name, for example "Clocks vertical offset, plus 12 pixels".

### D. Title band

- [ ] Given the Title pane, when Alignment is Left, Center or Right, then the title box sits at the left edge, the centre or the right edge of the content width, inside its own band at the Title pane's place in the order.
- [ ] Given Left alignment and the Title pane first, when the picture is drawn, then the title is exactly where build 17 draws it at Top left.
- [ ] Given a title wider than the content width, when it is drawn, then it shrinks and, at 34 pt, is cut with an ellipsis, as today.
- [ ] Given the viewer, when the operator presses on the title, then nothing is dragged; the title is no longer movable in the viewer, and a click there does what a click on the background does.
- [ ] Given an empty title, when the picture is drawn, then the band keeps its height, so typing a title never moves the other elements.
- [ ] Given the pre-roll slate, when it is drawn, then it ignores pane order, Alignment and offsets, as it ignores the title position today.

### E. Clock sides

- [ ] Given Left clock is Elapsed (default), when the picture is drawn, then Elapsed is left and Remaining right, as in build 17.
- [ ] Given Left clock is Remaining, when the picture is drawn, then Remaining and its label are left-aligned at the left edge and Elapsed and its label right-aligned at the right edge, on the same baseline.
- [ ] Given either setting, when the end warning runs, then the red fade follows the Remaining clock to whichever side it is on, and the clocks keep at least 24 pixels between them.

### F. Saved jobs, Apply to All and Restore Defaults

- [ ] Given a saved job or saved default appearance from build 17 with Clock position Above waveforms, when it loads, then the order is Title, Clocks, Full track, Close-up and the picture matches build 17's.
- [ ] Given a saved job whose title was at Top left, Top center or Top right, when it loads, then the picture matches build 17's.
- [ ] Given a saved job whose title was anywhere else, when it loads, then the title is in the top band with the nearest alignment to its old horizontal position (left third Left, middle third Center, right third Right). This changes that job's picture on purpose.
- [ ] Given a saved order that is damaged (a pane missing, repeated or unknown), when it loads, then every movable pane appears exactly once: known panes keep their saved sequence and missing ones follow in the default order.
- [ ] Given Apply to All, when it runs, then pane order, offsets, Alignment and Left clock are copied with the rest of the look, and the queue's tick marks compare them too. Title text stays per track.
- [ ] Given Restore Defaults, when it is clicked, then order, offsets, Alignment and Left clock return to their defaults with the other appearance settings. Title text is unchanged.
- [ ] Given a job is added, when it is created, then it takes the order, offsets, Alignment and Left clock last set, as it takes the other appearance settings today.

### Edge cases

- [ ] Given zoom is Off, when the Appearance tab is shown, then the Close-up pane keeps its place in the list with only Zoom window enabled, the close-up takes no room in the picture, and the full track uses the taller zoom-Off height at the Full track pane's place.
- [ ] Given two waveforms that end up 12 pixels apart, when the operator clicks near the boundary in the viewer, then the click scrubs the waveform the pointer is over, not its neighbour.
- [ ] Given a colour panel open from a pane, when that pane is moved or collapsed, then the colour panel closes and no colour is lost.
- [ ] Given the sidebar is scrolled, when a pane is dragged toward the top or bottom edge, then the list scrolls so every position can be reached.
- [ ] Given Reduce Motion is on, when a pane moves or collapses, then it changes without animation.

### Error states

- [ ] Given a job starts exporting while a pane is being dragged, when the mouse is released, then the order is unchanged and the status line shows the existing "settings locked" message.
- [ ] Given an edit the job refuses, when the sidebar refreshes, then order, offsets, Alignment and Left clock show the job's stored values, as the other controls do today.

---

## Technical Considerations

### Dependencies

- No new packages. AppKit only, per `47_project-ui-conventions.md` and the decision "Appearance sidebar stays AppKit" (2026-11-27).
- SF Symbol `line.3.horizontal` for the grip (macOS 12 and later; verified in the system symbol list). No dot-grip symbol exists.

### Architecture Notes

**Model (`CueCore`).**
- `CueAppearance` gains the pane order, one whole-pixel offset per movable pane, the title alignment and the left clock. Because they live in the appearance snapshot, Apply to All, the tick comparison, the saved default for new jobs and Restore Defaults pick them up without extra lists.
- `clockPosition` and the job's `labelX` and `labelY` are read only to migrate old data. `labelX`/`labelY` leave `adoptSharedSettings` and `sharesSettings`. Migrating the title needs the job, not only the appearance, because the old position is stored on the job.
- New fields decode with the house pattern `(try? decodeIfPresent) ?? default` (cookbook 122). Store the order as strings and normalise it with one pure function (drop unknowns and repeats, append missing panes in default order); a synthesized enum array would fail the whole appearance on one unknown value.

**Layout (`CueLayout`).**
- `Stack` takes its segment order from the appearance instead of from `ClockPosition`.
- Gaps become a rule per neighbouring pair, taken from build 10: title next to anything, 74.5; clocks next to a waveform, the clock-size-dependent value used today; waveform next to waveform, 72.5. This reproduces both the default and today's clocks-above layout exactly, because gaps are measured between extents and so do not depend on which element is on top.
- The layout returns a title band rectangle. `titleArea` and `extent(of: .title)` become that band, which also makes the `fits` check see the title (today its extent is the whole safe frame and hides overlaps).
- Offsets are applied after give-way and never affect `fits`. The resolution of stored offsets into offsets in use is one pure, deterministic function, tested without drawing. The spec fixes its properties (section C), not its algorithm; a two-pass clamp over the stack is the suggested starting point.
- Clock sides: `extent(of:)` and `drawClock`'s two calls take their side from the appearance. The warning colour already follows the value, not the side.

**Drawing and hit-testing (`CuePicture`, `MonitorView`).**
- Each waveform already draws its own cursor, labels and tags from its own rectangle, so reordering needs no change to waveform drawing.
- `caption` places the box in the title band by alignment. `draggedTitlePosition`, the title hit target, `placeLabel`, `selectPosition`, `anchors` and the Custom status line are removed.
- Hit zones around the waveforms are inflated by 12 pixels vertically and overlap when two waveforms are 12 pixels apart; resolve the overlap by nearest rectangle.

**Sidebar (`CueAppearanceSidebar`).**
- Keep the `NSStackView`. Each pane is one container view (header plus body) so spacing travels with it. Reorder with `insertArrangedSubview(_:at:)`, which moves an already-arranged view (stated in the macOS 27 SDK header, not in the web documentation); do not remove and re-insert.
- One `setOrder` path serves the drag, the menu and the VoiceOver actions, followed by animated layout, `recalculateKeyViewLoop()` and the announcement.
- Drag: a tracking loop on the grip, an insertion line, the move on mouse-up. A live shuffle is avoided because panes of different heights make it oscillate. `updateNSView` must not rebuild the stack during a drag. The drop-index calculation is a pure function in `CueCore`.
- Collapse: a `.disclosure` button that sets the pane body's `isHidden`; `NSStackView` detaches hidden views. State in `UserDefaults`, beside the inspector tab.
- Offset: one clamping setter feeds stepper and field; `valueWraps = false`; a number formatter with a "+" prefix and " px" suffix.
- macOS 26 and later make small controls taller; `prefersCompactControlSizeMetrics` is available if the panes get too long at 318 pt.

**Tests.**
- Unchanged: the 15 baseline hashes of the default, zoom-Off and warning cases, and `testNoSafeZonesClocksBelowEqualsBuild10Constants`.
- Re-recorded on purpose: the five `customTitle` hashes (title at 0.3, 0.6), and the tests of free title travel and title drag (`testTitleTravelMatchesCaptionFormula`, `testTitleDragMatchesBuild10`, `testTitleTravelClampedToUsableArea`, the title hit in `testClickSeeksToBuild10Frame`).
- Generalised: the `stack` and `gaps` helpers in `CueLayoutTests`, the give-way sequence, and the reserved-band sweeps, across all 24 orders.
- New: order normalisation, migration from `clockPosition` and `labelX`, offset resolution, clock sides, drop index.

### Performance

- `CueLayout` stays pure arithmetic computed once per appearance change. Offset resolution is a handful of comparisons.
- A held Offset stepper fires ten edits a second. Each must redraw the viewer without a visible lag and save the job no more often than the title drag does today (deferred save).

### Security

- None. No new files, network use or entitlements.

### Prerequisites

- Operator feedback on build 17 (Fade and End tags) is independent and does not block this work.
- UI placement is confirmed under `36_ui-changes-protocol.md` before the sidebar is changed.

---

## Out of Scope

- Horizontal offsets, and moving Elapsed and Remaining onto different rows.
- Dragging elements in the viewer to reorder or nudge them. The viewer shows the result; the sidebar is the control.
- Free title placement. A title that must sit over a waveform is no longer possible.
- Undo for reordering and offsets. The app has no undo for appearance edits today; Escape cancels a drag in progress, and Restore Defaults resets the layout.
- Menu-bar commands and keyboard shortcuts for Move Up and Move Down. The grip's menu and the VoiceOver actions cover reordering without a drag.
- Reordering or hiding the End warning and Overlay safe zones panes, and hiding a picture element altogether (zoom Off remains the only way to remove the close-up).
- Named saved looks, Apply to Selected and Undo for Apply to All (offered on 2026-11-28, not chosen).
- A miniature layout diagram in the sidebar. The viewer already shows the live result, and the research found no evidence that a diagram adds to it.
- Changes to the pre-roll slate.

---

## Open Questions

| Question | Status | Answer |
|----------|--------|--------|
| What do the up/down controls do? | Resolved | A per-pane Offset stepper (fine nudge). Reordering is by drag. Operator, 2026-11-28. |
| How is a pane dragged, given macOS has no stock handle? | Resolved | A three-bar grip in the header; clicking it offers Move Up and Move Down. Operator, 2026-11-28. |
| What happens to the neighbours when one element is nudged? | Resolved | Nothing. The element moves alone and stops 12 pixels from a neighbour or at a safe zone. Operator, 2026-11-28. |
| Title placement? | Resolved | Own band, Left, Center or Right; anchors and free drag go. Operator, 2026-11-28. |
| One Clocks pane or two? | Resolved | One pane; a control swaps the sides. Operator, 2026-11-28. |
| Where do End warning and Overlay safe zones go? | Resolved | Fixed panes below the movable ones. Operator, 2026-11-28. |
| Are panes collapsible? | Resolved | Yes, state remembered. Operator, 2026-11-28. |
| Where does a floating title go on old jobs? | Resolved | Top band, nearest alignment. Operator, 2026-11-28. |
| Does an empty title keep its band? | Resolved | Yes, so the picture does not jump while typing. Operator, 2026-11-28. |
| Does a moved pane keep its Offset? | Resolved | Yes, limited to the new free space. Operator, 2026-11-28. |
| Left clock as a two-segment control or a Swap button? | Resolved | A two-segment control that shows the state. Operator, 2026-11-28. |
| Is the grip drag reliable in the real sidebar? | Open (settled in the plan) | Feasibility check above. Fallback: menu only. |
| Does the order rule keep every one of the 24 orders fitting at all clock sizes without safe zones? | Open (settled in the plan) | Arithmetic says yes with waveform give-way at Small clocks between the waveforms; a test in section B settles it. |

---

## Decisions

- **2026-11-28 · Pane order is picture order, top to top.** Final Cut Pro's role lanes and `NSStackView` use this convention for stacks that do not overlap. Layer lists (OBS, Motion, Keynote) run front to back instead, which would mislead here.
- **2026-11-28 · Reorder by grip drag with a menu alternative; nudge by Offset stepper.** The operator chose both. WCAG 2.2 SC 2.5.7 and the HIG's drag-and-drop guidance both ask for a way to do a drag without dragging, hence Move Up and Move Down.
- **2026-11-28 · The title gets its own band.** Free placement is the cause of the covering in the build 15 screenshots; the layout already reserved a band that only the default position used.
- **2026-11-28 · Keep `NSStackView`, do not move to a table view.** A table brings row reuse, selection and first-responder rules that fight panes full of controls, for one gain (a stock gap animation).
- **2026-11-28 · Layout settings live in `CueAppearance`.** Apply to All, ticks, defaults for new jobs and Restore Defaults then need no new lists.

---

## Related

- Backlog: [TASKS.md](../TASKS.md) inbox items of 2026-11-28 (swappable positions; Color column drift).
- Previous spec: [batch-presets-cue-tools.md](batch-presets-cue-tools.md), section F (safe zones, give-way order, clocks move as a pair).
- Decisions: [decisions.md](../decisions.md): "Appearance sidebar stays AppKit" (2026-11-27), "Apply to All copies every shared setting" (2026-11-28).
- Session: [2026-11-28](../sessions/2026-11-28.md)
- Directions: `36_ui-changes-protocol.md`, `47_project-ui-conventions.md`, `56_acceptance-criteria.md`, cookbook 122 (tolerant Codable migration).
- Research sources:
  - Final Cut Pro, role order sets lane order: https://support.apple.com/guide/final-cut-pro/veref2bcd518/mac
  - OBS sources list (layer order, up and down buttons): https://obsproject.com/kb/sources-guide
  - WCAG 2.2 SC 2.5.7 Dragging Movements: https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements
  - HIG, drag and drop (offer alternatives): https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
  - HIG, disclosure controls: https://developer.apple.com/design/human-interface-guidelines/disclosure-controls
  - HIG, segmented controls: https://developer.apple.com/design/human-interface-guidelines/segmented-controls
  - `NSStackView.insertArrangedSubview(_:at:)`: https://developer.apple.com/documentation/appkit/nsstackview/insertarrangedsubview(_:at:)
  - Apple sample, stack view with header and disclosure items: https://developer.apple.com/documentation/appkit/organize-your-user-interface-with-a-stack-view
  - `UITableViewCell.showsReorderControl` (the handle exists on iOS, not macOS): https://developer.apple.com/documentation/uikit/uitableviewcell/showsreordercontrol
  - `announcementRequested`: https://developer.apple.com/documentation/appkit/nsaccessibility-swift.struct/notification/announcementrequested
