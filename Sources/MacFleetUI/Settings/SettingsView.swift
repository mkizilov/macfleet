import MacFleetKit
import MacFleetState
import SwiftUI

/// The Settings window: General preferences, and the Notifications pane supplied by the caller. It takes presentation
/// values and action closures only. Each control has a label, and each explains what it does.
public struct SettingsView<Notifications: View>: View {
    private let presentation: PreferencesPresentation
    private let onMenuBar: @Sendable (MenuBarMetric, Bool) -> Void
    private let onRefresh: @Sendable (RefreshKind, Int) -> Void
    private let onLaunchAtLogin: @Sendable (Bool) -> Void
    private let onOpenLoginItems: @Sendable () -> Void
    private let onPane: @Sendable (SettingsPane) -> Void
    private let onReset: @Sendable () -> Void
    private let notifications: Notifications

    public init(
        presentation: PreferencesPresentation,
        onMenuBar: @escaping @Sendable (MenuBarMetric, Bool) -> Void,
        onRefresh: @escaping @Sendable (RefreshKind, Int) -> Void,
        onLaunchAtLogin: @escaping @Sendable (Bool) -> Void,
        onOpenLoginItems: @escaping @Sendable () -> Void,
        onPane: @escaping @Sendable (SettingsPane) -> Void,
        onReset: @escaping @Sendable () -> Void,
        @ViewBuilder notifications: () -> Notifications
    ) {
        self.presentation = presentation
        self.onMenuBar = onMenuBar
        self.onRefresh = onRefresh
        self.onLaunchAtLogin = onLaunchAtLogin
        self.onOpenLoginItems = onOpenLoginItems
        self.onPane = onPane
        self.onReset = onReset
        self.notifications = notifications()
    }

    public var body: some View {
        TabView(selection: Binding(get: { presentation.pane }, set: onPane)) {
            generalPane
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsPane.general)
            notifications
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsPane.notifications)
        }
        .frame(minWidth: 500, minHeight: 460)
    }

    private var generalPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionCard("Menu bar") {
                    ForEach(presentation.menuBarOptions) { option in
                        Toggle(option.title, isOn: Binding(get: { option.isShown }, set: { onMenuBar(option.metric, $0) }))
                    }
                    Text(presentation.menuBarSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SectionCard("Refresh rates") {
                    ForEach(presentation.refreshRows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Picker(row.title, selection: Binding(get: { row.selectedSeconds }, set: { onRefresh(row.kind, $0) })) {
                                ForEach(row.choices) { choice in
                                    Text(choice.title).tag(choice.seconds)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityHint(row.help)
                            Text(row.help)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(presentation.energySummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SectionCard("Startup") {
                    Toggle("Open MacFleet at Login", isOn: Binding(get: { presentation.launch.isOn }, set: onLaunchAtLogin))
                        .disabled(!presentation.launch.canChange)
                        .accessibilityHint(presentation.launch.helpText)
                    Text(presentation.launch.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if presentation.launch.showsLoginItemsLink {
                        Button("Open Login Items Settings", action: onOpenLoginItems)
                    }
                    if let notice = presentation.launchNotice {
                        Label(notice, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let notice = presentation.loadNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = presentation.saveNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: onReset)
                        .disabled(presentation.isDefault)
                }
            }
            .padding()
        }
    }
}
