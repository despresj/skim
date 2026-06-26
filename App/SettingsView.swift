import SwiftUI

/// A quiet gear pinned to the top-left corner that opens the Settings sheet. Shared
/// across the entry and reading surfaces so settings live in one predictable spot.
/// Same surface/hairline family as the other secondary controls.
struct SettingsGear: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.readingMuted)
                .frame(width: 40, height: 40)
                .background(Color.readingSurface.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Set-once reading preferences: which hand drives the rail, the speed a fresh read
/// opens at, and whether reading begins hands-free. Same warm reading-by-lamplight
/// surface as the rest of Skim. Everything here is a *default for new reads* — a
/// loaded read's live speed and hand still move freely; these just set the start.
struct SettingsView: View {
    let viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingAI = false

    /// The default starting band, derived from the persisted default WPM.
    private var band: SpeedBand { SpeedBand(wpm: viewModel.defaultWpm) }

    var body: some View {
        ZStack {
            ReadingCanvas()

            VStack(spacing: 0) {
                header
                Divider().overlay(Color.readingBorder)

                VStack(spacing: 26) {
                    handRow
                    speedRow
                    cruiseRow
                    aiRow
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .sheet(isPresented: $showingAI) {
                    if let service = viewModel.comprehension {
                        AIFeaturesView(service: service, settings: service.settingsForUI)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground { ReadingCanvas() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Spacer()
            Button("Done") { dismiss() }
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingAccent)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: Reading hand

    private var handRow: some View {
        SettingRow(title: "Reading hand",
                   subtitle: "Mirrors the rail, word, and speed dial to your thumb.") {
            HStack(spacing: 4) {
                handSegment(title: "Left", isLeft: true)
                handSegment(title: "Right", isLeft: false)
            }
            .padding(3)
            .background(Color.readingSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
        }
    }

    private func handSegment(title: String, isLeft: Bool) -> some View {
        let selected = viewModel.isLeftHanded == isLeft
        return Button {
            viewModel.isLeftHanded = isLeft
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? Color.readingOnAccent : Color.readingMuted)
                .padding(.vertical, 6)
                .padding(.horizontal, 16)
                .background { if selected { Capsule().fill(Color.readingAccent) } }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }

    // MARK: Default speed

    private var speedRow: some View {
        SettingRow(title: "Default speed",
                   subtitle: "Where a freshly opened read starts. Slide to change it live.") {
            HStack(spacing: 14) {
                stepButton(systemName: "minus", enabled: band.wpm > SpeedBand.minWPM) {
                    viewModel.defaultWpm = band.slower().wpm
                }

                VStack(spacing: 1) {
                    Text(band.label)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                    Text("\(band.wpm) wpm")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingMuted)
                }
                .frame(width: 74)

                stepButton(systemName: "plus", enabled: band.wpm < SpeedBand.maxWPM) {
                    viewModel.defaultWpm = band.faster().wpm
                }
            }
        }
    }

    private func stepButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Color.readingAccent : Color.readingMuted.opacity(0.4))
                .frame(width: 34, height: 34)
                .background(Color.readingSurface, in: Circle())
                .overlay(Circle().stroke(Color.readingBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Start in cruise

    private var cruiseRow: some View {
        SettingRow(title: "Start in cruise control",
                   subtitle: "Begin streaming hands-free the moment a read opens.") {
            Toggle("", isOn: Binding(
                get: { viewModel.startInCruise },
                set: { viewModel.startInCruise = $0 }
            ))
            .labelsHidden()
            .tint(Color.readingAccent)
        }
    }

    // MARK: AI features

    private var aiRow: some View {
        SettingRow(title: "AI features",
                   subtitle: "Optional comprehension checks with your own OpenAI key.") {
            Button { showingAI = true } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.readingMuted)
            }
            .buttonStyle(.plain)
        }
    }
}

/// One labelled settings row: a title + quiet subtitle on the left, the control on
/// the right, vertically centered.
private struct SettingRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text(subtitle)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
    }
}
