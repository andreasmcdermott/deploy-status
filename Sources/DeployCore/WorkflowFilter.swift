import Foundation

public enum RunField: Hashable, Codable {
    case title, input(String)

    public var label: String {
        switch self {
        case .title: return "Run title contains"
        case .input(let key):
            let words = key.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "Run title contains": self = .title
        case "Environment": self = .input("environment")
        case "Service": self = .input("service")
        case "Deployment group": self = .input("deployment_group")
        default: self = .input(raw.hasPrefix("input:") ? String(raw.dropFirst(6)) : raw)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .title: try value.encode("Run title contains")
        case .input(let key): try value.encode("input:" + key)
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
        field == .title ? "Title contains “\(value)”" : "\(field.label) = \(value)"
    }

    public func matches(_ attempt: Attempt) -> Bool {
        switch field {
        case .title: return attempt.runTitle?.localizedCaseInsensitiveContains(value) == true
        case .input(let key): return attempt.parameters?[key] == value
        }
    }
}
