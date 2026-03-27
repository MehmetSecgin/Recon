import AppKit
import SwiftUI

struct DiagnosticsWindowView: View {
    @ObservedObject var viewModel: DiagnosticsViewModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    currentTabContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 560, height: 520)
        .background(DiagnosticsWindowConfigurator())
        .onAppear {
            viewModel.activateWindow()
        }
        .onDisappear {
            viewModel.deactivateWindow()
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(DiagnosticsViewModel.Tab.allCases, id: \.self) { tab in
                    Button {
                        viewModel.selectTab(tab)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 12, weight: viewModel.selectedTab == tab ? .medium : .regular))

                            Text(tab.title)
                                .font(.system(size: 12, weight: viewModel.selectedTab == tab ? .medium : .regular))
                        }
                        .foregroundStyle(Color(nsColor: .labelColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(viewModel.selectedTab == tab ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch viewModel.selectedTab {
        case .health:
            healthTab
        case .logs:
            logsTab
        case .history:
            historyTab
        }
    }

    private var healthTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = viewModel.healthSnapshot, snapshot.telepresenceUnavailable {
                DiagnosticsCallout(
                    title: "Telepresence not found",
                    message: snapshot.unavailableReason ?? "Install Telepresence or set TELEPRESENCE_PATH."
                )
                .padding(.bottom, 14)
            }

            DiagnosticsSection(title: "COMPONENT STATUS", topPadding: 0) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(viewModel.healthCards()) { card in
                        DiagnosticsHealthCardView(card: card)
                    }
                }
            }

            DiagnosticsSection(title: "SESSION DETAILS", topPadding: 20) {
                DiagnosticsCard {
                    ForEach(Array(viewModel.sessionDetails().enumerated()), id: \.offset) { index, item in
                        DiagnosticsValueRow(key: item.0, value: item.1)

                        if index < viewModel.sessionDetails().count - 1 {
                            DiagnosticsInsetDivider()
                        }
                    }
                }
            }

            DiagnosticsSection(title: "ACTIONS", topPadding: 20) {
                HStack(spacing: 10) {
                    Button("Copy 'telepresence status'") {
                        viewModel.copyStatusCommand()
                    }
                    .buttonStyle(.borderedProminent)

                    Button(viewModel.isExportingBundle ? "Exporting..." : "Export diagnostic bundle") {
                        viewModel.exportDiagnosticBundle()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isExportingBundle)
                }
            }

            if let exportStatusMessage = viewModel.exportStatusMessage, !exportStatusMessage.isEmpty {
                Text(exportStatusMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            if let healthErrorMessage = viewModel.healthErrorMessage,
               !healthErrorMessage.isEmpty,
               viewModel.healthSnapshot?.telepresenceUnavailable == false {
                Text(healthErrorMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
    }

    private var logsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiagnosticsSection(title: "LOG SOURCE", topPadding: 0) {
                DiagnosticsCard {
                    HStack(spacing: 12) {
                        Picker(
                            "Log source",
                            selection: Binding(
                                get: { viewModel.selectedLogSource },
                                set: { viewModel.selectLogSource($0) }
                            )
                        ) {
                            Text("Unavailable").tag(Optional<DiagnosticsLogSource>.none)
                            ForEach(DiagnosticsLogSource.allCases) { source in
                                let exists = viewModel.sourceStates.first(where: { $0.source == source })?.exists == true
                                Text(source.title).tag(Optional(source))
                                    .disabled(!exists)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 180, alignment: .leading)

                        TextField(
                            "Filter logs",
                            text: Binding(
                                get: { viewModel.filterText },
                                set: { viewModel.filterText = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 10)

                    HStack(spacing: 8) {
                        ForEach([DiagnosticsLogLevel.info, .warn, .error], id: \.self) { level in
                            DiagnosticsLevelToggle(
                                title: level.rawValue,
                                isSelected: viewModel.includedLogLevels.contains(level),
                                action: { viewModel.toggleLogLevel(level) }
                            )
                        }

                        Spacer(minLength: 0)
                    }
                }
            }

            DiagnosticsSection(title: "LIVE LOG", topPadding: 20) {
                DiagnosticsLogViewer(
                    entries: viewModel.filteredLogEntries,
                    selectedSourceState: viewModel.selectedSourceState,
                    logsDirectoryExists: viewModel.logsDirectoryExists
                )
                .frame(height: 280)
            }

            DiagnosticsSection(title: "ACTIONS", topPadding: 20) {
                HStack(spacing: 10) {
                    Button("Open in Console.app") {
                        viewModel.openSelectedLogInConsole()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenSelectedLog)

                    Button("Reveal log file") {
                        viewModel.revealSelectedLog()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenSelectedLog && !viewModel.logsDirectoryExists)
                }
            }
        }
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            DiagnosticsSection(title: "EVENT HISTORY", topPadding: 0) {
                DiagnosticsCard {
                    if viewModel.isLoadingHistory && viewModel.historyItems.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if viewModel.historyItems.isEmpty {
                        Text("No diagnostic events recorded yet.")
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(viewModel.historyItems.enumerated()), id: \.element.id) { index, item in
                            DiagnosticsHistoryRow(item: item)

                            if index < viewModel.historyItems.count - 1 {
                                DiagnosticsInsetDivider()
                            }
                        }
                    }
                }
            }

            if let historyErrorMessage = viewModel.historyErrorMessage, !historyErrorMessage.isEmpty {
                Text(historyErrorMessage)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Text("Showing last 7 days. Older events are in the log file.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
    }
}

private struct DiagnosticsSection<Content: View>: View {
    let title: String
    let topPadding: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                .tracking(0.5)
                .padding(.top, topPadding)

            content
                .padding(.top, 6)
        }
    }
}

private struct DiagnosticsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DiagnosticsInsetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
            .padding(.leading, 12)
    }
}

private struct DiagnosticsCallout: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.red)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }
}

