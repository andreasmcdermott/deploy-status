import DeployCore
import SwiftUI

struct WorkflowFilterEditor: View {
    let watch: Watch
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var field: RunField?
    @State private var value: String
    @State private var runs: [Attempt] = []
    @State private var problem: String?
    @State private var loading = true

    init(watch: Watch) {
        self.watch = watch
        _field = State(initialValue: watch.runFilter?.field)
        _value = State(initialValue: watch.runFilter?.value ?? "")
    }

    private var filter: WorkflowFilter? { field.map { WorkflowFilter(field: $0, value: value) } }
    private var suggestions: [String] {
        guard let field, field != .title else { return [] }
        return Set(runs.compactMap { $0.parameters?[field.rawValue] }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filter workflow runs").font(.title2.bold())
            Text(watch.service).foregroundStyle(.secondary)
            Picker("Match", selection: $field) {
                Text("All runs").tag(nil as RunField?)
                ForEach(RunField.available(repository: watch.repository, path: watch.environment), id: \.self) { item in
                    Text(item == .title ? item.rawValue : item.rawValue + " equals").tag(Optional(item))
                }
            }
            .onChange(of: field) { _, _ in value = "" }
            if let field {
                HStack {
                    TextField(field == .environment ? "e.g. production" : "Value", text: $value)
                    if !suggestions.isEmpty {
                        Menu("Recent values") {
                            ForEach(suggestions, id: \.self) { item in Button(item) { value = item } }
                        }.fixedSize()
                    }
                }
                Text(field == .title ? "Matches text anywhere in the published run title, ignoring case." :
                     "Matches the exact value published in the deploy run title.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Checking recent runs…").controlSize(.small) }
            else if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            else if filter?.value.isEmpty != true {
                if let match = runs.first(where: { filter?.matches($0) != false }) {
                    Text(match.runTitle ?? "Latest matching run").lineLimit(2)
                    Text("\(match.phase.label) · \((match.current?.date ?? match.created).formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No matches in the \(runs.count) recent runs checked.").foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.setFilter(filter, for: watch.id); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(filter?.value.isEmpty == true)
            }
        }.padding(24).frame(width: 460)
        .task {
            defer { loading = false }
            guard let id = watch.workflowID else { return }
            do { runs = try await store.api.workflowRuns(repo: watch.repository, id: id, token: store.token()) }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
}
