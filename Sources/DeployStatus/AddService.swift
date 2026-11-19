import DeployCore
import SwiftUI

struct AddService: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [String] = []
    @State private var repo = ""
    @State private var problem: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add service").font(.title2.bold())
            if !repo.isEmpty {
                Picker("Repository", selection: Binding(get: { repo }, set: { selection in
                    repo = selection
                    store.rememberRepository(selection)
                })) {
                    ForEach(repositories, id: \.self) { Text($0).tag($0) }
                }
                SourcePicker(repo: repo).id(repo)
            } else {
                if loading { ProgressView("Loading repositories…") }
                else { Text(problem ?? "No repositories are visible to this login.") }
                HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(24).frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            do {
                guard let method = store.credential?.signInMethod else { throw ServiceError.unauthorized }
                repositories = try await store.api.repositories(token: store.token(), method: method)
                repo = store.state.preferredRepository(in: repositories)
            } catch { store.record(error); problem = error.localizedDescription }
            loading = false
        }
    }
}

private enum Source: String, CaseIterable { case workflow = "Workflow", environment = "Environment" }

private struct SourcePicker: View {
    let repo: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.workflow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Track", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Catalog(repo: repo, source: source).id(source)
        }
    }
}

private struct Catalog: View {
    let repo: String
    let source: Source
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var workflows: [Workflow] = []
    @State private var environments: [String] = []
    @State private var selectedIDs: Set<Int> = []
    @State private var displayNames: [Int: String] = [:]
    private var selectedWorkflows: [Workflow] { workflows.filter { selectedIDs.contains($0.id) } }
    private var workflow: Workflow? { selectedIDs.count == 1 ? selectedWorkflows.first : nil }
    private var followedIDs: Set<Int> {
        Set(store.state.watches.filter { $0.repository.caseInsensitiveCompare(repo) == .orderedSame }.compactMap(\.workflowID))
    }
    @State private var environment = ""
    @State private var service = ""
    @State private var stage = ""
    @State private var search = ""
    @State private var browsing = false
    @State private var loading = true
    @State private var discoveryProblem: String?
    @State private var preview: Attempt?
    @State private var previewMessage: String?
    @State private var verified: String?
    @State private var reload = 0

