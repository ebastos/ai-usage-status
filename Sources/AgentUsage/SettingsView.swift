import AgentUsageCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage("showMenuBarText") private var showMenuBarText = true
    @AppStorage("enabledProviders") private var enabledRaw = ProviderID.all.joined(separator: ",")
    @AppStorage("providerOrder") private var orderRaw = ProviderID.all.joined(separator: ",")
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                ForEach(Array(order.enumerated()), id: \.element) { index, id in
                    HStack(spacing: 8) {
                        Toggle(ProviderID.name(id), isOn: binding(for: id))
                        Spacer(minLength: 8)
                        Button {
                            orderRaw = ProviderList.moved(order, from: index, by: -1).joined(separator: ",")
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Move \(ProviderID.name(id)) up")
                        Button {
                            orderRaw = ProviderList.moved(order, from: index, by: 1).joined(separator: ",")
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == order.count - 1)
                        .help("Move \(ProviderID.name(id)) down")
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("This order is the panel and the menu bar. You can also drag the names along the top of the panel.")
            }
            Section("Menu bar") {
                Toggle("Show usage in the menu bar", isOn: $showMenuBarText)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: launchBinding)
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Quit Agent Usage") {
                NSApp.terminate(nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.top, 8)
        .preferredColorScheme(.dark)
    }

    private var order: [String] {
        ProviderList.normalizedOrder(orderRaw)
    }

    private var enabled: [String] {
        ProviderList.enabled(order: order, enabledRaw: enabledRaw)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(id) },
            set: { isOn in
                var ids = enabled
                if isOn {
                    if !ids.contains(id) { ids.append(id) }
                } else {
                    ids.removeAll { $0 == id }
                }
                let allowed = Set(ids)
                enabledRaw = order.filter { allowed.contains($0) }.joined(separator: ",")
                store.refresh(force: true)
            }
        )
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
            }
        )
    }
}
