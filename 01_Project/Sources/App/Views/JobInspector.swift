import AppKit
import AppShellKit
import CueCore
import SwiftUI

/// The inspector's Job tab (gate U1): Export (preset, audio tracks, start timecode, filename),
/// Markers (music end, fade start, Reset), Loudness (I / TP / LRA, Normalise), Trim (in, out,
/// fades, pre-roll). Apply to All lives in the inspector footer (`InspectorPane`).
/// Every control is an AppKit wrapper; edits go to the selected job through `EditorModel`.
/// The running job's tab is dimmed and disabled (its settings are locked).
struct JobInspector: View {
    let model: EditorModel

    static let labelWidth: CGFloat = 85

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Job")
                    .font(.system(size: 17, weight: .semibold))
                if let job = model.selectedJob {
                    content(for: job)
                } else {
                    note("Select a job in the queue to see its export settings, markers and loudness.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func content(for job: CueJob) -> some View {
        Text(job.sourceURL.lastPathComponent)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(job.sourcePath)
        if !model.canEdit {
            message("This job is exporting. Its settings are locked.", color: Color(nsColor: .systemOrange))
        }
        Group {
            exportSection(job)
            markersSection(job)
            loudnessSection(job)
            trimSection(job)
        }
        .disabled(!model.canEdit)
        .opacity(model.canEdit ? 1 : 0.5)
    }

    // MARK: Export

    @ViewBuilder
    private func exportSection(_ job: CueJob) -> some View {
        section("Export")
        let preset = ExportPreset.preset(for: job.presetID) ?? .default
        row("Preset") {
            AppKitPopUp(items: ExportPreset.builtIn.map(\.name),
                        selection: ExportPreset.builtIn.firstIndex(of: preset) ?? 0,
                        accessibilityLabel: "Export preset",
                        toolTip: "Codec and picture format of this job’s MXF file.") { index in
                guard ExportPreset.builtIn.indices.contains(index) else { return }
                model.selectPreset(ExportPreset.builtIn[index])
            }
        }
        note(preset.detailedReadout(layout: job.layout))
        if let warning = preset.note {
            message(warning, color: Color(nsColor: .systemOrange))
        }
        row("Audio tracks") {
            AppKitPopUp(items: AudioLayout.allCases.map(\.title),
                        selection: AudioLayout.allCases.firstIndex(of: job.layout) ?? 0,
                        accessibilityLabel: "Audio tracks",
                        toolTip: "Mono PCM tracks: left on 1, right on 2, the rest digital silence.") { index in
                guard AudioLayout.allCases.indices.contains(index) else { return }
                model.selectAudioLayout(AudioLayout.allCases[index])
            }
            .frame(width: 119)
        }
        row("Start TC") {
            AppKitTextField(text: job.startTimecode, placeholder: CueJob.defaultStartTimecode,
                            accessibilityLabel: "Start timecode",
                            toolTip: "Embedded start timecode, HH:MM:SS:FF at 25 fps.",
                            monospaced: true,
                            onChange: { model.setStartTimecode($0) },
                            onCommit: { model.commitStartTimecode($0) })
                .frame(width: 119)
        }
        if let problem = model.timecodeProblem {
            message(problem, color: Color(nsColor: .systemRed))
        }
        row("Filename") {
            AppKitTextField(text: job.filenameTemplate, placeholder: CueJob.defaultFilenameTemplate,
                            accessibilityLabel: "Filename template",
                            toolTip: "Tokens: {name} (audio file name), {preset} and {date}.",
                            onChange: { model.setFilenameTemplate($0) },
                            onCommit: { model.commitFilenameTemplate($0) })
        }
        if let name = model.resolvedFilename {
            note("File: " + name)
                .help("A file that already exists is never overwritten: “ 2”, “ 3”… is added.")
        }
        note("Tokens: {name}, {preset}, {date}")
    }

    // MARK: Markers

    @ViewBuilder
    private func markersSection(_ job: CueJob) -> some View {
        section("Markers")
            .padding(.top, 11)
        if let detected = model.detectedMarkers {
            if detected.noMusic {
                message("No music detected", color: Color(nsColor: .systemOrange))
                note("The whole track stays below −60 dBFS, so no markers are set.")
            } else {
                let markers = model.selectedMarkers ?? detected
                markerRow("Music end", kind: .musicEnd, value: markers.musicEnd,
                          detected: detected.detectedMusicEnd, edited: job.markers.editedMusicEnd != nil)
                markerRow("Fade start", kind: .fadeStart, value: markers.fadeStart,
                          detected: detected.detectedFadeStart, edited: job.markers.editedFadeStart != nil)
                if let problem = model.markerMessage {
                    message(problem, color: Color(nsColor: .systemRed))
                }
                HStack(spacing: 8) {
                    AppKitPushButton(title: "Reset",
                                     toolTip: "Return both markers to the detected values.") {
                        model.resetMarkers()
                    }
                    .disabled(!job.markers.isEdited)
                    note("Drag a marker in the monitor, or type seconds or M:SS.ff.")
                }
            }
        } else {
            note("Markers appear once the track has been analysed.")
        }
    }

    @ViewBuilder
    private func markerRow(_ title: String, kind: MarkerKind, value: Double?, detected: Double?,
                           edited: Bool) -> some View {
        row(title) {
            HStack(spacing: 8) {
                AppKitTextField(text: value.map(MarkerTime.format) ?? "",
                                placeholder: "0:00.00",
                                accessibilityLabel: title,
                                toolTip: "Seconds (83.5) or M:SS.ff (1:23.50).",
                                monospaced: true,
                                onCommit: { model.commitMarker(kind, text: $0) })
                    .frame(width: 90)
                Text(edited ? "Edited" + (detected.map { " · was " + MarkerTime.format($0) } ?? "") : "Detected")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Loudness

    @ViewBuilder
    private func loudnessSection(_ job: CueJob) -> some View {
        section("Loudness")
            .padding(.top, 11)
        if let loudness = job.loudness {
            row("Integrated") { value(loudness.integratedLUFS.map { Self.decibels($0) + " LUFS" } ?? "Silent") }
            row("True peak") { value(loudness.truePeakDBTP.map { Self.decibels($0) + " dBTP" } ?? "Silent") }
            row("Range") { value(String(format: "%.1f LU", loudness.rangeLU)) }
            if Loudness.isFlagged(loudness) {
                badge("Outside EBU R 128: −23 ±1 LUFS, true peak ≤ −1 dBTP")
            } else {
                note("Within EBU R 128.")
            }
        } else if let failure = model.loudnessFailures[job.id] {
            message("Loudness couldn’t be measured.", color: Color(nsColor: .systemRed))
            note(failure)
                .lineLimit(3)
                .help(failure)
            AppKitPushButton(title: "Measure Again", controlSize: .small) { model.measureLoudnessAgain() }
        } else if model.measuringJobID == job.id {
            note("Measuring loudness…")
        } else {
            note("Waiting to measure loudness.")
        }
        AppKitCheckbox(title: "Normalise to −23 LUFS", isOn: job.normalise,
                       toolTip: "Apply one linear gain on export, held back if the true peak would pass −1 dBTP. No compression or limiting.") {
            model.setNormalise($0)
        }
        if job.normalise {
            normaliseResult(job.loudness)
        }
    }

    @ViewBuilder
    private func normaliseResult(_ loudness: LoudnessMeasurement?) -> some View {
        if let loudness {
            let result = Loudness.normalisation(for: loudness)
            if loudness.isSilent {
                note("The track is silent; nothing is normalised.")
            } else if result.limitedByPeak {
                message("Peak-limited: gain " + Self.gain(result.gainDB) + " reaches "
                        + Self.decibels(result.achievedLUFS) + " LUFS, not −23.",
                        color: Color(nsColor: .systemOrange))
            } else {
                note("Gain " + Self.gain(result.gainDB) + " reaches −23.0 LUFS.")
            }
        } else {
            note("The gain is worked out when the loudness has been measured (at export at the latest).")
        }
    }

    // MARK: Trim

    @ViewBuilder
    private func trimSection(_ job: CueJob) -> some View {
        section("Trim")
            .padding(.top, 11)
        trimPointRow("In", edge: .inPoint, value: job.trim.inPoint, placeholder: "Start",
                     toolTip: "Where the clip’s music starts, in source time: seconds (83.5) or M:SS.ff. Empty is the start of the file. I sets it at the playhead.")
        trimPointRow("Out", edge: .outPoint, value: job.trim.outPoint, placeholder: "End",
                     toolTip: "Where the clip’s music ends, in source time: seconds (83.5) or M:SS.ff. Empty is the end of the file. O sets it at the playhead.")
        if let problem = model.trimMessage {
            message(problem, color: Color(nsColor: .systemRed))
        }
        if let problem = model.trimProblem {
            message(problem, color: Color(nsColor: .systemRed))
        }
        row("Fade in") {
            secondsPopUp(TrimSettings.fadeChoices, selected: job.trim.fadeIn, zero: "None",
                         accessibilityLabel: "Fade in",
                         toolTip: "Audio fade-in from the in point. The picture is not faded.") {
                model.selectFade(.inPoint, seconds: $0)
            }
        }
        row("Fade out") {
            secondsPopUp(TrimSettings.fadeChoices, selected: job.trim.fadeOut, zero: "None",
                         accessibilityLabel: "Fade out",
                         toolTip: "Audio fade-out to the out point. The picture is not faded.") {
                model.selectFade(.outPoint, seconds: $0)
            }
        }
        row("Pre-roll") {
            secondsPopUp(TrimSettings.preRollChoices, selected: job.trim.preRoll, zero: "Off",
                         accessibilityLabel: "Pre-roll",
                         toolTip: "A slate with the title, music duration, loudness and “Starts in” over silence before the music. The start timecode stays on the first music frame.") {
                model.selectPreRoll($0)
            }
        }
        if let summary = model.trimSummary {
            note(summary)
        }
        note("Press I or O to set a point at the playhead, or drag the brackets beside the waveform.")
    }

    private func trimPointRow(_ title: String, edge: TrimEdge, value: Double?, placeholder: String,
                              toolTip: String) -> some View {
        row(title) {
            AppKitTextField(text: value.map(MarkerTime.format) ?? "",
                            placeholder: placeholder,
                            accessibilityLabel: title + " point",
                            toolTip: toolTip,
                            monospaced: true,
                            onCommit: { model.commitTrimPoint(edge, text: $0) })
                .frame(width: 90)
        }
    }

    /// A pop-up of second values ("None" or "Off" for 0). A stored value that is not offered
    /// shows the nearest choice.
    private func secondsPopUp(_ choices: [Double], selected: Double, zero: String, accessibilityLabel: String,
                              toolTip: String, onSelect: @escaping (Double) -> Void) -> some View {
        let nearest = choices.indices.min { abs(choices[$0] - selected) < abs(choices[$1] - selected) } ?? 0
        return AppKitPopUp(items: choices.map { $0 == 0 ? zero : Self.seconds($0) },
                           selection: nearest,
                           accessibilityLabel: accessibilityLabel,
                           toolTip: toolTip) { index in
            guard choices.indices.contains(index) else { return }
            onSelect(choices[index])
        }
        .frame(width: 90)
    }

    /// "0.5 s", "2 s".
    static func seconds(_ value: Double) -> String {
        (value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)) + " s"
    }

    // MARK: Building blocks

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.system(size: 13).monospacedDigit())
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: .systemOrange))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .systemOrange).opacity(0.15)))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Loudness outside EBU R 128")
    }

    /// "−14.2" with a true minus sign.
    static func decibels(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: "-", with: "−")
    }

    /// "+3.2 dB" or "−1.5 dB".
    static func gain(_ value: Double) -> String {
        (value >= 0 ? "+" : "") + decibels(value) + " dB"
    }
}

/// Marker times in the Job tab: shown as M:SS.ff (hundredths of a second); typed as seconds
/// (`83.5`) or M:SS.ff (`1:23.50`, `1:23`).
enum MarkerTime {
    static func format(_ seconds: Double) -> String {
        let hundredths = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }

    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        func number(_ part: Substring) -> Double? {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(part), value.isFinite else { return nil }
            return value
        }
        switch parts.count {
        case 1:
            return number(parts[0])
        case 2:
            guard parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), let minutes = Int(parts[0]),
                  let seconds = number(parts[1]), seconds < 60 else { return nil }
            return Double(minutes) * 60 + seconds
        default:
            return nil
        }
    }
}
