# Implementation Plan: Appearance panes and picture layout

> **Persists across sessions.** Execute using the shared `commands/execute.md` procedure.
> Repair scheduling errors while preserving task IDs, completed evidence and approved scope.
> Task state/evidence is authoritative here; TASKS links here and holds backlog/inbox.
> Follow the master's `reference/task-state.md` for legacy reconciliation and archival.

**Progress:** 9/13; external acceptance: PU1 approved 2026-11-28; PX1, PX2 and PX3 open.
**Task states:** unchecked = pending / implemented-unverified / blocked (name gate);
checked = complete with required evidence. Task identity includes this plan path plus ID.

This is the second active plan. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) (batch round, 26/26) stays open on its external gates X2, X3 and X4. Task IDs here carry a `P` so the two plans cannot be confused in logs.

## Goal

The operator arranges the four picture elements (Title, Full track, Close-up, Clocks) from the Appearance tab: pane order is picture order, each pane has an Offset, the title has its own band, and the clocks can swap sides. The viewer and the export follow, and no element can cover another.

**Journey (spec → User Flow):** a job is selected and the Appearance tab shows the default order → the operator drags the Clocks pane above Full track, sets Left clock to Remaining and steps the Clocks Offset down by 10 → the job's appearance changes at once in the viewer and is written into the exported MXF; Apply to All copies it → the clocks sit between the title and the full track, 10 pixels lower, Remaining on the left, and nothing is inside the OSD bands.

**Feasibility spike (task P1.3):** whether a grip drag in the real sidebar is reliable. Observable result: a pane lands where the insertion line showed it, ten times out of ten, including with the list scrolled. Limit: half a session, sidebar code only. Stop/replan: if it is unreliable within the limit, ship Move Up and Move Down from the grip's menu alone and record the drag as a follow-up. No layout task depends on the result.

## Acceptance Criteria

The spec's Given/When/Then criteria are authoritative and are not copied here. Each task names the sections it satisfies.

- [ ] A. Panes in the Appearance tab (8 criteria): P2.2, P4.2
- [ ] B. Pane order is picture order (9): P1.1, P1.3, P2.2, P4.2
- [ ] C. Offset per pane (10): P1.2, P2.1, P3.1
- [ ] D. Title band (6): P1.1, P2.2
- [ ] E. Clock sides (3): P2.1, P2.2
- [ ] F. Saved jobs, Apply to All and Restore Defaults (7): P0.1, P0.2, P1.1, P3.2
- [ ] Edge cases (5) and error states (2): P2.1, P2.2, P3.1
- [ ] Performance: a held Offset stepper redraws the viewer without visible lag and saves the job no more often than typing a title does: P3.1, P4.1

## Specs

- [specs/appearance-panes-picture-layout.md](specs/appearance-panes-picture-layout.md): the whole round (sections A–F, edge cases, error states)

---

## Planning findings (2026-11-28)

Facts established while planning that sharpen the spec's technical notes. Sources: the code at `531e91c`, the macOS 27.2 SDK headers, Apple documentation and release notes, headless probes run by two research agents on this Mac (macOS 27.2, Xcode 27.2), and hand arithmetic on the layout constants. Probes were headless: no live VoiceOver speech, no physically held stepper and no macOS 14 or 15 run.

**Layout**

