import Foundation

public struct Workflow: Decodable, Identifiable, Hashable {
    public let id: Int
    public let name, path, state: String
}

struct WorkflowRun: Decodable {
    let id, runAttempt: Int
    let headSha, status: String
    let displayTitle, headBranch, path, event: String?
    let conclusion: String?
    let createdAt, updatedAt: Date
    let runStartedAt: Date?
    let htmlUrl: URL

    var phase: Phase {
        switch status {
        case "in_progress": return .running
        case "queued", "requested", "pending": return .queued
        case "waiting": return .waiting
        case "completed":
            switch conclusion {
            case "success": return .succeeded
            case "failure", "timed_out", "startup_failure", "action_required", "stale": return .failed
            case "cancelled": return .cancelled
            case "skipped": return .skipped
            case "neutral": return .neutral
            default: return .unknown
            }
        default: return .unknown
        }
    }

    var transitionOrder: Int {
        switch phase {
        case .queued: return 1
        case .waiting: return 2
        case .running: return 3
        default: return 4
        }
    }
}

extension GitHub {
    public func workflows(repo: String, token: String) async throws -> [Workflow] {
        struct Page: Decodable { let workflows: [Workflow] }
        var results: [Int: Workflow] = [:]
        var page = 1
        while true {
            let batch: Page = try await get("repos/\(repo)/actions/workflows", token: token, query: paging(page))
            for workflow in batch.workflows { results[workflow.id] = workflow }
            if batch.workflows.count < 100 { break }
            page += 1
        }
        return results.values.sorted { ($0.name.lowercased(), $0.path, $0.id) < ($1.name.lowercased(), $1.path, $1.id) }
    }

    public func environments(repo: String, token: String) async throws -> [String] {
        struct Environment: Decodable { let name: String }
        struct Page: Decodable { let environments: [Environment] }
        var results = Set<String>()
        var page = 1
        while true {
            let batch: Page = try await get("repos/\(repo)/environments", token: token, query: paging(page))
            results.formUnion(batch.environments.map(\.name))
            if batch.environments.count < 100 { break }
            page += 1
        }
        return results.sorted()
    }

    public func workflowRuns(repo: String, id: Int, token: String, page: Int = 1, count: Int = 30) async throws -> [Attempt] {
        struct Page: Decodable { let workflowRuns: [WorkflowRun] }
        let batch: Page = try await get("repos/\(repo)/actions/workflows/\(id)/runs", token: token,
                                        query: ["page": String(page), "per_page": String(count)])
        return batch.workflowRuns.map { Attempt(run: $0, repository: repo) }
    }

    func pollWorkflow(repo: String, id: Int, filter: WorkflowFilter?, previous: Reading, token: String, now: Date) async throws -> (Reading, [Event]) {
        var reading = previous
        // Keep previously matched runs when a full page of newer runs misses the filter.
        var recent: [Int: Attempt] = [:]
        if filter != nil {
            for attempt in previous.status.attempts { recent[attempt.id] = attempt }
        }
        var refreshed = Set<Int>()
        var page = 1
        let count = filter == nil ? 30 : 100
        while true {
            let batch = try await workflowRuns(repo: repo, id: id, token: token, page: page, count: count)
            for attempt in batch {
                refreshed.insert(attempt.id)
                if filter?.matches(attempt) != false { recent[attempt.id] = attempt }
                else { recent.removeValue(forKey: attempt.id) }
            }
            if batch.count < count { reading.history.exhausted = true; break }
            guard let checked = previous.status.checked, batch.allSatisfy({ $0.created >= checked }) else { break }
            page += 1
        }
        // Rare parameter values can first occur well outside the latest page.
        // Backfill one extra page per poll until we know the latest matching
        // success and failure, or have reached the beginning of the workflow.
        if let filter, !reading.history.exhausted {
            let phases = recent.values.map(\.phase)
            if (reading.status.success == nil && !phases.contains(.succeeded)) ||
                (reading.status.failure == nil && !phases.contains(.failed)) {
                reading.history.page = max(reading.history.page, page + 1)
                let older = try await workflowRuns(repo: repo, id: id, token: token, page: reading.history.page, count: count)
                for attempt in older where filter.matches(attempt) { recent[attempt.id] = attempt }
                reading.history.page += 1
                reading.history.exhausted = older.count < count
            }
        }
        for old in previous.status.active where !refreshed.contains(old.id) {
            let run: WorkflowRun = try await get("repos/\(repo)/actions/runs/\(old.id)", token: token)
            let attempt = Attempt(run: run, repository: repo)
            if filter?.matches(attempt) != false { recent[old.id] = attempt }
            else { recent.removeValue(forKey: old.id) }
        }
        let events = reading.status.update(recent: Array(recent.values), history: [], at: now)
        if filter != nil {
            let keep = Set(reading.status.attempts.prefix(30).map(\.id))
            reading.status.attempts.removeAll { !keep.contains($0.id) && !$0.phase.active }
        }
        return (reading, events)
    }
}
