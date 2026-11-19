import Foundation

public enum Phase: String, Codable {
    case waiting, queued, deploying, running, succeeded, failed, cancelled, skipped, neutral, inactive, unknown

    init(github: String) {
        switch github {
        case "queued", "pending": self = .queued
        case "waiting": self = .waiting
        case "in_progress": self = .deploying
        case "success": self = .succeeded
        case "error", "failure": self = .failed
        case "inactive": self = .inactive
        default: self = .unknown
        }
    }
    public var active: Bool { [.queued, .waiting, .deploying, .running].contains(self) }
    public var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .queued: return "Queued"
        case .deploying: return "Deploying"
        case .running: return "Running"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .neutral: return "Neutral"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        case .inactive: return "Inactive"
        case .unknown: return "Awaiting status"
        }
    }
}

public struct Watch: Codable, Identifiable {
    public let id: UUID
    public let repository: String
    public let environment: String
    public let workflowID: Int?
    public var runFilter: WorkflowFilter?
    public var service: String
    public var stage: String
    public var alerts: Set<AlertKind> = []
    public init(repository: String, environment: String, service: String, stage: String, workflowID: Int? = nil) {
        id = UUID()
        self.workflowID = workflowID
        self.repository = repository
        self.environment = environment
        self.service = service
        self.stage = stage
    }
}

public enum AlertKind: String, Codable, CaseIterable {
    case started, succeeded, failed
    public var title: String { rawValue.capitalized }
}

public struct Deployment: Decodable, Identifiable {
    public let id: Int
    public let environment: String
    public let sha: String
    public let createdAt: Date
}

public struct GitStatus: Decodable {
    public let id: Int
    public let state: String
    public let createdAt: Date
    public let logUrl: String?
}

public struct Event: Codable, Identifiable {
    public let id: Int
    public let phase: Phase
    public let date: Date
    public let url: URL?
    public var alert: AlertKind? {
        switch phase {
        case .deploying, .running: return .started
        case .succeeded: return .succeeded
        case .failed: return .failed
        default: return nil
        }
    }
}

public struct Attempt: Codable, Identifiable {
    public let id: Int
    public let sha: String
    public let created: Date
    public let events: [Event]
    public var current: Event? { events.first }
    public var phase: Phase { current?.phase ?? .unknown }

    public private(set) var runTitle: String?
    public private(set) var parameters: [String: String]?

    init(run: WorkflowRun, inputs: [String: String] = [:]) {
        runTitle = run.displayTitle
        parameters = inputs.isEmpty ? nil : inputs
        id = run.id
        created = run.runStartedAt ?? run.createdAt
        sha = run.headSha
        let phase = run.phase
        let time = phase.active ? (phase == .running ? created : run.createdAt) : run.updatedAt
        // Run IDs persist through retries. Distinguish each attempt and transition
        // even when GitHub reports two transitions in the same second.
        let eventID = run.id * 1_000_000 + run.runAttempt * 100 + run.transitionOrder
        events = [Event(id: eventID, phase: phase, date: time, url: run.htmlUrl)]
    }

    public init(_ deployment: Deployment, statuses: [GitStatus]) {
        id = deployment.id
        sha = deployment.sha
        created = deployment.createdAt
        events = statuses.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }.map {
            let url = $0.logUrl.flatMap(URL.init(string:))
            return Event(id: $0.id, phase: Phase(github: $0.state), date: $0.createdAt,
                         url: url?.scheme?.lowercased() == "https" && url?.host != nil ? url : nil)
        }
    }
}

public struct Snapshot: Codable {
    public var attempts: [Attempt] = []
    public var success: Event?
    public var failure: Event?
    public var checked: Date?
    public var latest: Attempt? { attempts.first }
    public var active: [Attempt] { attempts.filter { $0.phase.active } }
    public init() {}

    // Keep terminal times even after the associated deployment leaves the page.
    public mutating func update(recent: [Attempt], history: [Attempt], at date: Date) -> [Event] {
        let previous = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
        let events = recent.flatMap(\.events)
        let known = events + history.flatMap(\.events)
        success = ([success].compactMap { $0 } + known.filter { $0.phase == .succeeded }).max { $0.date < $1.date }
        failure = ([failure].compactMap { $0 } + known.filter { $0.phase == .failed }).max { $0.date < $1.date }
        var newEvents: [Event] = []
        if let checked {
            for attempt in recent {
                let old = previous[attempt.id]
                var phase = old?.phase
                for event in attempt.events.reversed() {
                    if let prior = old?.current {
                        guard (event.date, event.id) > (prior.date, prior.id) else { continue }
                    } else if old == nil && event.date < checked.roundedDownToSecond {
                        continue
                    }
                    if event.phase != phase && event.alert != nil { newEvents.append(event) }
                    phase = event.phase
                }
            }
        }
        attempts = recent.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
        checked = date
        return newEvents.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
    }
}

private extension Date {
    var roundedDownToSecond: Date { Date(timeIntervalSince1970: floor(timeIntervalSince1970)) }
}
