import Foundation

private struct Job: Decodable {
    struct Step: Decodable {
        let name, status: String
        let conclusion: String?
        var executed: Bool { status == "in_progress" || conclusion == "success" || conclusion == "failure" }
    }
    let id: Int
    let name, status: String
    let steps: [Step]?
    func belongs(to job: String) -> Bool { name == job || name.hasPrefix(job + " (") }
}

final class InputEvidence {
    let values: [String: String]
    let expires: Date
    init(_ values: [String: String], lasting: Bool) {
        self.values = values
        expires = Date().addingTimeInterval(lasting ? 86400 : 15)
    }
}

extension GitHub {
    func resolvedAttempt(_ run: WorkflowRun, repo: String, token: String, field: RunField?, bestEffort: Bool) async throws -> Attempt {
        guard run.event == "workflow_dispatch", let path = run.path,
              field != .title else { return Attempt(run: run) }
        let wanted: String?
        if case let .input(key) = field { wanted = key } else { wanted = nil }
        let cacheKey = "\(repo)/\(run.id)/\(run.runAttempt)/\(run.status)/\(wanted.map { "input:" + $0 } ?? "summary")" as NSString
        if let cached = evidence.object(forKey: cacheKey), cached.expires > Date() {
            return Attempt(run: run, inputs: cached.values)
        }
        let definition: WorkflowDefinition
        do { definition = try await self.definition(repo: repo, path: path, ref: run.headSha, token: token) }
        catch ServiceError.http(let status, _) where status == 404 || (bestEffort && status == 403) {
            evidence.setObject(InputEvidence([:], lasting: false), forKey: cacheKey)
            return Attempt(run: run)
        }
        let context = ["github.event_name": run.event, "github.ref_name": run.headBranch].compactMapValues { $0 }
        var values: [String: String] = [:]
        if let template = definition.title, let title = run.displayTitle {
            let pattern = RunTemplate(template)
            values = pattern.match(title, inputs: definition.inputs, context: context) ?? [:]
            values.merge(pattern.finiteValues(for: title, inputs: definition.inputs, context: context)) { old, _ in old }
        }
        // Inspect job output only for the input the user actually asked to filter on.
        if wanted.map({ key in values[key] == nil && definition.inputs.contains { $0.id == key } }) ?? true {
            let guards = definition.guards.filter { (wanted == nil || $0.input == wanted) && values[$0.input] == nil }
            let scripts = wanted.map { key in definition.scripts.filter { script in script.lines.contains { $0.contains("inputs." + key) } } } ?? []
            if !guards.isEmpty || !scripts.isEmpty {
                let jobs = try await attemptJobs(run, repo: repo, token: token)
                var byInput: [String: Set<String>] = [:]
                for rule in guards where jobs.contains(where: { job in
                    job.belongs(to: rule.job) && job.steps?.contains(where: { $0.name == rule.step && $0.executed }) == true
                }) { byInput[rule.input, default: []].insert(rule.value) }
                if let wanted, byInput[wanted] == nil {
                    for job in jobs where job.status == "completed" {
                        let applicable = scripts.filter { script in job.belongs(to: script.job) &&
                            (script.stepName == nil || job.steps?.contains(where: { $0.executed && $0.name == script.stepName }) == true) }
                        guard !applicable.isEmpty else { continue }
                        let blocks = try await loggedScripts(repo: repo, jobID: job.id, token: token)
                        for script in applicable {
                            for block in blocks where block.count == script.lines.count {
                                var result = Set<String>()
                                var matches = true
                                for (source, rendered) in zip(script.lines, block) {
                                    guard let fields = RunTemplate(source).match(rendered, inputs: definition.inputs, context: context) else {
                                        matches = false; break
                                    }
                                    if let value = fields[wanted] { result.insert(value) }
                                }
                                if matches { byInput[wanted, default: []].formUnion(result) }
                            }
                        }
                    }
                }
                for (key, confirmed) in byInput where confirmed.count == 1 { values[key] = confirmed.first }
            }
        }
        if run.status == "completed" || wanted.flatMap({ values[$0] }) != nil {
            evidence.setObject(InputEvidence(values, lasting: !values.isEmpty), forKey: cacheKey)
        }
        return Attempt(run: run, inputs: values)
    }

    private func attemptJobs(_ run: WorkflowRun, repo: String, token: String) async throws -> [Job] {
        struct Page: Decodable { let jobs: [Job] }
        var jobs: [Job] = []
        var page = 1
        while true {
            let batch: Page = try await get("repos/\(repo)/actions/runs/\(run.id)/attempts/\(run.runAttempt)/jobs",
                                            token: token, query: paging(page))
            jobs += batch.jobs
            if batch.jobs.count < 100 { return jobs }
            page += 1
        }
    }

    private func loggedScripts(repo: String, jobID: Int, token: String) async throws -> [[String]] {
        let request = try apiRequest("repos/\(repo)/actions/jobs/\(jobID)/logs", token: token)
        let (stream, response) = try await session.bytes(for: request, delegate: LogRedirect())
        defer { stream.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if [404, 410].contains(http.statusCode) { return [] }
        guard http.statusCode == 200 else { try checkResponse(http, data: Data()); return [] }
        var blocks: [[String]] = []
        var block: [String]?
        var bytes = 0
        // Only inspect runner-printed script headers. Never persist or emit raw logs.
        for try await line in stream.lines {
            bytes += line.utf8.count + 1
            if bytes > 2_000_000 { break }
            guard let space = line.firstIndex(of: " ") else { continue }
            let body = line[line.index(after: space)...]
            if body.hasPrefix("##[group]Run ") { block = []; continue }
            guard block != nil else { continue }
            if body.hasPrefix("shell: ") {
                if let block { blocks.append(block) }
                block = nil
            } else if body.hasPrefix("\u{1B}[36;1m"), body.hasSuffix("\u{1B}[0m") {
                block?.append(String(body.dropFirst(7).dropLast(4)))
            } else { block = nil }
        }
        return blocks
    }
}

// GitHub redirects log downloads to short-lived signed HTTPS URLs.
private final class LogRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(redirected)
    }
}
