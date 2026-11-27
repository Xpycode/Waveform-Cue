import AppKit
import SwiftUI

/// The queue footer's destination pop-up: "Beside source", the chosen folder (when one is set)
/// and "Choose Folder…". Choosing a folder opens an open panel through `EditorModel`; the
/// queue-wide folder wins over every job's own destination.
struct DestinationPopUpRepresentable: NSViewRepresentable {
    let model: EditorModel
    /// The queue-wide folder, or `nil` for beside each source.
    let folder: URL?
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.chosen(_:))
        popUp.setAccessibilityLabel("Destination")
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (popUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
        context.coordinator.rebuild(popUp, folder: folder)
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.model = model
        context.coordinator.rebuild(popUp, folder: folder)
        popUp.isEnabled = isEnabled
        popUp.toolTip = folder.map { "Every job is written to " + $0.path + "." }
            ?? "Each job is written beside its audio file (or the folder chosen with Export Selected to Folder…)."
    }

    @MainActor
    final class Coordinator: NSObject {
        static let besideTag = 1
        static let folderTag = 2
        static let chooseTag = 3

        var model: EditorModel
        private var shown: URL??

        init(model: EditorModel) { self.model = model }

        func rebuild(_ popUp: NSPopUpButton, folder: URL?) {
            guard shown != .some(folder) else { return }
            shown = .some(folder)
            popUp.removeAllItems()
            let menu = popUp.menu ?? NSMenu()
            menu.addItem(item("Beside source", tag: Self.besideTag))
            if let folder {
                let chosen = item(folder.lastPathComponent, tag: Self.folderTag)
                chosen.toolTip = folder.path
                chosen.image = NSWorkspace.shared.icon(forFile: folder.path)
                chosen.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(chosen)
            }
            menu.addItem(.separator())
            menu.addItem(item("Choose Folder…", tag: Self.chooseTag))
            popUp.selectItem(withTag: folder == nil ? Self.besideTag : Self.folderTag)
        }

        private func item(_ title: String, tag: Int) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = tag
            return item
        }

        @objc func chosen(_ sender: NSPopUpButton) {
            switch sender.selectedTag() {
            case Self.besideTag:
                model.setQueueDestination(nil)
            case Self.chooseTag:
                // Show the current choice again until the panel returns a folder.
                if let shown { sender.selectItem(withTag: shown == nil ? Self.besideTag : Self.folderTag) }
                model.chooseQueueDestination()
            default:
                break
            }
        }
    }
}
