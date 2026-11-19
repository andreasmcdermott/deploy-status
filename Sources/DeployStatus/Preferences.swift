import AppKit
import DeployCore
import SwiftUI

struct Preferences: View {
    @EnvironmentObject var store: Store
    @State private var tab = "Services"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(["Services", "Account"], id: \.self) { name in
                    Button { tab = name } label: {
                        Text(name)
                            .font(.body.weight(tab == name ? .semibold : .regular))
                            .foregroundStyle(tab == name ? Color.primary : Color.secondary)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if tab == name { Rectangle().frame(height: 2) }
                            }
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(tab == name ? .isSelected : [])
                }
                Spacer()
            }.padding(.horizontal, 24)
            Divider()
            if tab == "Account" { Account() } else { Services { tab = "Account" } }
            if let message = store.message {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.message = nil }.buttonStyle(.borderless)
                }.padding(.horizontal, 24).padding(.vertical, 10)
            }
        }
        .frame(width: 520, height: 356)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { tab = store.credential == nil || store.reconnect ? "Account" : "Services" }
        .onChange(of: store.credential?.login) { _, login in tab = login == nil ? "Account" : "Services" }
    }
}

private struct Account: View {
    @EnvironmentObject var store: Store
    @State private var method = SignInMethod.cli
    @State private var personalToken = ""

    private var connected: Bool { store.credential != nil && !store.reconnect }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if connected, let credential = store.credential {
                        Label(credential.login, systemImage: "person.crop.circle").font(.title2.weight(.semibold))
                        Text("Connected with \(credential.signInMethod.rawValue)").foregroundStyle(.secondary)
                    } else {
                        Text(store.reconnect ? "Reconnect GitHub" : "Connect GitHub").font(.title2.weight(.semibold))
                        Picker("Sign-in method", selection: $method) {
                            ForEach(SignInMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).disabled(store.signingIn)
                        switch method {
                        case .cli:
                            Text("Use the GitHub CLI account signed in on this Mac.").foregroundStyle(.secondary)
                        case .personal:
                            SecureField("Personal access token", text: $personalToken)
                            Text("Choose your work organization and grant read-only Actions access for workflows or Deployments access for rollouts. Add Environments access to browse rollout targets.")
                                .foregroundStyle(.secondary)
                            Link("Create a fine-grained token ↗", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        case .app:
                            TextField("GitHub App client ID", text: $store.clientID).disabled(store.signingIn)
                            if let code = store.code {
                                Text("Enter this code on GitHub to finish signing in.").foregroundStyle(.secondary)
                                Text(code.userCode).font(.title3.monospaced().weight(.medium)).textSelection(.enabled)
                            } else {
                                Text("Enable device flow and grant read-only Actions access for workflows or Deployments and Environments access for rollouts. Install it on the repositories you follow.")
                                    .foregroundStyle(.secondary)
                                Link("Register a GitHub App ↗", destination: URL(string: "https://github.com/settings/apps/new?name=Deploy+Status&url=https%3A%2F%2Fgithub.com&webhook_active=false&actions=read&deployments=read&environments=read&public=false")!)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                if connected {
                    Button("Sign out") { store.disconnect() }
                } else if store.signingIn {
                    ProgressView().controlSize(.small)
                    Button("Cancel sign-in") { store.cancelSignIn() }
                    if let code = store.code {
                        Button("Copy code and open GitHub") {
                            guard code.verificationUri.scheme == "https", code.verificationUri.host == "github.com" else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.userCode, forType: .string)
                            NSWorkspace.shared.open(code.verificationUri)
                        }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(connectTitle) {
                        store.connect(using: method, personalToken: personalToken)
                        personalToken = ""
                    }.buttonStyle(.borderedProminent)
                    .disabled((method == .personal && personalToken.trimmed.isEmpty) ||
                              (method == .app && store.clientID.trimmed.isEmpty))
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }
    }

    private var connectTitle: String {
        switch method {
        case .cli: return "Use GitHub CLI"
        case .personal: return "Connect with token"
        case .app: return "Sign in with GitHub"
        }
    }
}

private struct Services: View {
    @EnvironmentObject var store: Store
    let openAccount: () -> Void
    @State private var adding = false
    @State private var renaming: Watch?
    @State private var filtering: Watch?
    @State private var displayName = ""
    private var connected: Bool { store.credential != nil && !store.reconnect }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Followed services").font(.title2.weight(.semibold))
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 8)
            if store.state.watches.isEmpty {
                Text(connected ? "Choose a service to see its deployments in the menu bar." : "Connect GitHub to start following services.")
                    .foregroundStyle(.secondary).padding(.horizontal, 24)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.state.watches) { watch in
                            if watch.id != store.state.watches.first?.id { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(watch.service).fontWeight(.semibold)
                                        Text(watch.runFilter?.label ?? watch.stage).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text("\(watch.repository) / \(watch.environment)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Menu {
                                    Button("Rename…") {
                                        displayName = watch.service
                                        renaming = watch
                                    }
                                    Divider()
                                    if watch.workflowID != nil {
                                        Button("Filter runs…") { filtering = watch }
                                        Divider()
                                    }
                                    Section("Notify on") {
                                        ForEach(AlertKind.allCases, id: \.self) { kind in
                                            Toggle(kind.title, isOn: Binding(get: { watch.alerts.contains(kind) },
                                                set: { enabled in Task { await store.toggle(kind, for: watch.id, enabled: enabled) } }))
                                        }
                                    }
                                    Divider()
                                    Button("Unfollow service", role: .destructive) { store.unfollow(watch) }
                                } label: {
                                    Image(systemName: "ellipsis.circle").frame(width: 24, height: 24)
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                                .help("Notifications and options for \(watch.service)")
                                .accessibilityLabel("Options for \(watch.service), \(watch.stage)")
                            }.padding(.vertical, 10)
                        }
                    }.padding(.horizontal, 24)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(connected ? "Add service…" : "Connect GitHub…") {
                    if connected { adding = true } else { openAccount() }
                }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .sheet(isPresented: $adding) { AddService().environmentObject(store) }
        .sheet(item: $filtering) { watch in WorkflowFilterEditor(watch: watch).environmentObject(store) }
        .sheet(item: $renaming) { watch in
            VStack(alignment: .leading, spacing: 14) {
                Text(watch.workflowID == nil ? "Rename service" : "Rename workflow").font(.title2.bold())
                Text("\(watch.repository) / \(watch.environment)")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Display name") { TextField("Name", text: $displayName) }
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        store.rename(watch.id, to: displayName)
                        renaming = nil
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmed.isEmpty || displayName.trimmed == watch.service)
                }
            }.padding(24).frame(width: 420)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