private struct DiagnosticsHealthCardView: View {
    let card: DiagnosticsHealthCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                Text(card.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }

            Text(card.value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var color: Color {
        switch card.state {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        case .inactive:
            return .secondary
        case .unavailable:
            return .gray
        }
    }
}

private struct DiagnosticsValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct DiagnosticsLevelToggle: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color(nsColor: .secondaryLabelColor))
    }
}

private struct DiagnosticsLogViewer: View {
    private enum ScrollTarget {
        static let bottom = "diagnostics-log-bottom"
    }

    let entries: [DiagnosticsLogEntry]
    let selectedSourceState: DiagnosticsLogFileState?
    let logsDirectoryExists: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if logsDirectoryExists == false {
                        DiagnosticsLogEmptyState(
                            message: "Telepresence logs haven't been created yet.",
                            detail: NSString(string: TelepresenceLogLocator().logsDirectoryURL.path).abbreviatingWithTildeInPath
                        )
                    } else if selectedSourceState?.exists != true {
                        DiagnosticsLogEmptyState(
                            message: "The selected live log file isn't available.",
                            detail: selectedSourceState?.fileURL?.lastPathComponent ?? "Select a log source"
                        )
                    } else if entries.isEmpty {
                        DiagnosticsLogEmptyState(
                            message: "No matching log lines.",
                            detail: "Adjust the source, filter, or level toggles."
                        )
                    } else {
                        ForEach(entries) { entry in
                            DiagnosticsLogLine(entry: entry)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(ScrollTarget.bottom)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onAppear {
                scrollToBottom(using: proxy)
            }
            .onChange(of: entries.last?.id) { _, _ in
                scrollToBottom(using: proxy)
            }
            .onChange(of: selectedSourceState?.source) { _, _ in
                scrollToBottom(using: proxy)
            }
        }
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scrollToBottom(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(ScrollTarget.bottom, anchor: .bottom)
        }
    }
}

private struct DiagnosticsLogEmptyState: View {
    let message: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))

            Text(detail)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.vertical, 18)
    }
}

private struct DiagnosticsLogLine: View {
    let entry: DiagnosticsLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let timestampText = entry.timestampText {
                Text(timestampText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
            }

            if entry.level != .unknown {
                Text(entry.level.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor)
            }

            Text(entry.messageText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.9))
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:
            return Color(red: 0.43, green: 0.72, blue: 1.0)
        case .warn:
            return Color(red: 1.0, green: 0.81, blue: 0.27)
        case .error:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .unknown:
            return Color.white.opacity(0.65)
        }
    }
}

private struct DiagnosticsHistoryRow: View {
    let item: DiagnosticsHistoryItem

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(item.message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            Text(timestampText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var color: Color {
        switch item.tint {
        case .green:
            return .green
        case .gray:
            return .secondary
        case .red:
            return .red
        case .orange:
            return .orange
        case .blue:
            return .blue
        }
    }

    private var timestampText: String {
        if Calendar.current.isDateInToday(item.occurredAt) {
            return Self.todayTimeFormatter.string(from: item.occurredAt)
        }

        return Self.dateTimeFormatter.string(from: item.occurredAt)
    }

    private static let todayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct DiagnosticsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureWindow(for: nsView)
    }

    private func configureWindow(for view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            DiagnosticsWindowPresenter.configure(window)
            window.isOpaque = false
            window.backgroundColor = NSColor.windowBackgroundColor
            window.level = .floating
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
