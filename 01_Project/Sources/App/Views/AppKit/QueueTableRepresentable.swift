import AppKit
import CueCore
import SwiftUI

/// The queue list: an `NSTableView` with one row per job (name, status and percentage, Cancel,
/// Retry, Show in Finder, and a log disclosure for failures). Files and folders dropped anywhere
/// on the list are added to the queue. Selection is two-way with `EditorModel.selectJob`.
struct QueueTableRepresentable: NSViewRepresentable {
    let model: EditorModel
    let jobs: [CueJob]
    let selectedID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> QueueDropView {
        let coordinator = context.coordinator
        let table = QueueTableView()
        table.headerView = nil
        table.style = .plain
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.setAccessibilityLabel("Queue")
        let column = NSTableColumn(identifier: QueueJobCell.identifier)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = coordinator
        table.delegate = coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.onDelete = { [weak coordinator] in coordinator?.removeSelected() }

        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove from Queue", action: #selector(Coordinator.removeClicked), keyEquivalent: "")
        remove.target = coordinator
        menu.addItem(remove)
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let container = QueueDropView()
        container.onDrop = { [weak model] urls in model?.addAudio(urls) }
        container.embed(scroll)
        coordinator.table = table
        coordinator.container = container
        return container
    }

    func updateNSView(_ container: QueueDropView, context: Context) {
        let coordinator = context.coordinator
        coordinator.apply(jobs: jobs, selectedID: selectedID)
        container.showsPlaceholder = jobs.isEmpty
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: EditorModel
        weak var table: QueueTableView?
        weak var container: QueueDropView?
        private var jobs: [CueJob] = []
        private var expanded: Set<UUID> = []
        private var applyingSelection = false

        init(model: EditorModel) { self.model = model }

        func apply(jobs newJobs: [CueJob], selectedID: UUID?) {
            guard let table else { return }
            let old = jobs
            jobs = newJobs
            expanded.formIntersection(newJobs.filter(\.status.isFailure).map(\.id))
            if old.map(\.id) != newJobs.map(\.id) {
                // Reloading can move or drop the table's selection; that is not the operator's choice.
                applyingSelection = true
                table.reloadData()
                applyingSelection = false
            } else {
                // Same rows: reconfigure changed rows in place so progress ticks don't rebuild the list.
                // A row shows only the source name and status, so only those are compared.
                var heights = IndexSet()
                for (row, job) in newJobs.enumerated() where job.status != old[row].status || job.sourcePath != old[row].sourcePath {
                    if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueJobCell {
                        configure(cell, with: job)
                    }
                    if job.status.isFailure != old[row].status.isFailure { heights.insert(row) }
                }
                if !heights.isEmpty { table.noteHeightOfRows(withIndexesChanged: heights) }
            }
            let wanted = selectedID.flatMap { id in newJobs.firstIndex { $0.id == id } }
            if table.selectedRow != (wanted ?? -1) {
                applyingSelection = true
                if let wanted {
                    table.selectRowIndexes([wanted], byExtendingSelection: false)
                    table.scrollRowToVisible(wanted)
                } else {
                    table.deselectAll(nil)
                }
                applyingSelection = false
            }
        }

        // MARK: Data source and delegate

        func numberOfRows(in tableView: NSTableView) -> Int { jobs.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = (tableView.makeView(withIdentifier: QueueJobCell.identifier, owner: nil) as? QueueJobCell)
                ?? QueueJobCell()
            cell.identifier = QueueJobCell.identifier
            if jobs.indices.contains(row) { configure(cell, with: jobs[row]) }
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard jobs.indices.contains(row) else { return QueueJobCell.baseHeight }
            return QueueJobCell.height(expanded: expanded.contains(jobs[row].id))
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let row = table.selectedRow
            model.selectJob(jobs.indices.contains(row) ? jobs[row].id : nil)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard !QueueDropView.fileURLs(info).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .on)
            return .copy
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            let urls = QueueDropView.fileURLs(info)
            guard !urls.isEmpty else { return false }
            model.addAudio(urls)
            return true
        }

        // MARK: Row actions

        private func configure(_ cell: QueueJobCell, with job: CueJob) {
            let id = job.id
            cell.configure(with: job, expanded: expanded.contains(id))
            cell.onCancel = { [weak self] in self?.model.cancelJob(id) }
            cell.onRetry = { [weak self] in self?.model.retryJob(id) }
            cell.onReveal = { [weak self] in self?.model.reveal(id) }
            cell.onChooseFolder = { [weak self] in self?.model.choosePausedFolder(for: id) }
            cell.onDisclose = { [weak self] open in self?.setExpanded(open, for: id) }
        }

        private func setExpanded(_ open: Bool, for id: UUID) {
            if open { expanded.insert(id) } else { expanded.remove(id) }
            guard let table, let row = jobs.firstIndex(where: { $0.id == id }) else { return }
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? QueueJobCell {
                configure(cell, with: jobs[row])
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                table.noteHeightOfRows(withIndexesChanged: [row])
            }
        }

        func removeSelected() {
            guard let table, jobs.indices.contains(table.selectedRow) else { NSSound.beep(); return }
            model.removeJobs([jobs[table.selectedRow].id])
        }

        @objc func removeClicked() {
            guard let table, jobs.indices.contains(table.clickedRow) else { return }
            model.removeJobs([jobs[table.clickedRow].id])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let table, let item = menu.items.first else { return }
            let row = table.clickedRow
            item.isEnabled = jobs.indices.contains(row) && !jobs[row].status.isActive
        }
    }
}

