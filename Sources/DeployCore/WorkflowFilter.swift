import Foundation

public enum RunField: String, Codable, CaseIterable {
    case environment = "Environment", service = "Service", deploymentGroup = "Deployment group"
    case title = "Run title contains"

    // These three run-name templates expose dispatch inputs in monorepo.
    // Other workflows can always be filtered using their published title.
    public static func available(repository: String, path: String) -> [RunField] {
        guard repository.lowercased() == "useshortcut/monorepo" else { return [.title] }
        switch path {
        case ".github/workflows/backend-deploy.yml", ".github/workflows/backend-deploy-non-jvm.yml":
            return [.environment, .service, .title]
        case ".github/workflows/backend-deploy-haproxy-lb.yml":
            return [.deploymentGroup, .title]
        default: return [.title]
        }
    }
}

public struct WorkflowFilter: Codable, Equatable {
    public let field: RunField
    public let value: String

    public init(field: RunField, value: String) {
        self.field = field
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var label: String {
        field == .title ? "Title contains “\(value)”" : "\(field.rawValue) = \(value)"
    }

    public func matches(_ attempt: Attempt) -> Bool {
        if field == .title { return attempt.runTitle?.localizedCaseInsensitiveContains(value) == true }
        return attempt.parameters?[field.rawValue] == value
    }
}

extension WorkflowRun {
    func parameters(repository: String) -> [String: String]? {
        guard event == "workflow_dispatch", let path, let title = displayTitle, title.hasPrefix("Deploy "),
              let ref = headBranch, !ref.isEmpty, title.hasSuffix(" @ " + ref) else { return nil }
        let fields = RunField.available(repository: repository, path: path)
        guard fields != [.title] else { return nil }
        let body = title.dropFirst("Deploy ".count).dropLast((" @ " + ref).count)
        let parts = body.components(separatedBy: " → ")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        if fields.contains(.deploymentGroup) {
            return parts[0] == "haproxy-lb" ? [RunField.deploymentGroup.rawValue: parts[1]] : nil
        }
        return [RunField.service.rawValue: parts[0], RunField.environment.rawValue: parts[1]]
    }
}
