import DeployCore
import SwiftUI

struct Dashboard: View {
    @EnvironmentObject var store: Store
    let openSettings: () -> Void
    @State private var expanded: UUID?

    private var connected: Bool { store.credential != nil && !store.reconnect }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox").imageScale(.large)
                Text("Deploy Status").font(.headline)
                Spacer()
                if connected && !store.state.watches.isEmpty {
                    if store.refreshing {
                        ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    } else {
                        Button { store.refresh() } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                        }.help("Refresh now").accessibilityLabel("Refresh now")
                    }
                }
                Menu {
                    Button("Manage services…", action: openSettings)
                    Divider()
                    Button("Quit Deploy Status") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More options")
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 12)
            Divider()

            if !connected || store.state.watches.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(connected ? "Choose a service to follow." :
                            (store.reconnect ? "Reconnect to resume updates." : "Connect GitHub to see your deployments."))
                        .foregroundStyle(.secondary)
                    Button(connected ? "Manage services…" : "Connect GitHub…", action: openSettings)
                        .buttonStyle(.borderedProminent)
                }.padding(18)
            }

            if !store.state.watches.isEmpty {
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.state.watches) { watch in
                if watch.id != store.state.watches.first?.id { Divider() }
                WatchRow(watch: watch, status: store.state.readings[watch.id]?.status ?? Snapshot(),
                         error: store.errors[watch.id], expanded: expanded == watch.id) {
                    expanded = expanded == watch.id ? nil : watch.id
                }
            }
        }.padding(.horizontal, 18)
    }
}

struct WatchRow: View {
    let watch: Watch
    let status: Snapshot
    let error: String?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: (status.latest?.phase ?? .unknown).symbol)
                        .foregroundStyle((status.latest?.phase ?? .unknown).tint)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(watch.service).foregroundStyle(.primary).font(.body.weight(.semibold)).lineLimit(1)
                                .truncationMode(.middle).layoutPriority(1)
                            Spacer(minLength: 8)
                            Text(watch.runFilter?.label ?? status.latest?.parameters?["environment"] ?? status.latest?.parameters?["Environment"] ?? watch.stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let attempt = status.latest {
                            let time = attempt.current?.date ?? attempt.created
                            Text("\(attempt.phase.label) · \(time.formatted(date: .abbreviated, time: .shortened))")
                            if attempt.phase != .succeeded, let success = status.success {
                                Text("Last succeeded \(success.date.formatted(date: .abbreviated, time: .shortened))")
                            }
                            let others = status.active.filter { $0.id != attempt.id }
                            if !others.isEmpty { Text("\(others.count) earlier still active") }
                        } else {
                            Text(status.checked == nil ? "Waiting for first update" : (watch.workflowID == nil ? "No deployments yet" : (watch.runFilter == nil ? "No workflow runs yet" : "No matching runs found yet")))
                        }
                        if error != nil { Label("Update failed", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(watch.repository) / \(watch.environment)").textSelection(.enabled)
                    if let attempt = status.latest {
                        if let title = attempt.runTitle { Text(title).fontWeight(.medium).textSelection(.enabled) }
                        if let parameters = attempt.parameters {
                            ForEach(parameters.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(parameters[key] ?? "")")
                            }
                        }
                        Text("Commit \(attempt.sha.prefix(8))").monospacedDigit()
                        if let url = attempt.events.compactMap(\.url).first { Link(watch.workflowID == nil ? "View deployment ↗" : "View workflow run ↗", destination: url) }
                        else if let url = URL(string: "https://github.com/\(watch.repository)/deployments") {
                            Link("View repository deployments ↗", destination: url)
                        }
                    }
                    if let success = status.success { Text("Last succeeded \(success.date.formatted(date: .abbreviated, time: .standard))") }
                    if let failure = status.failure { Text("Last failed \(failure.date.formatted(date: .abbreviated, time: .standard))") }
                    if let checked = status.checked { Text("Last checked \(checked.formatted(date: .abbreviated, time: .standard))") }
                    if let error { Text(error).foregroundStyle(.orange) }
                }.font(.caption).padding(.leading, 26)
            }
        }.padding(.vertical, 12)
    }
}
