import AppShellKit
import SwiftUI

/// The App Shell: queue | monitor | inspector in an autosaved `HSplitView`, a flat
/// toolbar and a bottom status bar (layout per gate U1).
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
                    QueueSidebar(model: model)
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                }
                MonitorPane(model: model)
                    .frame(minWidth: 400)
                    .layoutPriority(1)
                if showInspector {
                    // The pane's content is rebuilt per selected job so the appearance controls show
                    // that job's settings; the stable ZStack keeps the split view's pane in place.
                    ZStack {
                        InspectorPane(model: model)
                            .id(model.selectedJobID)
                    }
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
                    toolbarLabel("Add Audio…", systemImage: "plus")
                }
                .buttonStyle(FlatToolbarButtonStyle(isOn: .constant(false)))
                .focusEffectDisabled()
                .help("Add audio files or a folder to the queue (Command-O).")
            }
            .buttonStyle(.borderless)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text(model.toolbarReadout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 360)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(model.formatDetail)
                    .accessibilityLabel("Export format")
                Button(action: model.toggleQueue) {
                    toolbarLabel(model.isExporting ? "Stop Queue" : "Start Queue",
                                 systemImage: model.isExporting ? "stop.fill" : "play.fill")
                }
                .buttonStyle(FlatToolbarButtonStyle(isOn: .constant(false)))
                .focusEffectDisabled()
                .disabled(model.isExporting ? model.queue.isStopping : !model.canStartQueue)
                .help(model.isExporting
                      ? "Stop the queue. The current job is cancelled; the rest stay Pending."
                      : "Export every Pending job, one at a time, in list order (Command-Return).")
                Button(action: model.exportSelected) {
                    toolbarLabel("Export Selected", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(FlatToolbarButtonStyle(isOn: .constant(false)))
                .focusEffectDisabled()
                .disabled(!model.canExportSelected)
                .help(EditorModel.exportHelp)
                PaneToggleButton(isOn: $showInspector, iconName: "sidebar.trailing",
                                 help: "Show or hide appearance settings.", highlightsWhenOn: false)
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

/// Replaces build 10's footer: status text, or the queue's overall progress while it runs.
private struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            if let line = model.progressLine, let progress = model.queue.overallProgress {
                Text(line)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(line)
                Spacer(minLength: 0)
                ProgressBarRepresentable(value: progress)
                    .frame(width: 180)
            } else {
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.statusHelp ?? model.status)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(Theme.secondaryBackground)
        .overlay(alignment: .top) { Divider() }
    }
}
