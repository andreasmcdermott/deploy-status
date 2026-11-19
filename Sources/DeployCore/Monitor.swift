import Foundation

public struct History: Codable {
    var page = 2
    var next = Date.distantPast
    var exhausted = false
    public init() {}
}

public struct Reading: Codable {
    public var status = Snapshot()
    public var history = History()
    var unresolvedActiveRuns: Set<Int>?
    public var needsFrequentPolling: Bool { !status.active.isEmpty || unresolvedActiveRuns?.isEmpty == false }
    public init() {}
}

extension GitHub {
    // A shared repository page normally contains every new deployment since
    // the previous poll. Busy repositories fall back to the exact environment.
    public func poll(_ watch: Watch, shared: [Deployment], previous: Reading,
                     token: String, now: Date = Date()) async throws -> (Reading, [Event]) {
        if let id = watch.workflowID {
            return try await pollWorkflow(repo: watch.repository, id: id, filter: watch.runFilter, previous: previous, token: token, now: now)
        }
        let size = 4
        var reading = previous
        var rows = shared.filter { $0.environment == watch.environment }
        let last = previous.status.latest
        if let last, rows.contains(where: { $0.id == last.id }) {
            rows = Array(rows.prefix(while: { $0.id != last.id }))
        } else {
            rows = []
            var page = 1
            while true {
                let batch = try await deployments(repo: watch.repository, environment: watch.environment,
                                                  page: page, count: size, token: token)
                rows += batch
                guard let last, batch.count == size, let end = batch.last,
                      (end.createdAt, end.id) > (last.created, last.id) else { break }
                page += 1
            }
        }

        var attempts = Dictionary(uniqueKeysWithValues: previous.status.attempts.map { ($0.id, $0) })
        var reload = Set(rows.map(\.id))
        if let last { reload.insert(last.id) }
        reload.formUnion(previous.status.active.map(\.id))
        for old in previous.status.attempts where old.phase == .unknown { reload.insert(old.id) }
        let indexed = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in reload.sorted(by: >) {
            let old = attempts[id]
            guard let row = indexed[id] ?? old.map({ Deployment(id: $0.id, environment: watch.environment,
                                                                sha: $0.sha, createdAt: $0.created) }) else { continue }
            attempts[id] = try await attempt(repo: watch.repository, deployment: row, token: token)
        }

        let recent = attempts.values.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
        var history: [Attempt] = []
        let phases = Set(recent.flatMap(\.events).map(\.phase))
        let missingSuccess = reading.status.success == nil && !phases.contains(.succeeded)
        let missingFailure = reading.status.failure == nil && !phases.contains(.failed)
        if recent.count >= size, (missingSuccess || missingFailure), !reading.history.exhausted,
           now >= reading.history.next {
            let older = try await deployments(repo: watch.repository, environment: watch.environment,
                                              page: reading.history.page, count: size, token: token)
            for row in older where attempts[row.id] == nil {
                history.append(try await attempt(repo: watch.repository, deployment: row, token: token))
            }
            reading.history.page += 1
            reading.history.exhausted = older.count < size
            reading.history.next = now.addingTimeInterval(300)
        }

        let events = reading.status.update(recent: recent, history: history, at: now)
        let keep = Set(recent.prefix(size).map(\.id))
        reading.status.attempts = recent.filter { keep.contains($0.id) || $0.phase.active }
        return (reading, events)
    }
}
