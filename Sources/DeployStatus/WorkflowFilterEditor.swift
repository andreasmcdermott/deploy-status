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
    @State private var readingInputs = true
    @State private var inputs: [WorkflowInput] = []
    @State private var schemaProblem: String?

    init(watch: Watch) {
        self.watch = watch
        _field = State(initialValue: watch.runFilter?.field)
        _value = State(initialValue: watch.runFilter?.value ?? "")
    }

    private var filter: WorkflowFilter? { field.map { WorkflowFilter(field: $0, value: value) } }
    private var selectedInput: WorkflowInput? {
        inputs.first { RunField.input($0.id) == field }
    }
    private var fields: [RunField] {
        var available = inputs.map { RunField.input($0.id) }
        if let saved = watch.runFilter?.field, saved != .title, !available.contains(saved) { available.append(saved) }
        return available + [.title]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filter workflow runs").font(.title2.bold())
            Text(watch.service).foregroundStyle(.secondary)
            Picker("Match", selection: $field) {
                Text("All runs").tag(nil as RunField?)
                ForEach(fields, id: \.self) { item in
                    Text(item == .title ? item.label : item.label + " equals").tag(Optional(item))
                }
            }
            .onChange(of: field) { _, _ in value = "" }
            if let field {
                if let input = selectedInput, !input.options.isEmpty {
                    Picker(field.label, selection: $value) {
                        Text("Choose a value…").tag("")
                        ForEach(input.options, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField("Value", text: $value)
                }
                Text(field == .title ? "Matches text anywhere in the run title, ignoring case." :
                     "Matches runs with a confirmed value for this input.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if readingInputs { ProgressView("Reading workflow inputs…").controlSize(.small) }
            else if let schemaProblem { Text(schemaProblem).font(.callout).foregroundStyle(.secondary) }
            else if inputs.isEmpty { Text("This workflow declares no manual inputs.").foregroundStyle(.secondary) }
            if loading { ProgressView("Checking recent runs…").controlSize(.small) }
            else if let problem { Text(problem).font(.callout).foregroundStyle(.secondary) }
            else if filter?.value.isEmpty != true {
                if let match = runs.first(where: { filter?.matches($0) != false }) {
                    Text(match.runTitle ?? "Latest matching run").lineLimit(2)
                    Text("\(match.phase.label) · \((match.current?.date ?? match.created).formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                } else if case .input(let key) = field, !runs.isEmpty,
                          runs.allSatisfy({ $0.parameters?[key] == nil }) {
                    Text("GitHub hasn’t exposed a value for this input in the recent runs checked.").foregroundStyle(.secondary)
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
            defer { readingInputs = false }
            do { inputs = try await store.api.workflowInputs(repo: watch.repository, path: watch.environment, token: store.token()) }
            catch {
                if !Task.isCancelled {
                    schemaProblem = "Could not read workflow inputs. Check the login’s read access to repository contents. " + error.localizedDescription
                }
            }
        }
        .task(id: field) {
            loading = true
            runs = []
            problem = nil
            defer { if !Task.isCancelled { loading = false } }
            guard let id = watch.workflowID else { return }
            do {
                let result = try await store.api.workflowRuns(repo: watch.repository, id: id, token: store.token(), count: 8, field: field)
                try Task.checkCancellation()
                runs = result
            } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
}
