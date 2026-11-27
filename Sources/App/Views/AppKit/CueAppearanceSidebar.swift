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
        family.widthAnchor.constraint(equalToConstant: 129).isActive = true
        style.widthAnchor.constraint(equalToConstant: 82).isActive = true
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
    private let centered = NSButton(checkboxWithTitle: "Keep playhead centered", target: nil, action: nil)
    private let endZoom = NSPopUpButton()
    private let shading = NSPopUpButton()
    private let titleFont = FontPickers(role: .title, label: "Title")
    private let clockFont = FontPickers(role: .clock, label: "Clock")
    private let showTitle = NSButton(checkboxWithTitle: "Title", target: nil, action: nil)
    private let showElapsed = NSButton(checkboxWithTitle: "Elapsed", target: nil, action: nil)
    private let showRemaining = NSButton(checkboxWithTitle: "Remaining", target: nil, action: nil)
    private let showFullTrack = NSButton(checkboxWithTitle: "Full track", target: nil, action: nil)
    private let safeZonesEnabled = NSButton(checkboxWithTitle: "Safe zones", target: nil, action: nil)
    private let countdownTarget = NSPopUpButton()
    private let clockPosition = NSPopUpButton()
    private let safeZonePreset = NSPopUpButton()
    private let showGuides = NSButton(checkboxWithTitle: "Show safe-zone guides", target: nil, action: nil)
    private let zoneNames = ["Top", "Bottom", "Left", "Right"]
    private let zoneSteppers = (0..<4).map { _ in NSStepper() }
    private let zoneValues = (0..<4).map { _ in NSTextField(labelWithString: "0 %") }
    private let roomMessage = NSTextField(wrappingLabelWithString: "Safe zones leave too little room")
    private var zoneGrid = NSGridView()
    private var settings: CueAppearance
    private var saved: CueAppearance
    private var clockFrames: Int?
    private var overrideRows: [(label: NSControl, title: String, settings: [CueAppearance.Setting])] = []
    private let changed: (CueAppearance) -> Void

    init(settings: CueAppearance, saved: CueAppearance, clockFrames: Int?, labelField: NSTextField, position: NSPopUpButton,
         changed: @escaping (CueAppearance) -> Void) {
        self.settings = settings
        self.saved = saved
        self.clockFrames = clockFrames
        self.changed = changed
        super.init(frame: .zero)

        func heading(_ title: String) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 11, weight: .medium)
            field.textColor = .secondaryLabelColor
            return field
        }
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
        shading.addItems(withTitles: CloseUpShading.allCases.map { $0 == .upcomingBrighter ? "Upcoming brighter" : "Played brighter" })
        shading.setAccessibilityLabel("Close-up shading")
        countdownTarget.addItems(withTitles: CountdownTarget.allCases.map { $0.title })
        countdownTarget.setAccessibilityLabel("Countdown target")
        countdownTarget.toolTip = "Count down to the end of the file or to the end of the music."
        clockPosition.addItems(withTitles: ClockPosition.allCases.map { $0.title })
        clockPosition.setAccessibilityLabel("Clock position")
        clockPosition.toolTip = "Place the clocks below or above the waveforms."
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
        for control in [countdownTarget, clockPosition, safeZonePreset, fadeFullTrack, fadeCloseUp,
                        centered, endZoom, shading, titleFont.family, titleFont.style, clockFont.family,
                        clockFont.style, showTitle, showElapsed, showRemaining, showFullTrack, safeZonesEnabled] as [NSControl] {
            control.target = self
            control.action = #selector(edit(_:))
        }
        showGuides.target = self
        showGuides.action = #selector(edit(_:))
        for picker in [elapsedSize, remainingSize, zoom, warning, solidRedAt, countdownTarget, clockPosition] {
            picker.widthAnchor.constraint(equalToConstant: 119).isActive = true
        }
        func section(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            return label
        }
        func grid(_ rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.column(at: 0).width = 85
            grid.xPlacement = .leading
            grid.yPlacement = .center
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            return grid
        }
        let overlayTitle = section("Overlay text")
        let placement = grid([[NSTextField(labelWithString: "Position"), position]])
        position.widthAnchor.constraint(equalToConstant: 134).isActive = true
        func label(_ title: String, _ settings: [(CueAppearance.Setting, String)]) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            registerOverrides(field, title: title, settings: settings)
            return field
        }
        for (box, setting) in [(fadeCloseUp, .fadeCloseUp), (fadeFullTrack, .fadeFullTrack),
                               (centered, .playheadMode), (showTitle, .showTitle), (showElapsed, .showElapsed),
                               (showRemaining, .showRemaining), (showFullTrack, .showFullTrack),
                               (showGuides, .showGuides), (safeZonesEnabled, .safeZonesEnabled)] as [(NSButton, CueAppearance.Setting)] {
            registerOverrides(box, title: box.title, settings: [(setting, box.title)])
        }
        let fonts = grid([
            [NSView(), heading("Family"), heading("Style")],
            [label("Title", [(.titleFontName, "Title font")]), titleFont.family, titleFont.style],
            [label("Clock", [(.clockFontName, "Clock font")]), clockFont.family, clockFont.style]
        ])
        fonts.column(at: 0).width = 44
        let visibility = grid([[showTitle, showElapsed], [showRemaining, showFullTrack]])
        visibility.column(at: 0).width = 126
        let clocks = grid([
            [heading("Clock"), heading("Size"), heading("Color")],
            [label("Elapsed", [(.elapsedSize, "Size"), (.elapsedColor, "Color")]), elapsedSize, elapsedColor],
            [label("Remaining", [(.remainingSize, "Size"), (.remainingColor, "Color")]), remainingSize, remainingColor]
        ])
        let waveforms = grid([
            [heading("Waveform"), heading("Zoom window"), heading("Color")],
            [label("Full track", [(.overviewColor, "Full track color")]), NSView(), overviewColor],
            [label("Close-up", [(.zoom, "Zoom window"), (.detailColor, "Color")]), zoom, detailColor]
        ])
        let closeUpOptions = grid([
            [label("Zoom near end", [(.endZoom, "Zoom near end")]), endZoom],
            [label("Close-up shading", [(.closeUpShading, "Close-up shading")]), shading]
        ])
        closeUpOptions.column(at: 0).width = 119
        shading.widthAnchor.constraint(equalToConstant: 144).isActive = true
        endZoom.widthAnchor.constraint(equalTo: shading.widthAnchor).isActive = true
        let timing = grid([
            [label("Fade to red", [(.warning, "Fade to red")]), warning],
            [label("Solid red at", [(.solidRedAt, "Solid red at")]), solidRedAt],
            [label("Countdown to", [(.countdownTarget, "Countdown to")]), countdownTarget]
        ])
        let clockPlacement = grid([[label("Clock position", [(.clockPosition, "Clock position")]), clockPosition]])
        let presetMenuLabel = label("Preset", [(.safeZonePreset, "Safe-zone preset")])
        let presetGroup = NSStackView(views: [presetMenuLabel, safeZonePreset])
        presetGroup.spacing = 5
        safeZonePreset.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let zonePreset = grid([[safeZonesEnabled, presetGroup]])
        zonePreset.column(at: 0).width = 96
        timing.column(at: 0).width = 105
        clockPlacement.column(at: 0).width = 105
        let sides: [CueAppearance.Setting] = [.safeZoneTop, .safeZoneBottom, .safeZoneLeft, .safeZoneRight]
        zoneGrid = grid(sides.indices.map { [label(zoneNames[$0], [(sides[$0], zoneNames[$0])]), zoneSteppers[$0], zoneValues[$0]] })
        let title = NSTextField(labelWithString: "Appearance")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let reset = NSButton(title: "Reset All to Default", target: self, action: #selector(reset))
        let stack = NSStackView(views: [title, overlayTitle, labelField, placement, section("Fonts"), fonts,
                                        section("Show"), visibility, clocks, clockPlacement, waveforms, centered, closeUpOptions,
                                        section("End warning"), timing, fadeCloseUp, fadeFullTrack,
                                        section("Overlay safe zones"), zonePreset, zoneGrid, showGuides, roomMessage, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        for view in [title, placement, visibility, clockPlacement, closeUpOptions, fadeFullTrack, showGuides] as [NSView] {
            stack.setCustomSpacing(20, after: view)
        }

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
            labelField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

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
        let resetHelp = "Control-click to reset to the saved default."
        label.toolTip = label.toolTip.map { $0 + " " + resetHelp } ?? resetHelp
        overrideRows.append((label, title, settings.map { $0.0 }))
    }

    @objc private func resetSetting(_ sender: NSMenuItem) {
        guard let setting = sender.representedObject as? CueAppearance.Setting else { return }
        settings = settings.resetting(setting, to: saved)
        refresh()
        changed(settings)
    }

    func display(settings: CueAppearance, saved: CueAppearance, clockFrames: Int?) {
        guard self.settings != settings || self.saved != saved || self.clockFrames != clockFrames else { return }
        self.settings = settings
        self.saved = saved
        self.clockFrames = clockFrames
        refresh()
    }

    @objc private func edit(_ sender: NSControl) {
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
        case centered: settings.playheadMode = centered.state == .on ? .centered : .edgeHeld
        case endZoom: settings.endZoom = EndZoom.allCases[endZoom.indexOfSelectedItem]
        case shading: settings.closeUpShading = CloseUpShading.allCases[shading.indexOfSelectedItem]
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
        case clockPosition: settings.clockPosition = ClockPosition.allCases[clockPosition.indexOfSelectedItem]
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
        settings = saved
        refresh()
        changed(settings)
    }

    private func refresh() {
        let differences = settings.differences(from: saved)
        for row in overrideRows {
            let overridden = !differences.isDisjoint(with: row.settings)
            let title = overridden ? "• " + row.title : row.title
            if let field = row.label as? NSTextField { field.stringValue = title }
            if let box = row.label as? NSButton { box.title = title }
            for (setting, item) in zip(row.settings, row.label.menu?.items ?? []) {
                item.isEnabled = differences.contains(setting)
            }
        }
        titleFont.display(settings.titleFontName)
        clockFont.display(settings.clockFontName)
        for (box, value) in [(showTitle, settings.showTitle), (showElapsed, settings.showElapsed),
                             (showRemaining, settings.showRemaining), (showFullTrack, settings.showFullTrack),
                             (safeZonesEnabled, settings.safeZonesEnabled), (centered, settings.playheadMode == .centered)] {
            box.state = value ? .on : .off
        }
        centered.isEnabled = settings.zoom != .off
        shading.isEnabled = centered.isEnabled
        shading.selectItem(at: CloseUpShading.allCases.firstIndex(of: settings.closeUpShading)!)
        endZoom.isEnabled = centered.isEnabled
        endZoom.selectItem(at: EndZoom.allCases.firstIndex(of: settings.endZoom)!)
        // With no clip selected, Auto may reach its full ten seconds on future imports.
        let frames = clockFrames ?? 20 * ClipTimeline.clockRate
        let width = settings.zoom.rawValue > 0 && (settings.playheadMode == .centered || clockFrames == nil)
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
        clockPosition.selectItem(withTitle: settings.clockPosition.title)
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
        zoneGrid.isHidden = !editable
        roomMessage.isHidden = settings.layout.fits
    }
}
