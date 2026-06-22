import SwiftUI

/// The "Make reading video" sheet — a small production panel pulled up over the
/// current read, not a separate app. The reader is already paused behind it. It asks
/// only what it can't infer (title, speed, format, which cards/branding), renders in
/// place, then hands the file to the system share sheet. The mental model is "I'm
/// reading this; this one's good; make a video from it."
///
/// Lifecycle, all without ever resuming the reader: render replaces the questions
/// with progress (cancellable); on completion the share sheet opens automatically;
/// when it closes, the whole panel dismisses back to the paused read.
struct ExportView: View {
    @Bindable var viewModel: ExportViewModel
    @Environment(\.dismiss) private var dismiss

    /// The finished file to share (carried in an item so the share sheet can never be
    /// presented with empty contents).
    @State private var shareItem: ShareItem?

    private struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var settings: ExportSettings { viewModel.settings }

    var body: some View {
        ZStack {
            ReadingCanvas().ignoresSafeArea()
            switch viewModel.phase {
            case .idle, .failed:
                questions
            case let .rendering(progress):
                renderingPanel(progress: progress, cancellable: true)
            case .done:
                renderingPanel(progress: 1, cancellable: false)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // When the share sheet closes (shared or dismissed), return to the paused
        // reader — the user just did a creator action; let them decide what's next.
        .sheet(item: $shareItem, onDismiss: { dismiss() }) { item in
            ShareSheet(items: [item.url])
        }
        .onChange(of: viewModel.phase) { _, new in
            if case let .done(url) = new { shareItem = ShareItem(url: url) }
        }
    }

    // MARK: Questions

    private var questions: some View {
        VStack(spacing: 0) {
            header
            Form {
                titleSection
                speedSection
                formatSection
                optionsSection
            }
            .scrollContentBackground(.hidden)
            .tint(Color.readingAccent)
            exportBar
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Make reading video")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text("Turn this read into a vertical MP4.")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.readingMuted)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private var titleSection: some View {
        Section("Title") {
            TextField("Optional title", text: $viewModel.settings.title)
                .foregroundStyle(Color.readingForeground)
        }
        .foregroundStyle(Color.readingForeground)
    }

    private var speedSection: some View {
        Section("Speed") {
            HStack {
                Text("\(viewModel.bandLabel) · \(settings.wpm) wpm")
                    .foregroundStyle(Color.readingForeground)
                    .monospacedDigit()
                Spacer()
                Button { viewModel.slower() } label: {
                    Image(systemName: "minus.circle").foregroundStyle(Color.readingAccent)
                }
                .buttonStyle(.plain)
                Button { viewModel.faster() } label: {
                    Image(systemName: "plus.circle").foregroundStyle(Color.readingAccent)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Text("Estimated \(settings.format == .gif ? "GIF" : "video"): \(viewModel.estimateLabel)")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                    .monospacedDigit()
                Spacer()
            }
            if let warning = viewModel.warning {
                Text(warning)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingAccent)
            }
        }
        .foregroundStyle(Color.readingForeground)
    }

    private var formatSection: some View {
        Section {
            Picker("Format", selection: $viewModel.settings.format) {
                Text("MP4 Video").tag(ExportSettings.Format.mp4)
                Text("GIF Preview").tag(ExportSettings.Format.gif)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Format")
        } footer: {
            if settings.format == .gif {
                Text("GIF is for short previews only.")
            }
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section("Options") {
            // Title and end cards are an MP4 concept; a GIF carries neither.
            if settings.format == .mp4 {
                Toggle("Include title card", isOn: $viewModel.settings.includeTitleCard)
                Toggle("Include end card", isOn: $viewModel.settings.includeEndCard)
            }
            Toggle("Show progress bar", isOn: $viewModel.settings.includeProgressBar)
            Toggle("Skim watermark", isOn: watermarkBinding)

            if settings.format == .mp4 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("End card text")
                        .font(.footnote)
                        .foregroundStyle(Color.readingMuted)
                    TextField("End card text", text: $viewModel.settings.endCardText, axis: .vertical)
                        .lineLimit(1...3)
                        .foregroundStyle(Color.readingForeground)
                }
            }
        }
        .foregroundStyle(Color.readingForeground)
    }

    /// One watermark toggle that drives the right field for the active format.
    private var watermarkBinding: Binding<Bool> {
        settings.format == .mp4
            ? $viewModel.settings.includeWatermark
            : $viewModel.settings.gifWatermark
    }

    /// The pinned primary action.
    private var exportBar: some View {
        VStack(spacing: 8) {
            if case let .failed(message) = viewModel.phase {
                Text(message)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.readingAccent)
                    .multilineTextAlignment(.center)
            }
            Button(viewModel.exportButtonTitle) { viewModel.export() }
                .buttonStyle(PrimaryPillStyle())
                .disabled(!viewModel.canExport)
                .opacity(viewModel.canExport ? 1 : 0.5)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.readingBorder).frame(height: 1)
        }
    }

    // MARK: Rendering (replaces the sheet contents)

    private func renderingPanel(progress: Double, cancellable: Bool) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Rendering video")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingForeground)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Color.readingAccent)
                .monospacedDigit()
            ProgressView(value: progress)
                .tint(Color.readingAccent)
                .padding(.horizontal, 64)
            Spacer()
            if cancellable {
                Button("Cancel") {
                    viewModel.cancelExport()
                    dismiss()
                }
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.readingMuted)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
