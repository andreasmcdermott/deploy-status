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

    public func workflowRuns(repo: String, id: Int, token: String, page: Int = 1, count: Int = 30, field: RunField? = nil) async throws -> [Attempt] {
        struct Page: Decodable { let workflowRuns: [WorkflowRun] }
        var query = ["page": String(page), "per_page": String(count)]
        if case .input = field { query["event"] = "workflow_dispatch" }
        let batch: Page = try await get("repos/\(repo)/actions/workflows/\(id)/runs", token: token, query: query)
        var attempts: [Attempt] = []
        for run in batch.workflowRuns {
            try Task.checkCancellation()
            if field != nil || attempts.isEmpty {
                attempts.append(try await resolvedAttempt(run, repo: repo, token: token, field: field, bestEffort: field == nil))
            } else { attempts.append(Attempt(run: run)) }
        }
        return attempts
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
        let count = filter == nil ? 30 : (filter?.field == .title ? 100 : 8)
        var unresolved = previous.unresolvedActiveRuns ?? []
        func record(_ attempt: Attempt) {
            refreshed.insert(attempt.id)
            if case let .input(key) = filter?.field, attempt.phase.active && attempt.parameters?[key] == nil {
                unresolved.insert(attempt.id)
            } else {
                unresolved.remove(attempt.id)
            }
            if filter?.matches(attempt) != false { recent[attempt.id] = attempt }
            else { recent.removeValue(forKey: attempt.id) }
        }
        while true {
            let batch = try await workflowRuns(repo: repo, id: id, token: token, page: page, count: count, field: filter?.field)
            for attempt in batch { record(attempt) }
            if batch.count < count { reading.history.exhausted = true; break }
            guard let checked = previous.status.checked, batch.allSatisfy({ $0.created >= checked }) else { break }
            page += 1
        }
        // Rare parameter values can first occur well outside the latest page.
        // Backfill one extra page per poll until we know the latest matching
        // success and failure, or have reached the beginning of the workflow.
        if filter != nil, !reading.history.exhausted {
            let phases = recent.values.map(\.phase)
            if (reading.status.success == nil && !phases.contains(.succeeded)) ||
                (reading.status.failure == nil && !phases.contains(.failed)) {
                reading.history.page = max(reading.history.page, page + 1)
                let older = try await workflowRuns(repo: repo, id: id, token: token, page: reading.history.page, count: count, field: filter?.field)
                for attempt in older where !refreshed.contains(attempt.id) { record(attempt) }
                reading.history.page += 1
                reading.history.exhausted = older.count < count
            }
        }
        let outstanding = Set(previous.status.active.map(\.id)).union(unresolved).subtracting(refreshed)
        for runID in outstanding {
            let run: WorkflowRun = try await get("repos/\(repo)/actions/runs/\(runID)", token: token)
            record(try await resolvedAttempt(run, repo: repo, token: token, field: filter?.field, bestEffort: filter == nil))
        }
        reading.unresolvedActiveRuns = unresolved.isEmpty ? nil : unresolved
        let events = reading.status.update(recent: Array(recent.values), history: [], at: now)
        if filter != nil {
            let keep = Set(reading.status.attempts.prefix(30).map(\.id))
            reading.status.attempts.removeAll { !keep.contains($0.id) && !$0.phase.active }
        }
        return (reading, events)
    }
}
