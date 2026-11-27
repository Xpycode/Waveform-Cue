import AppKit
import CueCore

private final class SidebarDocument: NSView {
    override var isFlipped: Bool { true }
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
    private let changed: (CueAppearance) -> Void

    init(settings: CueAppearance, labelField: NSTextField, position: NSPopUpButton,
         changed: @escaping (CueAppearance) -> Void) {
        self.settings = settings
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
        for checkbox in [fadeFullTrack, fadeCloseUp] {
            checkbox.target = self
            checkbox.action = #selector(edit(_:))
        }
        countdownTarget.addItems(withTitles: CountdownTarget.allCases.map { $0.title })
        countdownTarget.setAccessibilityLabel("Countdown target")
        countdownTarget.toolTip = "Count down to the end of the file or to the end of the music."
        clockPosition.addItems(withTitles: ClockPosition.allCases.map { $0.title })
        clockPosition.setAccessibilityLabel("Clock position")
        clockPosition.toolTip = "Place the clocks below or above the waveforms."
        safeZonePreset.addItems(withTitles: SafeZonePreset.allCases.map { $0.title })
        safeZonePreset.setAccessibilityLabel("Overlay safe zones")
        safeZonePreset.toolTip = "Keep the picture free where a server overlay draws."
        showGuides.toolTip = "Draw the safe zones in the preview and in the exported file."
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
        for control in [countdownTarget, clockPosition, safeZonePreset] {
            control.target = self
            control.action = #selector(edit(_:))
        }
        showGuides.target = self
        showGuides.action = #selector(edit(_:))
        for picker in [elapsedSize, remainingSize, zoom, warning, solidRedAt, countdownTarget, clockPosition, safeZonePreset] {
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
        let clocks = grid([
            [heading("Clock"), heading("Size"), heading("Color")],
            [NSTextField(labelWithString: "Elapsed"), elapsedSize, elapsedColor],
            [NSTextField(labelWithString: "Remaining"), remainingSize, remainingColor]
        ])
        let waveforms = grid([
            [heading("Waveform"), heading("Zoom window"), heading("Color")],
            [NSTextField(labelWithString: "Full track"), NSView(), overviewColor],
            [NSTextField(labelWithString: "Close-up"), zoom, detailColor]
        ])
        let timing = grid([
            [NSTextField(labelWithString: "Fade to red"), warning],
            [NSTextField(labelWithString: "Solid red at"), solidRedAt],
            [NSTextField(labelWithString: "Countdown to"), countdownTarget]
        ])
        let clockPlacement = grid([[NSTextField(labelWithString: "Clock position"), clockPosition]])
        let zonePreset = grid([[NSTextField(labelWithString: "Safe zones"), safeZonePreset]])
        zoneGrid = grid((0..<4).map { [NSTextField(labelWithString: zoneNames[$0]), zoneSteppers[$0], zoneValues[$0]] })
        let title = NSTextField(labelWithString: "Appearance")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(reset))
        let stack = NSStackView(views: [title, overlayTitle, labelField, placement, clocks, clockPlacement, waveforms,
                                        section("End warning"), timing, fadeCloseUp, fadeFullTrack,
                                        section("Overlay safe zones"), zonePreset, zoneGrid, showGuides, roomMessage, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        for view in [title, placement, clockPlacement, waveforms, fadeFullTrack, showGuides] as [NSView] {
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

    /// Shows `appearance` in every control, dropping edits the job refused.
    func sync(to appearance: CueAppearance) {
        guard settings != appearance else { return }
        settings = appearance
        refresh()
    }

    func closeColorPicker() {
        for well in [elapsedColor, remainingColor, overviewColor, detailColor] where well.isActive {
            well.deactivate()
            NSColorPanel.shared.orderOut(nil)
        }
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
            detailColor.isEnabled = settings.zoom != .off
            updateWarningControls()
        case warning:
            settings.warning = CountdownWarning.allCases[warning.indexOfSelectedItem]
            updateWarningControls()
        case solidRedAt: settings.solidRedAt = SolidRedThreshold.allCases[solidRedAt.indexOfSelectedItem]
        case fadeCloseUp: settings.fadeCloseUp = fadeCloseUp.state == .on
        case fadeFullTrack: settings.fadeFullTrack = fadeFullTrack.state == .on
        case countdownTarget: settings.countdownTarget = CountdownTarget.allCases[countdownTarget.indexOfSelectedItem]
        case clockPosition: settings.clockPosition = ClockPosition.allCases[clockPosition.indexOfSelectedItem]
        case safeZonePreset:
            settings.safeZones.preset = SafeZonePreset.allCases[safeZonePreset.indexOfSelectedItem]
            updateSafeZoneControls()
        case showGuides: settings.showGuides = showGuides.state == .on
        case let stepper as NSStepper where zoneSteppers.contains(stepper):
            var custom = settings.safeZones.custom
            let values = zoneSteppers.map { Int($0.integerValue) }
            custom = SafeZones.Insets(top: values[0], bottom: values[1], left: values[2], right: values[3])
            settings.safeZones.custom = custom
            updateSafeZoneControls()
        default: return
        }
        roomMessage.isHidden = settings.layout.fits
        changed(settings)
    }

    @objc private func reset() {
        settings = CueAppearance()
        refresh()
        changed(settings)
    }

    private func refresh() {
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
        let editable = settings.safeZones.preset == .custom
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
