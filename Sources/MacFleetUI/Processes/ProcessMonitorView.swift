import MacFleetKit
import MacFleetState
import SwiftUI

/// The process window: a summary, a name search, sort and grouping controls, and the list. It takes presentation
/// values and forwards actions, and holds no state of its own. Values that macOS does not let us read appear as the
/// reason, in place of a number.
public struct ProcessMonitorView: View {
    private let presentation: ProcessListPresentation
    private let searchText: String
    private let onSearch: @Sendable (String) -> Void
    private let onSort: @Sendable (ProcessSortKey) -> Void
    private let onMode: @Sendable (ProcessListMode) -> Void

    public init(
        presentation: ProcessListPresentation,
        searchText: String,
        onSearch: @escaping @Sendable (String) -> Void,
        onSort: @escaping @Sendable (ProcessSortKey) -> Void,
        onMode: @escaping @Sendable (ProcessListMode) -> Void
    ) {
        self.presentation = presentation
        self.searchText = searchText
        self.onSearch = onSearch
        self.onSort = onSort
        self.onMode = onMode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            content
        }
        .padding()
        .frame(minWidth: 680, minHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Processes")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let summary = presentation.summary {
                Text(summary.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("CPU: \(summary.cpuText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Memory: \(summary.memoryText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search by name", text: Binding(get: { searchText }, set: onSearch))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search processes by name")
            Picker("Sort by", selection: Binding(get: { presentation.sort }, set: onSort)) {
                ForEach(ProcessSortKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .accessibilityLabel("Sort processes by")
            Picker("View", selection: Binding(get: { presentation.mode }, set: onMode)) {
                ForEach(ProcessListMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .accessibilityLabel("Show processes or apps")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let status = presentation.status {
            Text(status)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch presentation.mode {
            case .processes:
                processList
            case .apps:
                appList
            }
        }
    }

    private var processList: some View {
        List(presentation.rows) { row in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(row.pidText)
                    .font(.caption.monospacedDigit())
                    .frame(width: 84, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    text(row.name, font: .callout.weight(.medium))
                    text(row.started, font: .caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                text(row.cpu, font: .callout.monospacedDigit())
                    .frame(width: 112, alignment: .trailing)
                text(row.memory, font: .callout.monospacedDigit())
                    .frame(width: 112, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.spokenSummary)
        }
    }

    private var appList: some View {
        List(presentation.groups) { group in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(.callout.weight(.medium))
                    Text(group.countText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                text(group.cpu, font: .callout.monospacedDigit())
                    .frame(width: 112, alignment: .trailing)
                text(group.memory, font: .callout.monospacedDigit())
                    .frame(width: 112, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A reading's text, or the reason it is missing in secondary style.
    @ViewBuilder
    private func text(_ value: Presented<String>, font: Font) -> some View {
        switch value {
        case let .available(string):
            Text(string).font(font)
        case let .unavailable(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(reason)
        }
    }
}
