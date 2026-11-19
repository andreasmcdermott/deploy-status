import Foundation
import Yams

public struct WorkflowInput: Identifiable, Equatable {
    public let id: String
    public let type: String
    public let options: [String]
    let required: Bool
}

struct WorkflowScript {
    let job: String
    let stepName: String?
    let lines: [String]
}

final class WorkflowDefinition {
    let inputs: [WorkflowInput]
    let title: String?
    let guards: [InputGuard]
    let scripts: [WorkflowScript]

    init(yaml: String) throws {
        let root = try Yams.compose(yaml: yaml)
        // Under YAML 1.1 the plain key "on" can carry a boolean tag.
        // GitHub accepts both quoted and unquoted spelling.
        let triggers = root?.mapping?.first { $0.key.string == "on" }?.value
        let declared = triggers?["workflow_dispatch"]?["inputs"]?.mapping
        inputs = declared?.compactMap { key, spec in
            guard let id = key.string else { return nil }
            let type = spec["type"]?.string ?? "string"
            let options = type == "boolean" ? ["true", "false"] : (spec["options"]?.sequence?.compactMap(\.string) ?? [])
            return WorkflowInput(id: id, type: type, options: options, required: spec["required"]?.string == "true")
        } ?? []
        title = root?["run-name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        var scripts: [WorkflowScript] = []
        let jobs = root?["jobs"]?.mapping.map(Array.init) ?? []
        for (id, job) in jobs {
            guard let jobName = job["name"]?.string ?? id.string else { continue }
            guard let steps = job["steps"]?.sequence else { continue }
            for step in steps {
                guard let script = step["run"]?.string, script.contains("inputs.") else { continue }
                scripts.append(WorkflowScript(job: jobName, stepName: step["name"]?.string,
                    lines: script.trimmingCharacters(in: .newlines).components(separatedBy: .newlines)))
            }
        }
        guards = InputGuard.extract(root: root, inputs: inputs)
        self.scripts = scripts
    }
}

extension GitHub {
    func definition(repo: String, path: String, ref: String? = nil, token: String) async throws -> WorkflowDefinition {
        let key = "\(repo)/\(path)@\(ref ?? "")" as NSString
        if ref != nil, let cached = definitions.object(forKey: key) { return cached }
        struct File: Decodable { let content: String; let encoding: String }
        let file: File = try await get("repos/\(repo)/contents/\(path)", token: token, query: ref.map { ["ref": $0] } ?? [:])
        guard file.encoding == "base64", let bytes = Data(base64Encoded: file.content, options: .ignoreUnknownCharacters),
              let yaml = String(data: bytes, encoding: .utf8) else {
            throw ServiceError.message("GitHub could not return the workflow YAML.")
        }
        let result = try WorkflowDefinition(yaml: yaml)
        if ref != nil { definitions.setObject(result, forKey: key) }
        return result
    }

    public func workflowInputs(repo: String, path: String, token: String) async throws -> [WorkflowInput] {
        try await definition(repo: repo, path: path, token: token).inputs
    }
}
