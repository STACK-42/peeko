import PeekoCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var username = ""
    @ViewState private var token = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection(title: "GitHub") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("@").foregroundStyle(Theme.muted)
                        TextField("username", text: $username)
                            .textFieldStyle(.plain)
                            .onSubmit(commitUsername)
                        if username != model.settings.githubUsername {
                            Button("Save", action: commitUsername)
                                .buttonStyle(.plain)
                                .font(Theme.mono().weight(.medium))
                                .foregroundStyle(usernameIsValid ? Theme.green : Theme.muted)
                                .disabled(!usernameIsValid)
                        }
                    }
                    .font(.system(size: 13))
                    Divider().overlay(Color.white.opacity(0.08))
                    if model.hasGitHubToken {
                        HStack {
                            Text("Token saved in Keychain").font(.system(size: 13))
                            Spacer()
                            Button("Remove") { model.setGitHubToken("") }
                                .buttonStyle(.plain)
                                .font(Theme.mono().weight(.medium))
                                .foregroundStyle(Theme.muted)
                        }
                    } else {
                        HStack(spacing: 6) {
                            SecureField("token for private repos (optional)", text: $token)
                                .textFieldStyle(.plain)
                                .onSubmit(commitToken)
                            if !token.isEmpty {
                                Button("Save", action: commitToken)
                                    .buttonStyle(.plain)
                                    .font(Theme.mono().weight(.medium))
                                    .foregroundStyle(Theme.green)
                            }
                        }
                        .font(.system(size: 13))
                    }
                    Text(model.hasGitHubToken
                         ? "Public and private pushes. Checked every 10 minutes."
                         : "Public pushes only. Add a classic token with the repo scope to count private ones too. Checked every 10 minutes.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .card()
            }

            PanelSection(title: "Notifications") {
                VStack(alignment: .leading, spacing: 10) {
                    notificationPermission
                    Divider().overlay(Color.white.opacity(0.08))
                    Toggle(isOn: Binding(
                        get: { model.settings.eveningNudgeEnabled },
                        set: { on in model.updateSettings { $0.eveningNudgeEnabled = on } }
                    )) {
                        Text("Evening reminder").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.green)
                    if model.settings.eveningNudgeEnabled {
                        HStack {
                            Text("if anything's left at")
                                .font(Theme.mono())
                                .foregroundStyle(Theme.muted)
                            Spacer()
                            DatePicker("", selection: nudgeTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.field)
                                .fixedSize()
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    Toggle(isOn: Binding(
                        get: { model.settings.breakRemindersEnabled },
                        set: { on in model.updateSettings { $0.breakRemindersEnabled = on } }
                    )) {
                        Text("Break reminders").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.green)
                    if model.settings.breakRemindersEnabled {
                        HStack {
                            Text("a 5-min walk after every")
                                .font(Theme.mono())
                                .foregroundStyle(Theme.muted)
                            Spacer()
                            Stepper(value: Binding(
                                get: { model.settings.breakIntervalMinutes },
                                set: { minutes in model.updateSettings { $0.breakIntervalMinutes = minutes } }
                            ), in: 30...120, step: 15) {
                                Text("\(model.settings.breakIntervalMinutes) min")
                                    .font(Theme.mono())
                                    .monospacedDigit()
                            }
                            .controlSize(.mini)
                        }
                    }
                }
                .card()
            }

            PanelSection(title: "General") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { model.launchAtLoginStatus == .enabled },
                        set: { model.setLaunchAtLogin($0) }
                    )) {
                        Text("Launch at login").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Theme.green)
                    if model.launchAtLoginStatus == .requiresApproval {
                        Button("Approve in System Settings → Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono())
                        .foregroundStyle(Theme.green)
                    }
                    if model.needsAccessibility || model.accessibilityTrusted {
                        Divider().overlay(Color.white.opacity(0.08))
                        if model.accessibilityTrusted {
                            Label("Accessibility is on (for website limits)", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.green)
                        } else {
                            linkRow("Website limits need Accessibility", action: "Allow") { model.requestAccessibility() }
                            Text("Peeko reads only the front window's title, to spot sites like YouTube.")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                    linkRow("Your data", action: "Reveal in Finder") { model.revealDataFolder() }
                    linkRow("Everything in one file", action: "Export JSON…") { model.exportData() }
                    linkRow("Updates", action: "Check now") { model.checkForUpdates() }
                    Text("Peeko looks for a new version once a day.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                }
                .card()
            }
        }
        .onAppear { username = model.settings.githubUsername }
    }

    @ViewBuilder
    private var notificationPermission: some View {
        switch model.notificationStatus {
        case .authorized, .provisional, .ephemeral:
            Label("Notifications are on", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.green)
        case .denied:
            linkRow("Notifications are off", action: "Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
        default:
            linkRow("Get a ping when Peeko sees something", action: "Allow") {
                Task { await model.requestNotifications() }
            }
        }
    }

    private func linkRow(_ label: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.system(size: 13))
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(Theme.mono().weight(.medium))
                .foregroundStyle(Theme.green)
        }
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private var usernameIsValid: Bool {
        trimmedUsername.isEmpty || GitHubEventsClient.isValidUsername(trimmedUsername)
    }

    private func commitUsername() {
        guard usernameIsValid else { return }
        let name = trimmedUsername
        username = name
        model.updateSettings { $0.githubUsername = name }
    }

    private func commitToken() {
        model.setGitHubToken(token)
        token = ""
    }

    private var nudgeTime: Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings.eveningNudgeMinutes
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.updateSettings { $0.eveningNudgeMinutes = (c.hour ?? 21) * 60 + (c.minute ?? 0) }
            }
        )
    }
}
