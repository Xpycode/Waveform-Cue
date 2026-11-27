import AppShellKit
import SwiftUI

/// The App Shell: queue | monitor | inspector in an autosaved `HSplitView`, a flat
/// toolbar and a bottom status bar. Parity layout for build 11 (gate U1 adds the
/// queue rows and Job inspector later).
struct MainWindow: View {
    let model: EditorModel

    @AppStorage("WaveformCue.showQueue") private var showQueue = true
    @AppStorage("WaveformCue.showInspector") private var showInspector = true

    var body: some View {
        // The status bar is stacked under the split view rather than added with
        // `.safeAreaInset`: HSplitView is AppKit-backed and ignores the inset, which
        // hid the transport row behind the bar (Atlas parity pass, 2026-11-27).
        VStack(spacing: 0) {
            HSplitView {
                if showQueue {
                    QueueSidebar()
                        .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
                }
                MonitorPane(model: model)
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                if showInspector {
                    InspectorPane(model: model)
                }
            }
            .autosaveSplitView(named: "WaveformCue.Main")
            .frame(maxHeight: .infinity)
            StatusBar(model: model)
        }
        .background(Theme.primaryBackground)
        .background(WindowReader { model.attach(window: $0) })
        .frame(minWidth: 690, minHeight: 530)
        .toolbar { toolbarContent }
        .toolbarRole(.editor)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            HStack(spacing: 6) {
                PaneToggleButton(isOn: $showQueue, iconName: "sidebar.leading",
                                 help: "Show or hide the queue.", highlightsWhenOn: false)
                Button(action: model.chooseAudio) {
                    toolbarLabel("Open Audio…", systemImage: "folder")
                }
                .buttonStyle(FlatToolbarButtonStyle(isOn: .constant(false)))
                .focusEffectDisabled()
                .disabled(model.isExporting)
                .help("Open an audio file (Command-O).")
            }
            .buttonStyle(.borderless)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text(EditorModel.formatReadout)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(EditorModel.formatDetail)
                    .accessibilityLabel("Export format")
                Button(action: model.exportOrCancel) {
                    toolbarLabel(model.isExporting ? "Cancel Export" : "Export MXF",
                                 systemImage: model.isExporting ? "xmark.circle" : "square.and.arrow.up")
                }
                .buttonStyle(FlatToolbarButtonStyle(isOn: .constant(false)))
                .focusEffectDisabled()
                .disabled(model.track == nil || model.isCancellingExport)
                .help(EditorModel.exportHelp)
                PaneToggleButton(isOn: $showInspector, iconName: "sidebar.trailing",
                                 help: "Show or hide appearance settings.", highlightsWhenOn: false)
                    .disabled(model.isExporting)
            }
            .buttonStyle(.borderless)
        }
    }

    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
            Text(title).font(.system(size: 12, weight: .semibold))
        }
    }
}

/// Replaces build 10's footer: status text, plus Show in Finder after an export.
private struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.status)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.statusHelp ?? model.status)
            Spacer(minLength: 0)
            if model.lastExport != nil {
                AppKitButton(title: "Show in Finder", action: model.revealExport)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.secondaryBackground)
        .overlay(alignment: .top) { Divider() }
    }
}