    private var key: String { workflow.map { String($0.id) } ?? environment }
    private var duplicate: Bool {
        store.state.watches.contains {
            $0.repository == repo && $0.workflowID == workflow?.id &&
            (workflow != nil || $0.environment == environment)
        }
    }
    private func matches(_ text: String) -> Bool { search.isEmpty || text.localizedCaseInsensitiveContains(search) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if source == .workflow {
                workflowList
            } else {
                HStack {
                    TextField("Exact GitHub environment", text: $environment)
                    Button("Browse…") {
                        search = ""
                        browsing = true
                    }.popover(isPresented: $browsing) { environmentBrowser }
                    if loading { ProgressView().controlSize(.small) }
                }
            }
            if let discoveryProblem {
                Text(discoveryProblem).font(.callout).foregroundStyle(.secondary)
                Button("Retry list") { reload += 1 }
            }
            if !key.isEmpty {
                if let workflow {
                    Text(workflow.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Display name") {
                    if let workflow {
                        TextField("Name", text: Binding(get: { displayNames[workflow.id] ?? workflow.name },
                                                        set: { displayNames[workflow.id] = $0 }))
                    } else { TextField("Name", text: $service) }
                }
                if source == .environment {
                    LabeledContent("Display environment") { TextField("e.g. production", text: $stage) }
                }
                if let preview {
                    Label("\(preview.phase.label) · \((preview.current?.date ?? preview.created).formatted()) · \(preview.sha.prefix(8))",
                          systemImage: preview.phase.symbol).foregroundStyle(preview.phase.tint)
                } else if let previewMessage {
                    Text(previewMessage).font(.callout).foregroundStyle(.secondary)
                } else { ProgressView("Checking latest status…").controlSize(.small) }
                if duplicate { Text("Already followed").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if source == .workflow {
                    Button(selectedIDs.count > 1 ? "Follow \(selectedIDs.count) workflows" : "Follow workflow") {
                        store.follow(selectedWorkflows.map { item in
                            Watch(repository: repo, environment: item.path, service: displayName(for: item),
                                  stage: "Workflow", workflowID: item.id)
                        })
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty ||
                              (workflow != nil && verified != key))
                } else {
                    Button("Follow service") {
                        store.follow([Watch(repository: repo, environment: environment,
                                            service: service.trimmingCharacters(in: .whitespacesAndNewlines),
                                            stage: stage.trimmingCharacters(in: .whitespacesAndNewlines))])
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || verified != key || duplicate ||
                              service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              (preview == nil && !environments.contains(environment)) ||
                              stage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .task(id: reload) {
            loading = true
            discoveryProblem = nil
            do {
                let access = try await store.token()
                switch source {
                case .workflow: workflows = try await store.api.workflows(repo: repo, token: access)
                case .environment: environments = try await store.api.environments(repo: repo, token: access)
                }
            } catch {
                if !Task.isCancelled {
                    store.record(error)
                    discoveryProblem = error.localizedDescription + (source == .workflow
                        ? " Workflow discovery requires read access to Actions."
                        : " Enter an exact environment name if you have Deployments access only.")
                }
            }
            loading = false
        }
        .task(id: key) {
            verified = nil
            preview = nil
            previewMessage = nil
            guard !key.isEmpty else { return }
            if source == .environment {
                let parts = environment.split(separator: "-")
                stage = parts.last.map(String.init) ?? ""
                var names = parts.dropLast()
                if repo == "useshortcut/monorepo", names.first == "backend" { names = names.dropFirst() }
                service = names.isEmpty ? (repo.split(separator: "/").last.map(String.init) ?? "") : names.joined(separator: "-")
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let access = try await store.token()
                let latest: Attempt?
                if let workflow {
                    latest = try await store.api.workflowRuns(repo: repo, id: workflow.id, token: access, count: 1).first
                } else if let deployment = try await store.api.deployments(repo: repo, environment: environment,
                                                                            count: 1, token: access).first {
                    latest = try await store.api.attempt(repo: repo, deployment: deployment, token: access)
                } else { latest = nil }
                try Task.checkCancellation()
                preview = latest
                if latest == nil {
                    previewMessage = workflow != nil ? "No workflow runs yet." : "No deployments for this environment yet."
                }
                verified = key
            } catch {
                if !Task.isCancelled { store.record(error); previewMessage = error.localizedDescription }
            }
        }
    }

    private func displayName(for item: Workflow) -> String {
        let name = displayNames[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? item.name : name
    }

    private var workflowList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search workflows by name or file", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let results = workflows.filter { matches($0.name) || matches($0.path) }
                    let followed = followedIDs
                    ForEach(results) { item in
                        let existing = followed.contains(item.id)
                        Toggle(isOn: Binding(get: { existing || selectedIDs.contains(item.id) }, set: { checked in
                            if checked { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                        })) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text(item.path + (item.state == "active" ? "" : " · " + item.state))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if existing { Text("Following").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .toggleStyle(.checkbox).disabled(existing).padding(.vertical, 4)
                    }
                    if results.isEmpty { emptyResults }
                }
            }.frame(height: 180)
        }
    }

    private var environmentBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search environments", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let results = environments.filter(matches)
                    ForEach(results, id: \.self) { name in
                        Button {
                            environment = name
                            browsing = false
                        } label: {
                            Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if results.isEmpty { emptyResults }
                }
            }
        }.padding(12).frame(width: 400, height: 320)
    }

    private var emptyResults: some View {
        Text(loading ? "Loading…" : (discoveryProblem == nil ? "No matches" : "List unavailable"))
            .foregroundStyle(.secondary)
    }
}