- The pair-gap rule reproduces build 17 exactly. Title next to anything is 74.5; full track next to close-up is 72.5; clocks next to a waveform is today's `gaps[1]`, which depends on the zoom setting and the larger clock size, not on which waveform is the neighbour (Medium 112.88, Small 128.28, Extra large 75.92 with zoom on).
- All 24 orders fit with safe zones None. The default stack leaves about 42 pixels of slack in the 970-pixel safe frame. The worst orders put the clocks between the two waveforms, which costs one extra clock gap: Medium needs 40.4 more pixels and fits unchanged; Small needs 55.8 and the waveforms give way by 14 pixels in total; Large and Extra large need less. This is arithmetic, to be confirmed by the test in P1.1.
- `updateAppearance` saves `queue.json` (every job's waveform) on each edit. A held stepper would rewrite it ten times a second, so Offset edits need the deferred save that title typing uses (P3.1).
- `updateAppearance` returns silently when the job is locked. The spec's error state needs the existing "This job is exporting. Its settings are locked." status there (P2.2).
- **Offset edits store the offsets in use for all four panes.** If only the edited pane were stored, another pane whose stored offset is being limited could spring further when its neighbour moves away, breaking "no other element moves". Storing the four offsets in use on each Offset edit prevents that, and it is what the spec's wording ("sets the safe zones back without editing any Offset") already assumes. Reordering, clock sizes and safe zones never rewrite stored offsets.
- Render hashes are pinned per macOS major version (`BaselineTests.expectedMacOS27` for the M1 Max, `expectedOriginal` for the M4 Pro on macOS 15). Re-recorded and new hashes can only be recorded on the Mac that runs them: gate PX3 covers the other Mac. Geometry fixtures (rectangles and baselines as numbers) are the same on both.

**Sidebar drag (for the spike)**

- `insertArrangedSubview(_:at:)` on an arranged view is a move (`NSStackView.h`: "it will move the view to the specified index (but not change the subview index)"). The index is the final index after removal: from ABCDEF, moving B to 3 gives ACDBEF. The view is not re-added: no `viewDidMoveToSuperview`, constraints unchanged, and a text field being edited inside the moved pane stays first responder (measured).
- Mapping an insertion gap `g` (0…n) for a pane at index `cur`: `g == cur` or `g == cur + 1` is no move; otherwise insert at `g > cur ? g - 1 : g`. Hidden arranged views still count in the indices.
- Custom spacing set with `setCustomSpacing(_:after:)` travels with the view, so spacing inside a pane container moves with it; a gap meant for a position must be reassigned.
- `NSStackView` is not flipped. Convert pane frames to the flipped document view before comparing with the pointer. The drop gap is the number of visible panes whose vertical midpoint is above the pointer; this handles panes of very different heights.
- Tracking loop: `window.trackEvents(matching:timeout:mode:handler:)` with `.leftMouseDragged`, `.leftMouseUp`, `.keyDown` and `.periodic`, plus `.mouseCancelled` on macOS 26 and later. Key events must be consumed in the loop or they replay after mouse-up; Escape is key code 53. A finite timeout plus `NSEvent.pressedMouseButtons` gives a watchdog against a lost mouse-up. `stopPeriodicEvents()` belongs in `defer`; starting periodic events twice raises an exception.
- `autoscroll(with:)` scrolls only when the pointer is outside the clip view (measured). An edge zone inside the sidebar must scroll the clip view by hand on each periodic event and then recompute the insertion line.
- SwiftUI keeps calling `updateNSView` while the run loop is in event-tracking mode (measured for `@Observable` and `ObservableObject`). The host needs an `isTracking` flag: while set, `updateNSView` keeps the latest values and returns; they are applied once after the loop. The new order is written to the model only on mouse-up.
- There is no system drag-threshold constant. Apple's LightTable sample uses 2 points; 4 points is planned to tell a click (menu) from a drag.
- macOS 27 routes `NSControl` interaction through gesture recognizers and events consumed by a tracking loop never reach them. The grip is therefore a plain `NSView` that draws the symbol and has its own `mouseDown` and accessibility role, not an `NSButton` subclass.
- The insertion line is most robust as a sibling overlay in the flipped document view, added after the stack, with `hitTest` returning `nil`.
- `window.recalculateKeyViewLoop()` must be called after the move and its layout; `autorecalculatesKeyViewLoop` does not react to a pure rearrangement (measured). Not yet tried inside a SwiftUI-hosted window: check in the spike.
- Collapse: Apple's stack-view sample animates a height constraint and does not hide the body. Hiding the body also animates (measured as layer animations, not seen on screen) but `clipsToBounds` is off by default since macOS 14 and must be set on the pane. The spike picks one; hiding without animation is always an acceptable result and is the Reduce Motion path anyway.
- A collapsed pane's colour well stays active while hidden. Collapsing must call `deactivate()` and order the colour panel out; deactivating keeps the colour. A move alone does not need it, but the spec asks for the panel to close on a move as well.
- No maintained reorderable-`NSStackView` library exists. Published examples (a 2017 gist and its derivatives) remove and re-add views, which is the cause of lost state; this plan never removes a pane.
- The Atlas helper can drag from point to point (`atlas drag`), and a tracking loop behaves like a slider knob, so the ten drags can run there. Drag-and-drop sessions do not start in the helper, which is another reason not to use `NSDraggingSession`. Escape during a drag and edge autoscroll while holding still may not be reproducible with `atlas drag`; if not, they move to gate PX1.

**Controls and accessibility**

- **The spec's Offset formatter is not enough.** A `NumberFormatter` with a "+" prefix and " px" suffix displays correctly but rejects a typed `12`, `+12`, `-8` and `12px`, and the field then refuses to end editing. The Offset field uses pure `format` and `parse` functions in `CueCore` (unit-tested) wrapped in a small `Formatter` subclass: display "+12 px", "0 px", "−8 px" (U+2212); accept a plain or signed whole number with or without "px"; on anything else, return to the value in use.
- `NSStepper` defaults to `valueWraps = true` and a 0–59 range; both must be set. A held stepper sends one action, pauses 0.5 s, then sends ten a second; the rate is not configurable.
- VoiceOver actions: a pane needs `isAccessibilityElement`, the `.group` role and a label before `accessibilityCustomActions()` is exposed (measured). There is no disabled state, so Move Up is left out on the first pane and Move Down on the last. The pane view must not also override `accessibilityPerformPress` or `accessibilityPerformShowMenu` (a third-party report says the actions then vanish).
- The move announcement: the header says to post `.announcementRequested` to the application element, Apple's sample posts to the main window, and a forum report found only `AccessibilityNotification.Announcement` (macOS 14 and later) reliable. Post `.layoutChanged` first, then the announcement at high priority. Which element is spoken reliably needs a live VoiceOver check (gate PX2).
- The disclosure triangle is an `NSButton` with `.disclosure` bezel (13 × 13). It reads as "disclosure triangle" with value 0 or 1; `setAccessibilityExpanded` must be kept in sync by hand. The clickable pane name calls the same toggle and is hidden from accessibility so VoiceOver meets one labelled control.
- macOS 26 and later draw small controls 4 points taller (20 instead of 16). `prefersCompactControlSizeMetrics` (`NSView`, macOS 26.0, inherited by descendants) restores the earlier metrics and narrows the segmented controls by 16 to 24 points; it needs `if #available(macOS 26.0, *)` and nothing on older systems. Both segmented controls fit 318 points either way (119 to 143 points wide at small size).
- `line.3.horizontal` exists from macOS 12 and loads on this Mac. No grip, dots or drag-handle symbol exists in the system catalogue.
- WCAG 2.2 SC 2.5.7 is met by the click menu (Move Up, Move Down), not by keyboard or VoiceOver actions alone.
- Reduce Motion: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, checked at the moment of each animation.

---

## Control placement (gate PU1 — approved 2026-11-28)

Per the UI changes protocol. Similar existing controls: every Appearance control is built in `CueAppearanceSidebar.init` (`Sources/App/Views/AppKit/CueAppearanceSidebar.swift`), as `NSGridView` rows inside one vertical `NSStackView` in a scroll view. All controls share one action, `edit(_:)`, which changes `settings` and calls the `changed` closure; `AppearanceSidebarRepresentable` passes that to `EditorModel.updateAppearance`, then calls `sidebar.sync(to:)` so a refused edit does not stay on screen. The title text field is owned by the representable's coordinator and reports through `EditorModel.setLabelText`.

Proposed, replacing the flat list in the same file and stack:

```
┌ Job | Appearance ───────────────────┐
│ ▾ ≡ Title                           │  header: triangle, grip, name
│     Text       [________________]   │  the existing field, moved here
│     Alignment  [Left|Center|Right]  │  new, three segments
│     Offset     [   0 px] [▲▼]       │  new
│ ▾ ≡ Full track                      │
│     Color      [■]                  │
│     Offset     [   0 px] [▲▼]       │
│ ▾ ≡ Close-up                        │
│     Zoom window [Auto        ▾]     │
│     Color      [■]                  │
│     ☑ Center playhead at start      │
│     ☑ Center playhead at end        │
│     ☑ Dim played audio              │
│     Offset     [   0 px] [▲▼]       │
│ ▾ ≡ Clocks                          │
│     Elapsed    [Medium ▾] [■]       │
│     Remaining  [Medium ▾] [■]       │
│     Left clock [Elapsed|Remaining]  │  new, two segments
│     Offset     [   0 px] [▲▼]       │
│ ▾   End warning                     │  no grip; rows as today plus
│     Fade to red, Solid red at,      │  Countdown to (moved here)
│     Countdown to, two checkboxes    │
│ ▾   Overlay safe zones              │  no grip; rows as today
│     [Restore Defaults]              │
├─────────────────────────────────────┤
│ [Apply to All]                      │
└─────────────────────────────────────┘
```

The operator approved all eight points as proposed on 2026-11-28 ("PU1 approved"), including removing the "Appearance" heading, the "Dim played audio" label, "layout" in the Apply to All text and the compact control height.

1. **Header.** Disclosure triangle, then the three-bar grip, then the pane name in 13-point semibold. Clicking the triangle or the name collapses or opens the pane. Clicking the grip, or right-clicking anywhere on the header, opens a menu with Move Up and Move Down. Grip tooltip: "Drag to reorder. Click for Move Up and Move Down." The two fixed panes have no grip; their names line up with the others.
2. **Removed.** The Position pop-up (nine anchors and Custom), the Clock position pop-up, and the "Appearance" heading above the list (the tab switch already says it).
3. **One grid per pane with shared column widths** (label 85, control 119, colour 48), so the four colour wells share one column.
4. **Renamed.** "Dim played audio in close-up" becomes "Dim played audio", since it now sits in the Close-up pane. Full track and Close-up colours become a "Color" row each.
5. **Offset row.** A 64-point field showing "+12 px", "0 px" or "−8 px" beside a stepper. Tooltip: "Moves only this element. Positive is up."
6. **Apply to All footer text.** "title position" becomes "layout" in the tooltip and the note ("Copies look, layout and export settings…").
7. **Control height.** On macOS 26 and later the panes use the compact control metrics (the height controls had up to macOS 15), which keeps six open panes about 60 points shorter.
8. **Collapse state** is stored in `UserDefaults` under `WaveformCue.collapsedPanes`, beside the inspector tab.

The spike (P1.3) prototypes the header on a branch that is not merged as it stands. P2.2 and P3.1 change the shipped sidebar; with PU1 approved they wait only for their task prerequisites.

---

## Execution schedule and ownership

- **Execution scope/limits:** Waves 0 through 3 requested on 2026-11-28. PU1 approved. Wave 4 requires a further execution request. Pushes and app control keep their own authorization; Atlas helper runs are covered by the standing authorization in `34_testing.md`.
- **Branch:** `feature/appearance-panes`, created locally from the reconciled build 17 branch in P0.1. Publishing the branch to the other Mac needs separate authorization. The work changes saved-job handling and the picture, so `main` stays at build 17 until P4.4. Merge to `main` is a fast-forward at the build 18 handoff.
- **Paths:** code paths are relative to `01_Project/`; docs are in `docs/`.
- **Coordinator-owned files/resources:** `project.yml`, `WaveformCue.xcodeproj` (regenerated with `xcodegen generate` when files are added), Git and merges, this plan, `PROJECT_STATE.md`, `TASKS.md`, `decisions.md`, `README.md`, `04_Exports/`, and the Atlas helper (one session at a time).
- **Shared build resources:** parallel tasks run in git worktrees under `.claude/worktrees/` (the ignored `.claude/worktrees/zPackages` symlink must exist) and run `swift test` with their own `--scratch-path` and a `--filter` for their own test classes. Only the coordinator runs the full suite and `xcodebuild`, with a `-derivedDataPath` outside the project.
- **Commands:** full suite `FFMPEG_EXECUTABLE=/Applications/Magpie.app/Contents/Resources/ffmpeg swift test --package-path 01_Project/Packages/CueCore`; app build `cd 01_Project && xcodegen generate && xcodebuild -scheme WaveformCue -configuration Debug -derivedDataPath <scratch>/dd build`.
- **Effects class:** `swift test` is headless and writes only to its scratch path and per-test temporary folders. `xcodebuild build` launches nothing. `xcodebuild test` is never used (it launches the app on the desktop). Atlas runs happen in the hidden helper only, with fixtures copied in.
- **Interfaces to establish before dispatch:** the value types and `CueAppearance` fields of P0.2, and the signatures named in each task's Interface line.
- **Staged refactor:** the old forms (`CueAppearance.clockPosition`, `CueJob.labelX`/`labelY`, `CueLabel.position`, the title drag) stay compilable until the app has stopped using them. P0.2 adds the new form, P1.1 to P2.2 move the callers, and P3.2 removes the old form. The removal gate is in P3.2.

Dependency graph (no cycles):

```
P0.1 → P0.2 → P1.1, P1.2, P1.3
P1.1, P1.2 → P2.1
P0.2, P1.1, P1.3, PU1 → P2.2
P2.1, P2.2, PU1 → P3.1          P2.1, P2.2 → P3.2
P3.1, P3.2 → P4.1 → P4.2, P4.3 → P4.4
P4.2 → PX2          P4.4 → PX1          P1.1, P2.1 → PX3
```

Ownership check: within each wave no two tasks write the same file. `CueLayout.swift` and `CuePicture.swift` pass P1.1 → P2.1 → P3.2; `CueAppearanceSidebar.swift` passes P1.3 (branch only) → P2.2 → P3.1; `EditorModel.swift` passes P2.2 → P3.1. `CueAppearance.swift` and `CueJob.swift` pass P0.2 → P3.2.

## Tasks

### Wave 0 (serial foundations — coordinator; each step changes what the next builds on)

- [x] **P0.1**: Branch, baseline and build 17 reference data
  - Depends on / external gates: none
  - Owns: branch `feature/appearance-panes`; new `Packages/CueCore/Tests/CueCoreTests/Build17LayoutTests.swift` and its fixture `Fixtures/build17-layouts.json`; one added `clocksAbove` case in `BaselineTests.swift`
  - Detail: before any layout code changes, record what build 17 draws. (1) A geometry fixture written by today's `CueLayout`: for both clock positions × zoom Off and Auto × all 16 clock-size pairs × safe zones None, EVS OSD and three custom sets, the full-track and close-up rectangles, clock baseline, clock sizes after give-way, title size, top-left title box origin and height, and `fits`. Numbers only, so it is valid on both Macs. (2) Five pixel hashes for a clocks-above appearance, recorded with `CUE_RECORD_BASELINE=1` into the table of the macOS version in use.
  - Interface: `Build17LayoutTests` loads the fixture and compares it with `CueLayout` for the same inputs; P1.1 changes only how the test builds its inputs (clock position becomes pane order).
  - Success: the suite passes at the recorded count with the new test and case included; the fixture is committed.
  - Backpressure: the full-suite command; the count and commit recorded in the Execution Log

- [x] **P0.2**: Shared value types and appearance fields (spec F, model part)
  - Depends on / external gates: P0.1
  - Owns: new `Packages/CueCore/Sources/CueCore/PictureArrangement.swift`; `CueAppearance.swift`; `Queue/CueJob.swift` (decoding only); new `PictureArrangementTests.swift`; the decoding tests in `RenderTests.swift` and `CueJobTests.swift`
  - Detail: `PicturePane` (title, fullTrack, closeUp, clocks; display names; default order), `TitleAlignment` (left, center, right), `LeftClock` (elapsed, remaining), `PaneOffsets` (one whole-pixel `Int` per pane, positive is up). `CueAppearance` gains `paneOrder`, `offsets`, `titleAlignment` and `leftClock`, decoded with `(try? decodeIfPresent) ?? default` (cookbook 122). The order is stored as strings and passed through one pure `PicturePane.normalised(_:)`: unknown and repeated names are dropped, known panes keep their saved sequence, missing ones follow in default order. Migration at decode: no `paneOrder` key and `clockPosition` above gives Title, Clocks, Full track, Close-up. In `CueJob.init(from:)`, an appearance without a `titleAlignment` key takes the alignment nearest the saved `labelX` (left third Left, middle third Center, right third Right). `clockPosition` stays as a computed shim derived from and applied to `paneOrder`, so the app and the old tests still compile; it is no longer encoded. Nothing reads the new fields for drawing yet.
  - Interface: the four types and fields above, frozen for P1.1, P1.2, P1.3 and P2.2.
  - Success: tests for normalisation (missing, repeated, unknown, empty), both migrations, a build 17 appearance and job decoding to build 17 behaviour, round trips, and `AppearanceSnapshot` equality seeing the new fields (so the queue's tick comparison does). The app builds unchanged.
  - Backpressure: the full-suite command; the app build command

### Wave 1 (parallel — three tasks; file sets are disjoint)

- [x] **P1.1**: Layout by pane order, pair gaps and the title band (spec B, D, F)
  - Depends on / external gates: P0.2
  - Owns: `CueLayout.swift`; `CuePicture.swift` (`caption`, both `hitTarget` functions); the `layout` entry point in `CueAppearance.swift`; `CueLayoutTests.swift`, `RenderTests.swift`, `TrimPreRollTests.swift`, `BaselineTests.swift`, `Build17LayoutTests.swift`
  - Detail: `Stack` takes its segments from `appearance.paneOrder` (the close-up is skipped with zoom Off). Gaps come from the pair rule in the planning findings; give-way keeps today's order (waveform heights, gaps, clock sizes, title size). The layout returns a title band rectangle at the Title pane's place: `titleArea` and `extent(of: .title)` become that band, so `fits` sees the title. An empty title keeps the band. `caption` places the box in the band by `titleAlignment` and ignores `CueLabel.position`; width fitting and the ellipsis at 34 points stay. `hitTarget` no longer returns `.title`, so a press on the title acts like a press on the background (the app's drag code goes quiet without being edited). The slate is untouched.
  - Interface: `CueLayout.init(appearance:)` reads order, alignment and safe zones from the appearance; `CueLayout.titleBand: CGRect`; `CueLayout.paneOrder`. The `clockPosition:` initialiser parameter is removed; tests build an order instead.
  - Success: `Build17LayoutTests` passes for both old clock positions through the migration; the 15 default, zoom-Off and warning hashes and `testNoSafeZonesClocksBelowEqualsBuild10Constants` are unchanged; the `clocksAbove` hashes from P0.1 are unchanged; the five `customTitle` hashes are re-recorded on purpose for the macOS in use and the other table's five entries are marked pending for PX3 (skipped with a message, not failed); the tests of free title travel and title drag are replaced by band and alignment tests; the `stack` and `gaps` helpers, the give-way sequence and the reserved-band sweeps run across all 24 orders; a new test shows all 24 orders fit at every clock-size pair and zoom setting with safe zones None; every pair of neighbouring extents is at least 12 pixels apart in every swept case.
  - Operator decision (2026-11-28): enforce the 12-pixel gap in blocked previews too. Keep all 256 exportable fixture rows exact and compare the other 64 against explicit placement differences. The original build 17 fixture remains the reference.
  - Backpressure: `swift test --package-path 01_Project/Packages/CueCore --scratch-path <scratch> --filter 'CueLayoutTests|RenderTests|TrimPreRollTests|BaselineTests|Build17LayoutTests'`, then the full suite at merge

- [x] **P1.2**: Offset resolution as a pure function (spec C, arithmetic only)
  - Depends on / external gates: P0.2
  - Owns: new `Packages/CueCore/Sources/CueCore/OffsetResolver.swift`, `OffsetText.swift`; new `OffsetResolverTests.swift`, `OffsetTextTests.swift`
  - Detail: `OffsetResolver.resolve` turns stored offsets into offsets in use for elements given as vertical spans from top to bottom, a frame and a minimum gap of 12. `OffsetResolver.limits` gives the range one element may take while the others hold their offsets in use. A two-pass clamp over the stack is the starting point; the spec fixes the properties, not the algorithm. `OffsetText.format` and `parse` implement the Offset field's text (see planning findings).
  - Interface: `resolve(stored: [Int], spans: [ClosedRange<CGFloat>], frame: ClosedRange<CGFloat>, gap: CGFloat) -> [Int]`; `limits(index: Int, inUse: [Int], spans:, frame:, gap:) -> ClosedRange<Int>`; `OffsetText.format(_: Int) -> String`; `OffsetText.parse(_: String) -> Int?`. An absent element (close-up with zoom Off) is simply not in the arrays.
  - Success: property tests over generated stacks: stored offsets that fit are returned unchanged; every result keeps all neighbours at least 12 apart and inside the frame whenever the automatic positions do; each offset in use has the sign of its stored value and is no larger in size; the result is the same for the same inputs and whole pixels throughout, including with half-pixel spans; relaxing the frame returns the earlier result; two neighbours stored toward each other resolve by a documented rule; `limits` never allows a step that `resolve` would undo; a stack with no free space gives all zeros. Text tests: "+12 px", "0 px", "−8 px" out; `12`, `+12`, `-8`, `−8`, `12 px`, `12px` in; `abc`, `12.5` and the empty string rejected.
  - Backpressure: `swift test … --filter 'OffsetResolverTests|OffsetTextTests'`

- [x] **P1.3**: Feasibility spike: grip drag in the real sidebar (spec B; the spec's Feasibility check)
  - Depends on / external gates: P0.2. The sidebar edit stays on the task's branch.
  - Owns: new `Packages/CueCore/Sources/CueCore/PaneReorder.swift` and `PaneReorderTests.swift`; new `Sources/App/Views/AppKit/SidebarPaneView.swift` and `PaneDragController.swift`; a temporary edit of `CueAppearanceSidebar.swift` on the spike branch only; evidence in the session log
  - Detail: build the pane container (header with disclosure triangle, grip and name; body) and the drag controller as new files, following the planning findings: tracking loop with watchdog, 4-point threshold, insertion line in an overlay, move on mouse-up through `insertArrangedSubview`, Escape cancels, a plain click opens the Move Up / Move Down menu, edge scrolling by hand, `isTracking` deferral in the host. Wire two panes of the real sidebar (Clocks and the waveform rows) on the branch. Also try collapsing (hidden body against height constraint) and `recalculateKeyViewLoop()` in the SwiftUI-hosted window, and note which works.
  - Limit: half a session, sidebar code only, no layout engine work.
  - Interface: `PaneReorder.dropGap(pointerY:paneMidYs:) -> Int`, `PaneReorder.move(_ order: [PicturePane], from: Int, toGap: Int) -> [PicturePane]` (no-op gaps return the order unchanged), `canMoveUp`/`canMoveDown`; `SidebarPaneView(title:movable:body:)` with `isCollapsed`; `PaneDragController` reporting one `(from, toGap)` on a completed drag. P2.2 builds on these.
  - Success: in the Atlas helper, ten drags out of ten land where the insertion line showed, some with the list scrolled and some released outside the sidebar (no move); the menu makes the same moves; control values and an active text field survive each move. Record what could not be driven through `atlas drag` (Escape mid-drag, edge scrolling while holding still).
  - Stop/replan: if the drag is unreliable at the limit, keep `PaneReorder`, `SidebarPaneView` and the menu, drop `PaneDragController` from P2.2, add a drag follow-up to TASKS and record it under Blocked Tasks. P1.1, P1.2 and P2.1 are unaffected.
  - Backpressure: `swift test … --filter PaneReorderTests`; the app build command; Atlas screenshots of the ten drags

### Wave 2 (parallel — two tasks; one in the package, one in the app)

- [x] **P2.1**: Offsets, clock sides and hit zones in the picture (spec C, E, edge cases)
  - Depends on / external gates: P1.1, P1.2
  - Owns: `CueLayout.swift`, `CuePicture.swift` (`drawClock`, hit zones), `CueLayoutTests.swift`, `RenderTests.swift`, new `ClockSideTests.swift`
  - Detail: after give-way the layout resolves `appearance.offsets` with `OffsetResolver` and shifts each element's rectangles (the clocks move as a pair on one baseline). Offsets never change `fits`; a layout that does not fit uses zeros. Clock sides: `extent(of:)` and the two `drawClock` calls take their side from `leftClock`; the warning colour keeps following the Remaining value; the 24-pixel pair gap holds. Waveform hit zones are inflated by 12 pixels and can overlap when two waveforms are 12 apart: the nearer rectangle wins.
  - Interface: `CueLayout.offsetsInUse: PaneOffsets`; `CueLayout.offsetLimits(for: PicturePane) -> ClosedRange<Int>`; `CueLayout.leftClock`. P3.1 reads the first two.
  - Success: with all offsets 0 and Elapsed left, every P1.1 result is unchanged (fixture and hashes); a one-pixel step moves only that element's extent; offsets in use are equal for the same appearance however the layout is created (viewer and export share `appearance.layout`); the reserved-band and 12-pixel sweeps of P1.1 pass again with random stored offsets across the 24 orders; a safe-zone change and its reversal returns the earlier layout; Remaining left puts its extent and label at the left edge on the shared baseline; a point between two waveforms 12 apart hits the one it is nearer to.
  - Backpressure: `swift test … --filter 'CueLayoutTests|RenderTests|ClockSideTests|Build17LayoutTests|BaselineTests'`

- [x] **P2.2**: The Appearance tab as panes (spec A, B, D, E controls, edge cases, error states)
  - Depends on / external gates: P0.2, P1.1, P1.3; **PU1**
  - Owns: `Sources/App/Views/AppKit/CueAppearanceSidebar.swift`, `AppearanceSidebarRepresentable.swift`, `SidebarPaneView.swift`, `PaneDragController.swift`, `MonitorView.swift`, `MonitorRepresentable.swift`; `Sources/App/Views/InspectorPane.swift`; in `EditorModel.swift` the label and appearance section only
  - Detail: regroup every control into the six panes of the confirmed placement; the title field moves into the Title pane. New Alignment and Left clock segmented controls write `titleAlignment` and `leftClock`. The Position and Clock position pop-ups go, with `EditorModel.anchors`, `positionIndex`, `selectPosition`, `placeLabel`, the Custom status line, and the title drag in `MonitorView` (`labelOrigin`, `onPlace`). One `setOrder` path serves the drag, the menu and the VoiceOver actions: it writes `paneOrder`, moves the pane views, lays out (animated unless Reduce Motion is on), recalculates the key-view loop, posts the layout change and announces "Clocks, 2 of 4". `sync(to:)` reorders the pane views when the job's order differs (another job selected, Apply to All, Restore Defaults, a refused edit) and is deferred while a drag is tracking. Collapse state lives in `UserDefaults` and is untouched by Apply to All and Restore Defaults. With zoom Off the Close-up pane keeps its place with only Zoom window enabled. Moving or collapsing a pane closes the colour panel. `updateAppearance` sets the "settings locked" status when the job refuses the edit, and a drag that ends after the job locked changes nothing. Restore Defaults keeps resetting the whole appearance and leaves the title text alone.
  - Interface: `CueAppearanceSidebar` keeps `sync(to:)` and `closeColorPicker()`; each movable pane's body ends with an empty Offset row slot that P3.1 fills.
  - Success: the app builds with no reference left to the removed members; reordering by menu and by drag changes the viewer in the same edit; Atlas pass over spec A (all eight), B (drag, Escape where drivable, menu and its dimmed items, order follows the selected job), D (three alignments, no title drag, empty title keeps the band) and the Left clock control's stored value; relaunch keeps collapsed panes; an exporting job dims the panes.
  - Note: Left clock is drawn by P2.1, which runs beside this task. The control is checked on screen in P4.1 after both have merged.
  - Backpressure: the app build command; full suite (unchanged count); Atlas screenshots per criterion

### Wave 3 (parallel — two tasks; one in the app, one in the package)

- [x] **P3.1**: Offset rows (spec C controls, performance)
  - Depends on / external gates: P2.1, P2.2; **PU1**
  - Owns: `CueAppearanceSidebar.swift`, `SidebarPaneView.swift`, new `Sources/App/Views/AppKit/OffsetFormatter.swift`; `EditorModel.updateAppearance` (deferred save)
  - Detail: each movable pane gets a field and a stepper fed by one clamping setter. The field and stepper show the offset in use (`layout.offsetsInUse`), not the stored value, and refresh after every appearance change. An edit clamps to `layout.offsetLimits(for:)` and stores the offsets in use of all four panes with the edited one changed (planning findings). Stepper: `valueWraps = false`, explicit range, autorepeat. Field: `OffsetFormatter` over `OffsetText`; unparsable text returns to the value in use. Stepper edits use a deferred save; the viewer redraws on every step. Accessibility labels carry the pane name ("Clocks vertical offset") and the value reads as "plus 12 pixels".
  - Success: Atlas pass over spec C: one step moves one element by one pixel; holding repeats; typed 500 lands on the nearest allowed offset; at 12 pixels from a neighbour or at the frame edge the value stays; the Clocks pair moves together; after a reorder or a safe-zone change the fields show the offsets in use; setting the safe zones back restores the picture; a moved pane keeps its Offset. `queue.json` is written once after a burst of steps, not per step.
  - Backpressure: the app build command; full suite; Atlas screenshots; modification times of `queue.json` in the helper during a held stepper

- [x] **P3.2**: Remove the old forms (spec F; the refactor's removal gate)
  - Depends on / external gates: P2.1, P2.2
  - Owns: `CueAppearance.swift`, `Queue/CueJob.swift`, `CueTypes.swift`, `CuePicture.swift` (removals only), `Queue/QueueManager.swift` if it names the fields; `CueJobTests.swift`, `QueueManagerTests.swift`, `CueTypesTests.swift`, and any test still building `CueLabel` with a position
  - Removal gate: `grep -rnE 'clockPosition|labelX|labelY|draggedTitlePosition|placeLabel|selectPosition|positionIndex|label\.position|HitTarget\.title|case \.title' 01_Project/Sources` finds no use of the old members.
  - Detail: `clockPosition` and `labelX`/`labelY` become decode-only migration inputs and are no longer stored properties or encoded. `labelX`/`labelY` leave `adoptSharedSettings` and `sharesSettings`; the new layout fields are already covered by the appearance snapshot. `CueLabel.position`, `CuePicture.draggedTitlePosition` and `HitTarget.title` are removed. `ClockPosition` stays only as the migration's decoding type.
  - Success: Apply to All copies order, offsets, Alignment and Left clock and leaves title text alone; the tick comparison differs when any of them differs; Restore Defaults returns them to defaults (a default `CueAppearance`); a new job takes the last-set values; a build 17 `queue.json` fixture loads, saves and reloads with the same picture. The app builds against the reduced API.
  - Backpressure: `swift test … --filter 'CueJobTests|QueueManagerTests|CueTypesTests|PictureArrangementTests'`; the app build command at merge

### Wave 4 (verification and handoff)

- [ ] **P4.1**: Full integration run (serial: needs both lanes merged and the machine to itself)
  - Depends on / external gates: P3.1, P3.2
  - Owns: evidence in the Execution Log; a viewer-against-export case in `ExportIntegrationTests.swift`
  - Success: the whole suite passes with FFmpeg present and no skipped integration test; an exported frame of a reordered, offset, Remaining-left job decodes to the same layout the viewer draws; Left clock and the end warning checked on screen in the helper (the red fade follows Remaining to the left); the render benchmark is within 5 % of the 6.1 record.
  - Backpressure: `FFMPEG_EXECUTABLE=… CUE_BENCH=1 swift test --package-path 01_Project/Packages/CueCore` with zero failures

- [ ] **P4.2**: Acceptance pass in the Atlas helper
  - Depends on / external gates: P4.1
  - Owns: a criterion checklist in `docs/sessions/`, with screenshots
  - Success: every spec criterion in A–F, the edge cases and the error states is marked verified, not verified or externally gated, each with a screenshot, a test name or a decoded-file measurement. Accessibility is checked as far as the helper allows: the pane groups, their actions and the labels are read from `atlas elements`; spoken output goes to PX2. Fixtures are copied in; no operator file is used; the helper is cleaned up.
  - Backpressure: the checklist, with no unexplained gaps

- [ ] **P4.3**: Review
  - Depends on / external gates: P4.1
  - Owns: review report; findings return to the owning task's files
  - Success: `/shell-check` reports no new violation; a fresh read-only review of the diff since `531e91c` (package and app, saved-job migration first) has its confirmed findings fixed and the affected tests re-run.
  - Backpressure: shell-check output and the re-run results

- [ ] **P4.4**: Build 18 handoff and documentation
  - Depends on / external gates: P4.2, P4.3
  - Owns: `04_Exports/0.1-18/`, `README.md`, `decisions.md`, `PROJECT_STATE.md`, `TASKS.md`, the merge to `main`
  - Success: Release build in `04_Exports/0.1-18` verified and handed off per `reference/log/app-handoff.md`; README describes the panes, order, Offset, title band and clock sides; the two inbox items of 2026-11-28 (swappable positions, Color column drift) are closed with links; the branch is merged by fast-forward. A push is offered, not done unasked.
  - Backpressure: `xcodebuild -configuration Release … build`, `codesign --verify --deep --strict`

## External checks

- [x] **PU1**: Confirm the control placement proposed above
  - Evidence (2026-11-28): the operator replied "PU1 approved" to the eight points, with no changes.
  - Requires: the operator
  - Gates: P2.2 and P3.1. Does not gate P0.1, P0.2, P1.1, P1.2, P1.3, P2.1 or P3.2's package work.
  - Success / verification: the eight points are confirmed or corrected, and this section is updated with the date.
  - While unavailable: Waves 0 and 1 and P2.1 proceed.

- [ ] **PX1**: Operator acceptance of build 18
  - Depends on: P4.4
  - Requires: the operator, on the desktop and on the EVS
  - Gates: the journey's observable outcome and overall completion.
  - Success / verification: the flow in the Goal run by hand (drag Clocks above Full track, Remaining left, Offset −10); a reordered export shown on the EVS with nothing inside the OSD bands; a build 17 queue opened in build 18 with titles where the spec says; anything the helper could not drive in P1.3 (Escape during a drag, scrolling at the list's edge while dragging).
  - While unavailable: nothing else waits on it; the plan stays open.

- [ ] **PX2**: VoiceOver check
  - Depends on: P4.2
  - Requires: a person with VoiceOver on, on the desktop
  - Gates: spec B's announcement criterion and spec C's spoken Offset label.
  - Success / verification: moving a pane with the Actions menu speaks "Clocks, 2 of 4"; Move Up is absent on the first pane; the Offset stepper and field are spoken with the pane name and "plus 12 pixels". If the announcement is not spoken, try the other two posting routes in the planning findings.
  - While unavailable: the criteria stay "implemented, not verified".

- [ ] **PX3**: Pixel hashes on the other Mac
  - Depends on: P1.1, P2.1
  - Requires: the M1 Max (macOS 27). Wave 0 ran on the M4 Pro (macOS 15).
  - Gates: the five `customTitle` entries and five `clocksAbove` entries of `BaselineTests.expectedMacOS27`.
  - Success / verification: on macOS 27, record the five clocks-above references using the original build 17 renderer at `2b8f028` with its layout-aware overview path. Compare the new renderer against those references, record the intentional five custom-title changes, verify the 15 unchanged hashes, then commit the table.
  - While unavailable: skip only the pending entries with a message on macOS 27. The geometry fixture covers both Macs.

---

## Operational Learnings

- The neighbour-gap check uses rounded picture positions. Build 17’s nearest-pixel rounding sometimes left 11.5 pixels in blocked previews. A hidden title can also leave a fitting automatic extent half a pixel past the safe frame. The offset resolver preserves zero there and permits inward movement.

## Blocked Tasks

- None. PU1 approved 2026-11-28.

---

## Execution Log

| Wave / task IDs | Assignments or serial reason | Validation / evidence | Commits or exception | Remaining gates / next action or stop reason |
|---|---|---|---|---|
| 0 / P0.1 | Coordinator, first prerequisite | Original build 17 produced 320 geometry cases and five clocks-above hashes on macOS 15. Reconciled branch matched all of them. Full suite passed 304/304 with FFmpeg, benchmarks and EVS samples enabled. | `a2b58e6` | P0.2 follows. PX3 still requires macOS 27. |
| 0 / P0.2 | Coordinator after P0.1. A fresh independent reviewer checked the migration and its fix. | A job emitted by build 17 migrates and round-trips. Corrupt entries preserve their valid neighbours. Legacy title edits update the job and editor copy. All 309 tests passed with zero skips. Debug app built, signature verified and helper launch checked. [Session evidence](sessions/2026-11-28.md#appearance-panes-wave-0) | `0b9c441` | Selected Wave 0 complete. Wave 1 (P1.1–P1.3) ready. PX1–PX3 open. |
| 1 / P1.1 | Fresh picture-layout agent, coordinator integrated; independent review checked the corrections | 64 focused tests, 256 exact exportable references, 64 explicit blocked-preview deltas, 3,072 fitting combinations. Full suite 327/327, no skips. Integrated viewer and title click verified. [Wave 1 validation](sessions/2026-11-28.md#appearance-panes-wave-1) | `7e68cfa`, countdown assertion `1eea36a` | P2.1 and P2.2 ready. PX3 still needs macOS 27. |
| 1 / P1.2 | Fresh offset agent plus independent review | 10 focused tests, including generated stacks and fractional automatic edges. Full suite passed. | `101c33a`, `dd5f1cb` | P2.1 integrates offsets. |
| 1 / P1.3 | Fresh sidebar agent, coordinator built and drove the Atlas helper, independent reviewer checked job identity and lock | 3 pure tests; 10/10 releases in the real sidebar. Control values and title focus held. Click menus, collapse and reopen checked. [Wave 1 validation](sessions/2026-11-28.md#appearance-panes-wave-1) | Feature `ede37a5`, `591f60d`. Prototype wiring on `wave1/sidebar-trial` at `adecd01`. | Keep dragging for P2.2. Physical Escape and stationary edge scrolling remain in PX1. |
| 2 / P2.1 | Fresh package worktree, reviewed independently and integrated by coordinator | 61 focused tests passed. All 320 geometry fixtures and protected macOS 15 hashes passed, including 9,408 additional offset cases and ink checks of both clock sides. [Picture checks](sessions/evidence/appearance-panes-wave2/README.md#picture) | `d140edd` | P3.1 and P3.2 ready with P2.2. PX3 needs macOS 27. |
| 2 / P2.2 | Fresh sidebar worktree, independent review, coordinator handled queue integration and Atlas | Full suite 336/336. All 48 queue tests reran after the synchronous lock correction. Atlas verified pane order, menu and grip moves, job selection, alignment, clock sides, export locking, restored defaults and collapse after relaunch. [Inspector checks](sessions/evidence/appearance-panes-wave2/README.md#inspector) | `ec1c3d2` | Selected Wave 2 complete. Wave 3 is ready. PX1–PX3 remain open. |
| 3 / P3.1 | Fresh app worktree, independent review, coordinator integrated the queue delay and verified the real inspector | 338/338 suite. A single held step advanced twice, updated the viewer before release and produced one queue write. Limits, safe-zone restoration, invalid edits and pane moves passed. [Offset evidence](sessions/evidence/appearance-panes-wave3/README.md#offset-controls) | `2f03818` | Wave 4 starts at P4.1. PX2 covers speech. |
| 3 / P3.2 | Fresh package worktree, independent review, coordinator updated the monitor adapter | 121 focused tests. The build 17 queue saved without the three old keys and reloaded to the same pixels. Apply to All, match ticks, import and Restore Defaults passed. The signed app built and ran. [Saved jobs](sessions/evidence/appearance-panes-wave3/README.md#saved-jobs-and-defaults) | `4ad214a` | Selected Wave 3 complete. PX1–PX3 remain open. |

---
*Keep active while required work or acceptance is incomplete. On completion, archive with execution
evidence and update incoming links before retiring the active copy.*
