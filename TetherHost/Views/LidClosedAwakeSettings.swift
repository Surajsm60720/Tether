import AppKit
import SwiftUI
import TetherCore

/// Settings → Lid-closed awake: status, short how-to, and one-time install.
struct LidClosedAwakeSettings: View {
    @Bindable var store: HostStore

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "laptopcomputer.and.arrow.down")
                        .font(.largeTitle)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.tether.accentText)
                        .frame(width: 44, alignment: .center)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stay reachable with the lid closed")
                            .font(.headline)
                        Text(
                            "A closed MacBook normally sleeps and drops Wi‑Fi / Tailscale. After a one-time setup, Tether can keep this Mac awake while you work remotely, then restore normal sleep."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Setup") {
                    Text(statusLabel)
                        .foregroundStyle(statusColor)
                }
                LabeledContent("Right now") {
                    Text(store.lidClosedAwakeActive ? "Holding awake" : "Not holding awake")
                        .foregroundStyle(store.lidClosedAwakeActive ? Color.tether.success : .secondary)
                }
                if !store.lidClosedAwakeReason.isEmpty {
                    Text(store.lidClosedAwakeReason)
                        .font(.callout)
                        .foregroundStyle(store.lidClosedAwakeActive ? Color.secondary : Color.tether.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L10n.preventSleep, isOn: Binding(
                    get: { store.preventSleepWhileActive },
                    set: { store.setPreventSleepWhileActive($0) }
                ))
                Toggle("Hold awake on battery", isOn: Binding(
                    get: { store.holdAwakeOnBattery },
                    set: { store.setHoldAwakeOnBattery($0) }
                ))
                LabeledContent("Power") {
                    Text(MacPowerSource.isExternallyPowered() ? "On AC" : "On battery")
                        .foregroundStyle(MacPowerSource.isExternallyPowered() ? Color.tether.success : Color.tether.warning)
                }
                LabeledContent("Other networks") {
                    Text(store.remoteEnabled ? "On" : "Off")
                        .foregroundStyle(store.remoteEnabled ? Color.tether.success : Color.tether.warning)
                }
                LabeledContent("iPhone connected") {
                    Text("\(store.connected.count)")
                        .monospacedDigit()
                }
                LabeledContent("Live agents") {
                    Text("\(store.runtimeLiveAgentCount)")
                        .monospacedDigit()
                }
            } header: {
                Text("Status")
            } footer: {
                Text("Needs Prevent sleep on, setup Installed, and Other networks on (or a connected iPhone / live agent). Turn off Hold awake on battery to skip lid-closed hold when unplugged — plug in for long remote sessions.")
            }

            Section {
                stepRow(1, "Install on this Mac", "Opens Terminal. Enter your login password once.")
                stepRow(2, "Turn on Prevent sleep and Other networks", "Right now should say Holding awake before you close the lid.")
                stepRow(3, "Close the lid and work remotely", "When nothing needs the Mac, normal sleep returns.")
            } header: {
                Text("How to use")
            }

            Section {
                Button {
                    store.refreshSleepPrivilegeStatus()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                if store.sleepPrivilegeStatus != .installed {
                    Button {
                        runInstall()
                    } label: {
                        Label(
                            store.sleepPrivilegeStatus == .agentNotRunning ? "Repair setup…" : "Install on this Mac…",
                            systemImage: "lock.open"
                        )
                    }
                }
                if store.sleepPrivilegeStatus != .notInstalled {
                    Button(role: .destructive) {
                        runUninstall()
                    } label: {
                        Label("Remove from this Mac…", systemImage: "trash")
                    }
                }
            } header: {
                Text("Setup")
            } footer: {
                Text("Install asks for your password once in Terminal. Recheck after it says Done.")
            }

            Section {
                pathRow("/etc/sudoers.d/tether-sleep", "Lets the helper run pmset without prompting again.")
                pathRow(
                    "~/Library/Application Support/Tether/tether-sleep-recovery.sh",
                    "Applies awake on/off for Host and clears it if Host crashes."
                )
                pathRow(
                    "~/Library/LaunchAgents/com.tether.host.sleep-recovery.plist",
                    "Runs that helper outside the app sandbox."
                )
            } header: {
                Text("Installed files")
            } footer: {
                Text("Keep the Mac ventilated with the lid closed — not in a bag. Prefer AC power for long sessions.")
            }

            Section {
                Text("For a real remote check: iPhone Wi‑Fi off, cellular on, Tailscale on, connect via the 100.x address, then close the lid. Same-home Wi‑Fi can hide Tailscale issues.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Tailscale tip")
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refreshSleepPrivilegeStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshSleepPrivilegeStatus()
        }
    }

    private var statusLabel: String {
        switch store.sleepPrivilegeStatus {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case .agentNotRunning: "Needs repair"
        case .recoveryPending: "Clearing stale awake…"
        }
    }

    private var statusColor: Color {
        switch store.sleepPrivilegeStatus {
        case .installed: Color.tether.success
        case .notInstalled: Color.secondary
        case .agentNotRunning, .recoveryPending: Color.tether.warning
        }
    }

    private func stepRow(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .frame(width: 22, height: 22)
                .background(Color.tether.accent.opacity(0.18), in: Circle())
                .foregroundStyle(Color.tether.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private func pathRow(_ path: String, _ purpose: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Text(purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func runInstall() {
        switch store.installSleepPrivilege() {
        case .openedTerminal:
            let alert = NSAlert()
            alert.messageText = "Terminal opened"
            alert.informativeText = "Enter your Mac password when asked. When Terminal says Done, come back here and press Recheck."
            alert.alertStyle = .informational
            alert.runModal()
        case let .failed(message):
            let alert = NSAlert()
            alert.messageText = "Couldn’t open Terminal"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func runUninstall() {
        let confirm = NSAlert()
        confirm.messageText = "Remove lid-closed setup?"
        confirm.informativeText = "Removes the privilege rule, LaunchAgent, and helper script. Terminal may ask for your password."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Remove")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        switch store.uninstallSleepPrivilege() {
        case .openedTerminal:
            break
        case let .failed(message):
            let alert = NSAlert()
            alert.messageText = "Couldn’t start remove"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
