import AppKit
import CueCore

private final class SidebarDocument: NSView {
    override var isFlipped: Bool { true }
}

/// The two menus store one PostScript name. A missing saved face is displayed using the
/// same resolved face as the renderer, without overwriting the saved name.
@MainActor
private final class FontPickers {
    let family = NSPopUpButton()
    let style = NSPopUpButton()
    private let role: CueFonts.Role
    private let families: [String: [CueFonts.Face]]
    private let faces: [String: CueFonts.Face]
    private var styles: [CueFonts.Face] = []

    init(role: CueFonts.Role, label: String) {
        self.role = role
        let candidates = role == .clock ? CueFonts.clockCandidates() : CueFonts.titleCandidates()
        families = Dictionary(grouping: candidates, by: \.family)
        faces = Dictionary(uniqueKeysWithValues: candidates.map { ($0.postScriptName, $0) })
        family.addItems(withTitles: families.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        family.setAccessibilityLabel(label + " font family")
        style.setAccessibilityLabel(label + " font style")
        for picker in [family, style] {
            (picker.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
    }

    func display(_ name: String?) {
        let resolved = CueFonts.resolve(name: name, role: role)
        guard let face = faces[resolved.postScriptName] else { return }
        family.selectItem(withTitle: face.family)
        let familyFaces = families[face.family] ?? []
        if styles != familyFaces {
            styles = familyFaces
            style.removeAllItems()
            for (index, choice) in styles.enumerated() {
                // addItem(withTitle:) coalesces duplicate style names.
                style.menu?.addItem(withTitle: choice.style, action: nil, keyEquivalent: "").tag = index
            }
        }
        if let index = styles.firstIndex(of: face) { style.selectItem(at: index) }
    }

    func selection(from sender: NSControl) -> String? {
        if sender === style, styles.indices.contains(style.indexOfSelectedItem) {
            return styles[style.indexOfSelectedItem].postScriptName
        }
        guard sender === family, let name = family.titleOfSelectedItem, let choices = families[name] else {
            return nil
        }
        return (choices.first { $0.style == style.titleOfSelectedItem }
                ?? choices.first { $0.style == "Regular" } ?? choices.first)?.postScriptName
    }
}

@MainActor
final class CueAppearanceSidebar: NSView {
    static let sidebarWidth: CGFloat = 318
    private let elapsedSize = NSPopUpButton()
    private let remainingSize = NSPopUpButton()
    private let elapsedColor = NSColorWell()
    private let remainingColor = NSColorWell()
    private let overviewColor = NSColorWell()
    private let detailColor = NSColorWell()
    private let warning = NSPopUpButton()
    private let solidRedAt = NSPopUpButton()
    private let fadeFullTrack = NSButton(checkboxWithTitle: "Fade full track to red", target: nil, action: nil)
    private let fadeCloseUp = NSButton(checkboxWithTitle: "Fade close-up to red", target: nil, action: nil)
    private let zoom = NSPopUpButton()
    private let centerAtStart = NSButton(checkboxWithTitle: "Center playhead at start", target: nil, action: nil)
    private let centerAtEnd = NSButton(checkboxWithTitle: "Center playhead at end", target: nil, action: nil)
    private let dimPlayedCloseUp = NSButton(checkboxWithTitle: "Dim played audio", target: nil, action: nil)
    private let endZoom = NSPopUpButton()
    private let titleFont = FontPickers(role: .title, label: "Title")
    private let clockFont = FontPickers(role: .clock, label: "Clock")
    private let showTitle = NSButton(checkboxWithTitle: "Show title", target: nil, action: nil)
    private let showElapsed = NSButton(checkboxWithTitle: "Show elapsed clock", target: nil, action: nil)
    private let showRemaining = NSButton(checkboxWithTitle: "Show remaining clock", target: nil, action: nil)
    private let showFullTrack = NSButton(checkboxWithTitle: "Show full track", target: nil, action: nil)
    private let safeZonesEnabled = NSButton(checkboxWithTitle: "Safe zones", target: nil, action: nil)
    private let countdownTarget = NSPopUpButton()
    private let alignment = NSSegmentedControl(labels: TitleAlignment.allCases.map { $0.rawValue.capitalized },
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let leftClock = NSSegmentedControl(labels: LeftClock.allCases.map { $0.rawValue.capitalized },
                                               trackingMode: .selectOne, target: nil, action: nil)
    private let safeZonePreset = NSPopUpButton()
    private let showGuides = NSButton(checkboxWithTitle: "Show safe-zone guides", target: nil, action: nil)
    private let zoneNames = ["Top", "Bottom", "Left", "Right"]
    private let zoneSteppers = (0..<4).map { _ in NSStepper() }
    private let zoneValues = (0..<4).map { _ in NSTextField(labelWithString: "0 %") }
    private let roomMessage = NSTextField(wrappingLabelWithString: "Safe zones leave too little room")
    private var customZoneRows: [NSGridRow] = []
    private var roomMessageRow: NSGridRow?
    private var offsetRows: [PicturePane: NSGridRow] = [:]
    private static let collapsedKey = "WaveformCue.collapsedPanes"
    private var settings: CueAppearance
    private let factory = CueAppearance()
    private var paneViews: [PicturePane: SidebarPaneView] = [:]
    private let paneStack = NSStackView()
    private var dragController: PaneDragController?
    private var pendingDisplay: (CueAppearance, Int?)?
    private var clockFrames: Int?
    private var overrideRows: [(label: NSControl, title: String, settings: [CueAppearance.Setting])] = []
    typealias ReorderTarget = (jobID: UUID?, appearance: CueAppearance, isEditable: Bool)
    private let reorderTarget: () -> ReorderTarget?
    private let changed: (CueAppearance) -> Void

    init(settings: CueAppearance, clockFrames: Int?, labelField: NSTextField,
         reorderTarget: @escaping () -> ReorderTarget?, reportLocked: @escaping () -> Void,
         changed: @escaping (CueAppearance) -> Void) {
        self.settings = settings
        self.clockFrames = clockFrames
        self.reorderTarget = reorderTarget
        self.changed = changed
        super.init(frame: .zero)

        if #available(macOS 26.0, *) { prefersCompactControlSizeMetrics = true }
        alignment.setAccessibilityLabel("Title alignment")
        leftClock.setAccessibilityLabel("Left clock")
        for (name, picker) in [("Elapsed", elapsedSize), ("Remaining", remainingSize)] {
            picker.addItems(withTitles: ClockSize.allCases.map { $0.rawValue })
            picker.setAccessibilityLabel(name + " size")
            picker.target = self
            picker.action = #selector(edit(_:))
        }
        for (name, well) in [("Elapsed", elapsedColor), ("Remaining", remainingColor),
                             ("Full track", overviewColor), ("Close-up", detailColor)] {
            well.setAccessibilityLabel(name + " color")
            well.toolTip = name + " color"
            well.supportsAlpha = false
            well.target = self
            well.action = #selector(edit(_:))
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        zoom.addItems(withTitles: ZoomWindow.allCases.map { $0.title })
        zoom.setAccessibilityLabel("Close-up zoom")
        zoom.toolTip = "Time visible in the close-up. Fewer seconds show more detail."
        zoom.target = self
        zoom.action = #selector(edit(_:))
        warning.addItems(withTitles: CountdownWarning.allCases.map { $0.title })
        warning.setAccessibilityLabel("Fade remaining to red")
        warning.toolTip = "Start fading the remaining time to red this far before the end of the clip."
        warning.target = self
        warning.action = #selector(edit(_:))
        solidRedAt.addItems(withTitles: SolidRedThreshold.allCases.map { $0.title })
        solidRedAt.setAccessibilityLabel("Solid red at")
        solidRedAt.toolTip = "Time remaining when the fade reaches solid red."
        solidRedAt.target = self
        solidRedAt.action = #selector(edit(_:))
        fadeFullTrack.toolTip = "Apply the countdown warning to the full-track waveform."
        fadeCloseUp.toolTip = "Apply the countdown warning to the zoomed waveform."
        endZoom.addItems(withTitles: EndZoom.allCases.map { $0 == .off ? "Off" : "\($0.rawValue) s" })
        endZoom.autoenablesItems = false
        endZoom.setAccessibilityLabel("Zoom near end")
        centerAtStart.toolTip = "Keep the close-up playhead centered from the first frame, with empty space before the music."
        centerAtEnd.toolTip = "Keep the close-up playhead centered to the last frame, with empty space after the end."
        dimPlayedCloseUp.toolTip = "Show the upcoming audio in full colour and dim what has already played."
        countdownTarget.addItems(withTitles: CountdownTarget.allCases.map { $0.title })
        countdownTarget.setAccessibilityLabel("Countdown target")
        countdownTarget.toolTip = "Count down to the end of the file or to the end of the music."
        safeZonePreset.addItems(withTitles: SafeZonePreset.allCases.map { $0.title })
        safeZonePreset.setAccessibilityLabel("Overlay safe zones")
        safeZonePreset.toolTip = "Keep the picture free where a server overlay draws."
        showGuides.toolTip = "Draw the safe zones in the preview only. They are never part of the exported file."
        showGuides.setAccessibilityLabel("Show safe-zone guides")
        roomMessage.font = .systemFont(ofSize: 11)
        roomMessage.textColor = .systemRed
        roomMessage.setAccessibilityLabel("Safe zones leave too little room")
        for (index, stepper) in zoneSteppers.enumerated() {
            stepper.minValue = Double(SafeZones.range.lowerBound)
            stepper.maxValue = Double(SafeZones.range.upperBound)
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.setAccessibilityLabel(zoneNames[index] + " safe zone, percent")
            stepper.toolTip = zoneNames[index] + " safe zone in percent"
            stepper.target = self
            stepper.action = #selector(edit(_:))
            zoneValues[index].alignment = .right
            zoneValues[index].widthAnchor.constraint(equalToConstant: 40).isActive = true
        }
        for control in [countdownTarget, alignment, leftClock, safeZonePreset, fadeFullTrack, fadeCloseUp,
                        centerAtStart, centerAtEnd, endZoom, dimPlayedCloseUp, titleFont.family, titleFont.style, clockFont.family,
                        clockFont.style, showTitle, showElapsed, showRemaining, showFullTrack, safeZonesEnabled] as [NSControl] {
            control.target = self
            control.action = #selector(edit(_:))
        }
        showGuides.target = self
        showGuides.action = #selector(edit(_:))
        for control in [elapsedSize, remainingSize, zoom, endZoom, warning, solidRedAt, countdownTarget,
                        safeZonePreset, titleFont.family, titleFont.style, clockFont.family, clockFont.style] {
            control.widthAnchor.constraint(equalToConstant: 119).isActive = true
        }
        let labelWidth: CGFloat = 85
        func grid() -> NSGridView {
            let grid = NSGridView()
            for width: CGFloat in [labelWidth, 119, 48] {
                grid.addColumn(with: []).width = width
            }
            grid.xPlacement = .leading
            grid.yPlacement = .center
            grid.rowSpacing = 5
            grid.columnSpacing = 8
            return grid
        }
        // Controls that use the whole row (checkboxes), or the remaining two columns
        // (text and segments), span cells without changing the common colour column.
        @discardableResult
        func wideRow(_ grid: NSGridView, _ view: NSView, label: NSTextField? = nil) -> NSGridRow {
            let row = grid.addRow(with: label.map { [$0, view] } ?? [view])
            let first = label == nil ? 0 : 1
            row.mergeCells(in: NSRange(location: first, length: 3 - first))
            return row
        }
        func label(_ title: String, _ settings: [(CueAppearance.Setting, String)] = []) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: title)
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.preferredMaxLayoutWidth = labelWidth
            field.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            if !settings.isEmpty { registerOverrides(field, title: title, settings: settings) }
            return field
        }
        for (box, setting) in [(fadeCloseUp, .fadeCloseUp), (fadeFullTrack, .fadeFullTrack),
                               (centerAtStart, .centerAtStart), (centerAtEnd, .centerAtEnd), (dimPlayedCloseUp, .closeUpShading), (showTitle, .showTitle), (showElapsed, .showElapsed),
                               (showRemaining, .showRemaining), (showFullTrack, .showFullTrack),
                               (showGuides, .showGuides), (safeZonesEnabled, .safeZonesEnabled)] as [(NSButton, CueAppearance.Setting)] {
            registerOverrides(box, title: box.title, settings: [(setting, box.title)])
        }
        let title = grid()
        wideRow(title, labelField, label: label("Text"))
        labelField.widthAnchor.constraint(equalToConstant: 175).isActive = true
        wideRow(title, alignment, label: label("Alignment"))
        title.addRow(with: [label("Font family", [(.titleFontName, "Title font")]), titleFont.family])
        title.addRow(with: [label("Font style", [(.titleFontName, "Title font")]), titleFont.style])
        wideRow(title, showTitle)

        let fullTrack = grid()
        fullTrack.addRow(with: [label("Color", [(.overviewColor, "Full track color")]), NSGridCell.emptyContentView, overviewColor])
        wideRow(fullTrack, showFullTrack)

        let closeUp = grid()
        closeUp.addRow(with: [label("Zoom window", [(.zoom, "Zoom window")]), zoom])
        closeUp.addRow(with: [label("Color", [(.detailColor, "Color")]), NSGridCell.emptyContentView, detailColor])
        for box in [centerAtStart, centerAtEnd, dimPlayedCloseUp] { wideRow(closeUp, box) }
        closeUp.addRow(with: [label("Zoom near end", [(.endZoom, "Zoom near end")]), endZoom])

        let clocks = grid()
        clocks.addRow(with: [label("Elapsed", [(.elapsedSize, "Size"), (.elapsedColor, "Color")]), elapsedSize, elapsedColor])
        clocks.addRow(with: [label("Remaining", [(.remainingSize, "Size"), (.remainingColor, "Color")]), remainingSize, remainingColor])
        wideRow(clocks, leftClock, label: label("Left clock"))
        clocks.addRow(with: [label("Font family", [(.clockFontName, "Clock font")]), clockFont.family])
        clocks.addRow(with: [label("Font style", [(.clockFontName, "Clock font")]), clockFont.style])
        wideRow(clocks, showElapsed)
        wideRow(clocks, showRemaining)

        let endWarning = grid()
        endWarning.addRow(with: [label("Fade to red", [(.warning, "Fade to red")]), warning])
        endWarning.addRow(with: [label("Solid red at", [(.solidRedAt, "Solid red at")]), solidRedAt])
        endWarning.addRow(with: [label("Countdown to", [(.countdownTarget, "Countdown to")]), countdownTarget])
        wideRow(endWarning, fadeCloseUp)
        wideRow(endWarning, fadeFullTrack)

        let safeZones = grid()
        wideRow(safeZones, safeZonesEnabled)
        safeZones.addRow(with: [label("Preset", [(.safeZonePreset, "Safe-zone preset")]), safeZonePreset])
        let sides: [CueAppearance.Setting] = [.safeZoneTop, .safeZoneBottom, .safeZoneLeft, .safeZoneRight]
        for index in sides.indices {
            let controls = NSStackView(views: [zoneSteppers[index], zoneValues[index]])
            let row = safeZones.addRow(with: [label(zoneNames[index], [(sides[index], zoneNames[index])]), controls])
            customZoneRows.append(row)
        }
        wideRow(safeZones, showGuides)
        roomMessageRow = wideRow(safeZones, roomMessage)
        let stack = paneStack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.wantsLayer = true
        func addPane(_ pane: SidebarPaneView, key: String) {
            pane.isCollapsed = UserDefaults.standard.stringArray(forKey: Self.collapsedKey)?.contains(key) == true
            pane.didToggle = { collapsed in
                var keys = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
                if collapsed { keys.insert(key) } else { keys.remove(key) }
                UserDefaults.standard.set(keys.sorted(), forKey: Self.collapsedKey)
            }
            pane.canInteract = { [weak self] in self?.reorderTarget()?.isEditable == true }
            pane.willCollapse = { [weak self] in self?.closeColorPicker() }
            stack.addArrangedSubview(pane)
            pane.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let bodies: [PicturePane: NSGridView] = [.title: title, .fullTrack: fullTrack, .closeUp: closeUp, .clocks: clocks]
        for id in settings.paneOrder {
            guard let body = bodies[id] else { continue }
            let offsetRow = body.addRow(with: [])
            offsetRow.isHidden = true
            offsetRows[id] = offsetRow
            let pane = SidebarPaneView(title: id.displayName, movable: true, body: body)
            paneViews[id] = pane
            addPane(pane, key: id.rawValue)
            pane.onGripDown = { [weak self, weak pane] event in
                guard let pane else { return }
                self?.dragController?.track(from: pane, event: event)
            }
            var menuContext: PaneReorder.Context?
            pane.willOpenMoveMenu = { [weak self] in menuContext = self?.reorderContext() }
            pane.canMove = { [weak self] direction in
                guard let context = self?.reorderContext(), context.isEditable,
                      let index = context.order.firstIndex(of: id) else { return false }
                return direction < 0 ? PaneReorder.canMoveUp(from: index, count: context.order.count)
                    : PaneReorder.canMoveDown(from: index, count: context.order.count)
            }
            pane.onMove = { [weak self] direction in
                guard let self, let menuContext, let from = menuContext.order.firstIndex(of: id) else { return false }
                return self.setOrder(from: from, toGap: direction < 0 ? from - 1 : from + 2, context: menuContext)
            }
        }
        addPane(SidebarPaneView(title: "End warning", movable: false, body: endWarning), key: "endWarning")
        addPane(SidebarPaneView(title: "Overlay safe zones", movable: false, body: safeZones), key: "safeZones")
        stack.addArrangedSubview(NSButton(title: "Restore Defaults", target: self, action: #selector(reset)))
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor.separatorColor.cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = SidebarDocument()
        scroll.documentView = document
        addSubview(border)
        addSubview(scroll)
        document.addSubview(stack)
        for view in [border, scroll, document, stack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.topAnchor.constraint(equalTo: topAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.widthAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: border.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        dragController = PaneDragController(scroll: scroll, document: document, panes: { [weak self] in
            guard let self else { return [] }
            return self.settings.paneOrder.compactMap { self.paneViews[$0] }
        }, context: { [weak self] in self?.reorderContext() }, locked: reportLocked, completed: { [weak self] context, from, gap in
            _ = self?.setOrder(from: from, toGap: gap, context: context)
        })
        dragController?.didEndTracking = { [weak self] in
            guard let self, let (look, frames) = self.pendingDisplay else { return }
            self.pendingDisplay = nil
            self.sync(to: look, clockFrames: frames)
        }
        for control in [alignment, leftClock, elapsedSize, remainingSize, overviewColor, detailColor,
                        elapsedColor, remainingColor, warning, solidRedAt, zoom, endZoom, countdownTarget,
                        titleFont.family, titleFont.style, clockFont.family, clockFont.style, safeZonePreset] as [NSControl] {
            control.controlSize = .small
        }
        refresh()
    }

    private func reorderContext() -> PaneReorder.Context? {
        guard let target = reorderTarget(), target.appearance.paneOrder == settings.paneOrder else { return nil }
        return PaneReorder.Context(jobID: target.jobID, order: target.appearance.paneOrder, isEditable: target.isEditable)
    }

    @discardableResult
    private func setOrder(from: Int, toGap: Int, context: PaneReorder.Context) -> Bool {
        guard context.permitsMove(in: reorderContext()), let target = reorderTarget() else { return false }
        let order = PaneReorder.move(context.order, from: from, toGap: toGap)
        guard order != context.order else { return false }
        let id = context.order[from]
        var proposed = target.appearance
        proposed.paneOrder = order
        changed(proposed)
        // The model synchronously feeds the accepted appearance back through sync(to:).
        guard settings.paneOrder == order, let to = order.firstIndex(of: id) else { return false }
        let message = "\(id.displayName), \(to + 1) of \(order.count)"
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue
        ])
        return true
    }

    required init?(coder: NSCoder) { fatalError() }

    func jobDidLock(_ id: UUID) {
        dragController?.jobDidLock(id)
    }

    func closeColorPicker() {
        for well in [elapsedColor, remainingColor, overviewColor, detailColor] where well.isActive {
            well.deactivate()
            NSColorPanel.shared.orderOut(nil)
        }
    }

    private func registerOverrides(_ label: NSControl, title: String, settings: [(CueAppearance.Setting, String)]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (setting, name) in settings {
            let item = menu.addItem(withTitle: settings.count == 1 ? "Reset" : "Reset " + name,
                                    action: #selector(resetSetting(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = setting
        }
        label.menu = menu
        let resetHelp = "Control-click to reset to the factory default."
        label.toolTip = label.toolTip.map { $0 + " " + resetHelp } ?? resetHelp
        overrideRows.append((label, title, settings.map { $0.0 }))
    }

    @objc private func resetSetting(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? CueAppearance.Setting else { return }
        guard let target = reorderTarget() else { return }
        settings = target.appearance.resetting(setting, to: factory)
        refresh()
        changed(settings)
    }

    func sync(to settings: CueAppearance, clockFrames: Int?) {
        if dragController?.isTracking == true {
            pendingDisplay = (settings, clockFrames)
            return
        }
        guard self.settings != settings || self.clockFrames != clockFrames else { return }
        self.settings = settings
        self.clockFrames = clockFrames
        refresh()
    }

    @objc private func edit(_ sender: NSControl) {
        guard let target = reorderTarget() else { return }
        settings = target.appearance
        switch sender {
        case elapsedSize: settings.elapsed.size = ClockSize.allCases[elapsedSize.indexOfSelectedItem]
        case remainingSize: settings.remaining.size = ClockSize.allCases[remainingSize.indexOfSelectedItem]
        case elapsedColor:
            guard let color = CueColor(elapsedColor.color) else { return }
            settings.elapsed.color = color
        case remainingColor:
            guard let color = CueColor(remainingColor.color) else { return }
            settings.remaining.color = color
        case overviewColor: settings.overviewColor = CueColor(overviewColor.color)
        case detailColor: settings.detailColor = CueColor(detailColor.color)
        case zoom:
            settings.zoom = ZoomWindow.allCases[zoom.indexOfSelectedItem]
        case centerAtStart: settings.centerAtStart = centerAtStart.state == .on
        case centerAtEnd: settings.centerAtEnd = centerAtEnd.state == .on
        case endZoom: settings.endZoom = EndZoom.allCases[endZoom.indexOfSelectedItem]
        case dimPlayedCloseUp: settings.dimPlayedCloseUp = dimPlayedCloseUp.state == .on
        case titleFont.family, titleFont.style: settings.titleFontName = titleFont.selection(from: sender)
        case clockFont.family, clockFont.style: settings.clockFontName = clockFont.selection(from: sender)
        case showTitle: settings.showTitle = showTitle.state == .on
        case showElapsed: settings.showElapsed = showElapsed.state == .on
        case showRemaining: settings.showRemaining = showRemaining.state == .on
        case showFullTrack: settings.showFullTrack = showFullTrack.state == .on
        case safeZonesEnabled: settings.safeZonesEnabled = safeZonesEnabled.state == .on
        case warning:
            settings.warning = CountdownWarning.allCases[warning.indexOfSelectedItem]
        case solidRedAt: settings.solidRedAt = SolidRedThreshold.allCases[solidRedAt.indexOfSelectedItem]
        case fadeCloseUp: settings.fadeCloseUp = fadeCloseUp.state == .on
        case fadeFullTrack: settings.fadeFullTrack = fadeFullTrack.state == .on
        case countdownTarget: settings.countdownTarget = CountdownTarget.allCases[countdownTarget.indexOfSelectedItem]
        case alignment: settings.titleAlignment = TitleAlignment.allCases[alignment.selectedSegment]
        case leftClock: settings.leftClock = LeftClock.allCases[leftClock.selectedSegment]
        case safeZonePreset:
            settings.safeZones.preset = SafeZonePreset.allCases[safeZonePreset.indexOfSelectedItem]
        case showGuides: settings.showGuides = showGuides.state == .on
        case let stepper as NSStepper where zoneSteppers.contains(stepper):
            var custom = settings.safeZones.custom
            let values = zoneSteppers.map { Int($0.integerValue) }
            custom = SafeZones.Insets(top: values[0], bottom: values[1], left: values[2], right: values[3])
            settings.safeZones.custom = custom
        default: return
        }
        refresh()
        changed(settings)
    }

    @objc private func reset() {
        settings = factory
        refresh()
        changed(settings)
    }

    private func refresh() {
        let orderedPanes = settings.paneOrder.compactMap { paneViews[$0] }
        if Array(paneStack.arrangedSubviews.prefix(orderedPanes.count)) != orderedPanes {
            closeColorPicker()
            SidebarPaneView.updateLayout(in: self) {
                for (index, pane) in orderedPanes.enumerated() where paneStack.arrangedSubviews[index] !== pane {
                    paneStack.insertArrangedSubview(pane, at: index)
                }
            }
            NSAccessibility.post(element: paneStack, notification: .layoutChanged)
        }
        let differences = settings.differences(from: factory)
        let closeUpSettings: Set<CueAppearance.Setting> = [.detailColor, .centerAtStart, .centerAtEnd, .closeUpShading, .endZoom]
        for row in overrideRows {
            let overridden = !differences.isDisjoint(with: row.settings)
            let title = overridden ? "• " + row.title : row.title
            if let field = row.label as? NSTextField { field.stringValue = title }
            if let box = row.label as? NSButton { box.title = title }
            for (setting, item) in zip(row.settings, row.label.menu?.items ?? []) {
                item.isEnabled = differences.contains(setting) && (settings.zoom != .off || !closeUpSettings.contains(setting))
            }
        }
        titleFont.display(settings.titleFontName)
        clockFont.display(settings.clockFontName)
        for (box, value) in [(showTitle, settings.showTitle), (showElapsed, settings.showElapsed),
                             (showRemaining, settings.showRemaining), (showFullTrack, settings.showFullTrack),
                             (safeZonesEnabled, settings.safeZonesEnabled), (centerAtStart, settings.centerAtStart),
                             (centerAtEnd, settings.centerAtEnd), (dimPlayedCloseUp, settings.dimPlayedCloseUp)] {
            box.state = value ? .on : .off
        }
        for control in [centerAtStart, centerAtEnd, dimPlayedCloseUp, endZoom] as [NSControl] {
            control.isEnabled = settings.zoom != .off
        }
        endZoom.selectItem(at: EndZoom.allCases.firstIndex(of: settings.endZoom)!)
        // With no clip selected, Auto may reach its full ten seconds on future imports.
        let frames = clockFrames ?? 20 * ClipTimeline.clockRate
        let width = settings.zoom.rawValue > 0 && clockFrames == nil
            ? settings.zoom.rawValue * ClipTimeline.clockRate : settings.zoom.frameCount(for: frames)
        for (choice, item) in zip(EndZoom.allCases, endZoom.itemArray) {
            item.isEnabled = choice == .off || choice.rawValue * ClipTimeline.clockRate < width
        }
        elapsedSize.selectItem(withTitle: settings.elapsed.size.rawValue)
        remainingSize.selectItem(withTitle: settings.remaining.size.rawValue)
        overviewColor.color = (settings.overviewColor ?? CueAppearance.defaultOverview).nsColor
        detailColor.color = (settings.detailColor ?? CueAppearance.defaultDetail).nsColor
        detailColor.isEnabled = settings.zoom != .off
        warning.selectItem(withTitle: settings.warning.title)
        solidRedAt.selectItem(withTitle: settings.solidRedAt.title)
        fadeCloseUp.state = settings.fadeCloseUp ? .on : .off
        fadeFullTrack.state = settings.fadeFullTrack ? .on : .off
        updateWarningControls()
        countdownTarget.selectItem(withTitle: settings.countdownTarget.title)
        alignment.selectedSegment = TitleAlignment.allCases.firstIndex(of: settings.titleAlignment)!
        leftClock.selectedSegment = LeftClock.allCases.firstIndex(of: settings.leftClock)!
        safeZonePreset.selectItem(withTitle: settings.safeZones.preset.title)
        showGuides.state = settings.showGuides ? .on : .off
        updateSafeZoneControls()
        zoom.selectItem(withTitle: settings.zoom.title)
        elapsedColor.color = settings.elapsed.color.nsColor
        remainingColor.color = settings.remaining.color.nsColor
    }

    private func updateWarningControls() {
        solidRedAt.isEnabled = settings.warning != .off
        fadeCloseUp.isEnabled = settings.warning != .off && settings.zoom != .off
        fadeFullTrack.isEnabled = settings.warning != .off
    }

    private func updateSafeZoneControls() {
        let custom = settings.safeZones.custom
        let values = [custom.top, custom.bottom, custom.left, custom.right]
        safeZonePreset.isEnabled = settings.safeZonesEnabled
        showGuides.isEnabled = settings.safeZonesEnabled
        let editable = settings.safeZonesEnabled && settings.safeZones.preset == .custom
        for index in 0..<4 {
            zoneSteppers[index].integerValue = values[index]
            zoneValues[index].stringValue = "\(values[index]) %"
            zoneSteppers[index].isEnabled = editable
            zoneValues[index].textColor = editable ? .labelColor : .disabledControlTextColor
        }
        for row in customZoneRows { row.isHidden = !editable }
        roomMessageRow?.isHidden = settings.layout.fits
    }
}