private extension JobStatus {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Table and drop container

/// Delete or Forward Delete removes the selected job.
final class QueueTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Holds the scrolling list and the empty-queue hint, and accepts file drops on any part of the
/// sidebar the table does not cover.
final class QueueDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var showsPlaceholder = true {
        didSet { placeholder.isHidden = !showsPlaceholder }
    }
    private let placeholder = NSTextField(wrappingLabelWithString: "Drop audio files or a folder here, or choose File → Add Audio…")
    private var hovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func embed(_ scroll: NSScrollView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20)
        ])
    }

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = !Self.fileURLs(sender).isEmpty
        return hovered ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovered = false
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hovered else { return }
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 6, yRadius: 6)
        outline.lineWidth = 2
        outline.stroke()
    }
}

// MARK: - Row

/// One job: name; status with a progress bar while exporting; Cancel, Retry, Show in Finder or
/// (Paused) Choose Folder…; and, for a failed job, a Log disclosure that shows the reason and the
/// encoder's log tail.
final class QueueJobCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QueueJobCell")
    static let baseHeight: CGFloat = 72
    static let logHeight: CGFloat = 132

    static func height(expanded: Bool) -> CGFloat { baseHeight + (expanded ? logHeight : 0) }

    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?
    var onReveal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onDisclose: ((Bool) -> Void)?

    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let retry = NSButton(title: "Retry", target: nil, action: nil)
    private let reveal = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let chooseFolder = NSButton(title: "Choose Folder…", target: nil, action: nil)
    private let disclosure = NSButton()
    private let logTitle = NSTextField(labelWithString: "Log")
    private let logScroll = NSScrollView()
    private let logText = NSTextView()

    init() {
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for (button, selector, tip) in [(cancel, #selector(cancelPressed), "Cancel this job. A running export stops and leaves no file."),
                                        (retry, #selector(retryPressed), "Return this job to Pending with a fresh file name."),
                                        (reveal, #selector(revealPressed), "Show the exported MXF in Finder."),
                                        (chooseFolder, #selector(chooseFolderPressed), "Choose a writable folder for the jobs paused with this one, and resume them.")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.target = self
            button.action = selector
            button.toolTip = tip
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(disclosePressed)
        disclosure.setAccessibilityLabel("Show log")
        disclosure.toolTip = "Show the failure reason and the encoder log."
        logTitle.font = .systemFont(ofSize: 11)
        logTitle.textColor = .secondaryLabelColor

        logText.isEditable = false
        logText.isSelectable = true
        logText.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logText.textColor = .secondaryLabelColor
        logText.drawsBackground = false
        logText.textContainerInset = NSSize(width: 2, height: 4)
        logText.isVerticallyResizable = true
        logText.autoresizingMask = [.width]
        logText.textContainer?.widthTracksTextView = true
        logText.setAccessibilityLabel("Failure log")
        logScroll.documentView = logText
        logScroll.hasVerticalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .bezelBorder
        logScroll.drawsBackground = false

        let statusRow = NSStackView(views: [status, progress])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [cancel, retry, reveal, chooseFolder, spacer, disclosure, logTitle])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.alignment = .centerY

        for view in [name, statusRow, buttons, logScroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let progressWidth = progress.widthAnchor.constraint(equalToConstant: 70)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusRow.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            statusRow.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            progressWidth,
            buttons.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 5),
            buttons.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 20),
            logScroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.baseHeight - 4),
            logScroll.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            logScroll.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            logScroll.heightAnchor.constraint(equalToConstant: Self.logHeight - 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with job: CueJob, expanded: Bool) {
        name.stringValue = job.sourceURL.lastPathComponent
        name.toolTip = job.sourcePath
        let line: String
        var failure: (reason: String, log: String)?
        switch job.status {
        case .done(let output): line = "Done   ·   " + output.lastPathComponent
        case .failed(let reason, let log):
            line = "Failed: " + reason
            failure = (reason, log)
        case .exporting(let value): line = "Exporting   \(Int((value * 100).rounded(.down)))%"
        case .paused: line = "Paused: destination can’t be written"
        default: line = job.status.title
        }
        status.stringValue = line
        status.toolTip = line
        status.textColor = failure != nil ? .systemRed : .secondaryLabelColor
        if let value = job.status.progress {
            progress.isHidden = false
            progress.doubleValue = value
        } else {
            progress.isHidden = true
        }
        let active = job.status.isActive
        cancel.isHidden = !(active || job.status == .pending || job.status == .paused)
        retry.isHidden = !job.status.canRetry
        if case .done = job.status { reveal.isHidden = false } else { reveal.isHidden = true }
        chooseFolder.isHidden = job.status != .paused
        disclosure.isHidden = failure == nil
        logTitle.isHidden = failure == nil
        disclosure.state = expanded ? .on : .off
        logScroll.isHidden = !(expanded && failure != nil)
        if let failure, expanded {
            let text = failure.log.isEmpty ? failure.reason : failure.reason + "\n\n" + failure.log
            if logText.string != text { logText.string = text }
        }
        setAccessibilityLabel(job.sourceURL.lastPathComponent + ", " + line)
    }

    @objc private func cancelPressed() { onCancel?() }
    @objc private func retryPressed() { onRetry?() }
    @objc private func revealPressed() { onReveal?() }
    @objc private func chooseFolderPressed() { onChooseFolder?() }
    @objc private func disclosePressed() { onDisclose?(disclosure.state == .on) }
}
