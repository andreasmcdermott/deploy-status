import XCTest
@testable import DeployCore

private final class MockHTTP: URLProtocol {
    typealias Reply = (Int, [String: String], Any)
    static var handler: ((URLRequest) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, headers, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let data = try (body as? Data) ?? JSONSerialization.data(withJSONObject: body)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class GitHubTests: XCTestCase {
    private var api: GitHub!
    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockHTTP.self]
        api = GitHub(session: URLSession(configuration: config))
    }
    override func tearDown() { MockHTTP.handler = nil }

    func testKoreyEnvironmentChoicesAndAttemptSpecificJobEvidence() async throws {
        let repo = "useshortcut/monorepo"
        let path = ".github/workflows/korey-frontend-zero_services_deploy.yml"
        let yaml = """
        on:
          workflow_dispatch:
            inputs:
              environment: {type: choice, options: [staging, production]}
        jobs:
          deploy-services:
            steps:
              - name: Check Production Deployment
                if: inputs.environment == 'production'
          build-package:
            steps:
              - name: Read Zero Docker Tag
                if: inputs.environment == 'staging'
        """
        var watch = Watch(repository: repo, environment: path, service: "Korey", stage: "Workflow", workflowID: 7)
        watch.runFilter = WorkflowFilter(field: .input("environment"), value: "production")
        func run(_ id: Int, _ active: Bool = false, attempt: Int = 1) -> [String: Any] {
            ["id": id, "run_attempt": attempt, "head_sha": "abc", "status": active ? "in_progress" : "completed",
             "conclusion": active ? NSNull() as Any : "success", "created_at": "2026-11-18T10:00:00Z",
             "updated_at": "2026-11-18T10:10:00Z", "path": path, "event": "workflow_dispatch", "display_title": "korey-frontend/Zero - Deploy Services",
             "html_url": "https://github.com/useshortcut/monorepo/actions/runs/\(id)"]
        }
        func job(_ name: String, _ step: String, _ status: String, _ conclusion: String?) -> [String: Any] {
            ["id": 123, "status": "completed", "name": name + " (korey-replication-manager)",
             "steps": [["name": step, "status": status, "conclusion": conclusion as Any? ?? NSNull()]]]
        }

        var secondPoll = false
        var lookups: [String] = []
        MockHTTP.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.contains("/contents/") {
                return (200, [:], ["encoding": "base64", "content": Data(yaml.utf8).base64EncodedString()])
            }
            if url.path.hasSuffix("/workflows/7/runs") {
                return (200, [:], ["workflow_runs": secondPoll ? [run(1, attempt: 2), run(2)] : [run(1), run(2), run(3, true)]])
            }
            if url.path.hasSuffix("/actions/runs/3") { return (200, [:], run(3, true)) }
            lookups.append(url.path)
            if url.path.hasSuffix("/runs/1/attempts/1/jobs") || (secondPoll && url.path.hasSuffix("/runs/3/attempts/1/jobs")) {
                return (200, [:], ["jobs": [job("deploy-services", "Check Production Deployment", "in_progress", nil)]])
            }
            if url.path.hasSuffix("/runs/2/attempts/1/jobs") || url.path.hasSuffix("/runs/1/attempts/2/jobs") {
                return (200, [:], ["jobs": [job("build-package", "Read Zero Docker Tag", "completed", "success"),
                                             job("deploy-services", "Check Production Deployment", "completed", "skipped")]])
            }
            XCTAssertTrue(url.path.hasSuffix("/runs/3/attempts/1/jobs"))
            return (200, [:], ["jobs": [job("deploy-services", "Check Production Deployment", "pending", nil)]])
        }

        let (first, quiet) = try await api.poll(watch, shared: [], previous: Reading(), token: "test")
        XCTAssertEqual(first.status.attempts.map(\.id), [1])
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertTrue(first.needsFrequentPolling)
        secondPoll = true
        let (next, _) = try await api.poll(watch, shared: [], previous: first, token: "test")
        XCTAssertEqual(next.status.attempts.map(\.id), [3])
        XCTAssertEqual(next.status.latest?.parameters?["environment"], "production")
        XCTAssertEqual(lookups.filter { $0.hasSuffix("/runs/2/attempts/1/jobs") }.count, 1)
        XCTAssertEqual(lookups.filter { $0.hasSuffix("/runs/3/attempts/1/jobs") }.count, 2)
    }

    func testUnrelatedWorkflowTextInputUsesOnlyMatchingRunnerScript() async throws {
        let yaml = """
        on: {workflow_dispatch: {inputs: {customer: {type: string}}}}
        jobs:
          notify:
            steps:
              - name: Format message
                run: |
                  CLIENT="${{ inputs.customer }}"
                  echo "Preparing message"
        """
        let repo = "example/notifications"
        let path = ".github/workflows/message.yml"
        var requestPaths: [String] = []
        MockHTTP.handler = { request in
            let url = try XCTUnwrap(request.url)
            requestPaths.append(url.path)
            if url.path.hasSuffix("/contents/" + path) {
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "revision")
                return (200, [:], ["encoding": "base64", "content": Data(yaml.utf8).base64EncodedString()])
            }
            if url.path.hasSuffix("/jobs/17/logs") {
                let lines = ["##[group]Run unrelated", "\u{1B}[36;1mCLIENT=\"wrong\"\u{1B}[0m", "shell: bash",
                             "CLIENT=\"untrusted-output\"", "##[group]Run CLIENT=\"acme\"",
                             "\u{1B}[36;1mCLIENT=\"acme\"\u{1B}[0m", "\u{1B}[36;1mecho \"Preparing message\"\u{1B}[0m", "shell: bash"]
                return (200, [:], Data(lines.map { "2026-11-18T00:00:00Z " + $0 }.joined(separator: "\n").utf8))
            }
            if url.path.hasSuffix("/attempts/1/jobs") {
                return (200, [:], ["jobs": [["id": 17, "status": "completed", "name": "notify",
                                            "steps": [["name": "Format message", "status": "completed", "conclusion": "success"]]]]])
            }
            XCTAssertTrue(url.path.hasSuffix("/workflows/5/runs"))
            XCTAssertTrue(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(URLQueryItem(name: "event", value: "workflow_dispatch")) == true)
            return (200, [:], ["workflow_runs": [["run_attempt": 1, "id": 1, "event": "workflow_dispatch",
                "status": "completed", "conclusion": "success", "head_sha": "revision", "path": path,
                "created_at": "2026-11-18T10:00:00Z", "updated_at": "2026-11-18T10:01:00Z",
                "html_url": "https://github.com/example/notifications/actions/runs/1"]]])
        }
        let runs = try await api.workflowRuns(repo: repo, id: 5, token: "test", field: .input("customer"))
        XCTAssertEqual(runs.first?.parameters, ["customer": "acme"])
        XCTAssertTrue(requestPaths.contains { $0.hasSuffix("/jobs/17/logs") })
    }

    func testCatalogIncludesSecondPageAndDisabledWorkflowsWithDuplicateNames() async throws {
        MockHTTP.handler = { request in
            let url = try XCTUnwrap(request.url)
            let second = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .contains(URLQueryItem(name: "page", value: "2")) == true
            let ids = second ? Array(100...100) : Array(0..<100)
            if url.path.hasSuffix("/environments") {
                return (200, [:], ["environments": ids.map { ["name": "env-\($0)"] }])
            }
            XCTAssertTrue(url.path.hasSuffix("/actions/workflows"))
            return (200, [:], ["workflows": ids.map { id in
                ["id": id, "name": "Deploy", "path": "deploy-\(id).yml", "state": second ? "disabled_manually" : "active"] as [String: Any]
            }])
        }
        let workflows = try await api.workflows(repo: "org/repo", token: "test")
        XCTAssertEqual(workflows.count, 101)
        XCTAssertEqual(workflows.first { $0.id == 100 }?.state, "disabled_manually")
        let environments = try await api.environments(repo: "org/repo", token: "test")
        XCTAssertTrue(environments.contains("env-100"))
    }

    func testProductionFilterScopesHistoryAlertsAndBackfillsPastStaging() async throws {
        let repo = "useshortcut/monorepo"
        let path = ".github/workflows/backend-deploy.yml"
        let timestamp = "2026-11-18T10:00:00Z"
        let clock = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
        func run(_ id: Int, environment: String, branch: String, conclusion: String) -> [String: Any] {
            ["id": id, "run_attempt": 1, "head_sha": "abc", "status": "completed", "conclusion": conclusion,
             "created_at": timestamp, "updated_at": id == 201 ? "2026-11-18T11:00:00Z" : timestamp,
             "html_url": "https://github.com/useshortcut/monorepo/actions/runs/\(id)",
             "event": "workflow_dispatch", "path": path, "head_branch": branch,
             "display_title": "Deploy graphql → \(environment) @ \(branch)"]
        }
        var watch = Watch(repository: repo, environment: path, service: "Backend", stage: "Workflow", workflowID: 17)
        watch.runFilter = WorkflowFilter(field: .input("environment"), value: "production")
        var secondPoll = false
        MockHTTP.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path.contains("/contents/") {
                let yaml = """
                run-name: "Deploy ${{ inputs.service }} → ${{ inputs.environment }} @ ${{ github.ref_name }}"
                on:
                  workflow_dispatch:
                    inputs:
                      environment: {type: choice, required: true, options: [staging, production]}
                      service: {type: string}
                """
                return (200, [:], ["encoding": "base64", "content": Data(yaml.utf8).base64EncodedString()])
            }
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let runs: [[String: Any]]
            if secondPoll {
                runs = [run(202, environment: "staging", branch: "production", conclusion: "failure"),
                        run(201, environment: "production", branch: "main", conclusion: "failure")]
            } else if page == "1" {
                runs = (100..<108).map { run($0, environment: "staging", branch: "production", conclusion: "failure") }
            } else {
                runs = [run(1, environment: "production", branch: "main", conclusion: "success")]
            }
            return (200, [:], ["workflow_runs": runs])
        }
        let (initial, quiet) = try await api.poll(watch, shared: [], previous: Reading(), token: "test", now: clock)
        XCTAssertTrue(quiet.isEmpty)
        XCTAssertEqual(initial.status.latest?.id, 1)
        XCTAssertEqual(initial.status.latest?.parameters, ["environment": "production", "service": "graphql"])
        XCTAssertNil(initial.status.failure)
        secondPoll = true
        let (next, alerts) = try await api.poll(watch, shared: [], previous: initial, token: "test",
                                               now: clock.addingTimeInterval(3600))
        XCTAssertEqual(next.status.latest?.id, 201)
        XCTAssertEqual(alerts.map(\.alert), [.failed])
        XCTAssertEqual(next.status.success?.date, clock)
        XCTAssertFalse(next.status.attempts.contains { $0.id == 202 })
    }

    func testTitleFilterAndMissingInputs() async throws {
        MockHTTP.handler = { _ in
            let run: [String: Any] = ["id": 3, "run_attempt": 1, "head_sha": "abc", "status": "queued",
                "created_at": "2026-11-18T10:00:00Z", "updated_at": "2026-11-18T10:00:00Z",
                "html_url": "https://github.com/org/repo/actions/runs/3", "event": "push",
                "path": ".github/workflows/ci.yml", "display_title": "Deploy graphql → Production @ main"]
            return (200, [:], ["workflow_runs": [run]])
        }
        let runs = try await api.workflowRuns(repo: "org/repo", id: 17, token: "test")
        let run = try XCTUnwrap(runs.first)
        XCTAssertNil(run.parameters)
        XCTAssertTrue(WorkflowFilter(field: .title, value: "production").matches(run))
        XCTAssertFalse(WorkflowFilter(field: .input("environment"), value: "production").matches(run))
    }

    func testFollowingWorkflowBeforeFirstRunAndThroughCompletion() async throws {
        let watch = Watch(repository: "org/repo", environment: "build.yml", service: "Build", stage: "Workflow", workflowID: 17)
        var reading = Reading()
        for (index, phase) in ["empty", "in_progress", "completed", "completed"].enumerated() {
            MockHTTP.handler = { request in
                XCTAssertEqual(request.url?.path, "/repos/org/repo/actions/workflows/17/runs")
                var run: [String: Any] = ["id": 3, "run_attempt": 1, "head_sha": "abc", "status": phase,
                    "created_at": "2026-11-18T10:00:00Z", "run_started_at": "2026-11-18T10:00:00Z",
                    "updated_at": "2026-11-18T10:01:00Z", "html_url": "https://github.com/org/repo/actions/runs/3"]
                if phase == "completed" { run["conclusion"] = "success" }
                return (200, [:], ["workflow_runs": phase == "empty" ? [] : [run]])
            }
            let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-18T10:00:00Z"))
            let (updated, events) = try await api.poll(watch, shared: [], previous: reading, token: "test", now: now)
            reading = updated
            if index == 1 { XCTAssertEqual(events.map(\.alert), [.started]); XCTAssertEqual(reading.status.latest?.phase, .running) }
            else if index == 2 { XCTAssertEqual(events.map(\.alert), [.succeeded]) }
            else { XCTAssertTrue(events.isEmpty) }
        }
        XCTAssertEqual(reading.status.latest?.current?.url?.lastPathComponent, "3")
    }

    func testUserCredentialsDiscoverRepositoriesWithoutInstallations() async throws {
        for method in [SignInMethod.cli, .personal] {
            MockHTTP.handler = { request in
                XCTAssertEqual(request.url?.path, "/user/repos")
                let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "page" }?.value
                let names = page == "1" ? (0..<100).map { "work/repo-\($0)" } : ["work/monorepo"]
                return (200, [:], names.map { ["full_name": $0] })
            }
            let repos = try await api.repositories(token: "test", method: method)
            XCTAssertEqual(repos.count, 101)
            XCTAssertTrue(repos.contains("work/monorepo"))
        }
    }

    func testCredentialMigrationAndCLIPersistence() throws {
        let legacy = Data(#"{"accessToken":"old","clientID":"app-id","login":"me"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Credential.self, from: legacy).signInMethod, .app)
        let cli = try JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(Credential.cli(login: "me")))
        XCTAssertEqual(cli.signInMethod, .cli)
        XCTAssertEqual(cli.login, "me")
        XCTAssertTrue(cli.accessToken.isEmpty)
    }

    func testDeviceSignInAndSecretlessRenewal() async throws {
        MockHTTP.handler = { request in
            XCTAssertEqual(request.url?.host, "github.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            switch request.url!.path {
            case "/login/device/code":
                return (200, [:], ["device_code": "device", "user_code": "1234",
                                   "verification_uri": "https://github.com/login/device", "expires_in": 60, "interval": 1])
            case "/login/oauth/access_token":
                return (200, [:], ["access_token": "new", "refresh_token": "rotated", "expires_in": 28800])
            default: throw URLError(.badURL)
            }
        }
        let code = try await api.begin(clientID: "public-id")
        XCTAssertEqual(code.userCode, "1234")
        let result = try await api.authorize(clientID: "public-id", code: code)
        let session = try result.credential(clientID: "public-id", login: "me")
        let renewed = try await api.renew(session)
        XCTAssertEqual(renewed.refreshToken, "rotated")
        XCTAssertEqual(renewed.login, "me")
        XCTAssertNotNil(renewed.expiration)
    }

    func testRateLimitAndRevokedAccess() async {
        MockHTTP.handler = { _ in (403, ["Retry-After": "180"], ["message": "Slow down"]) }
        do { _ = try await api.login(token: "example"); XCTFail("Expected backoff") }
        catch ServiceError.rateLimit(let until) { XCTAssertGreaterThan(until.timeIntervalSinceNow, 175) }
        catch { XCTFail("\(error)") }
        MockHTTP.handler = { _ in (401, [:], ["message": "Bad credentials"]) }
        do { _ = try await api.login(token: "expired"); XCTFail("Expected reconnect") }
        catch ServiceError.unauthorized {} catch { XCTFail("\(error)") }
    }

    func testEnvironmentPollingUsesDeploymentTimestampAndSurvivesBusyRepository() async throws {
        let env = "backend-korey-async-worker-production"
        let watch = Watch(repository: "org/repo", environment: env, service: "worker", stage: "production")
        let date = "2026-11-18T21:47:15Z"
        func row(_ id: Int) -> [String: Any] {
            ["id": id, "environment": env, "sha": "ff8a9e5", "created_at": date]
        }
        func event(_ id: Int, _ state: String, _ time: String) -> [String: Any] {
            ["id": id, "state": state, "created_at": time, "log_url": "https://github.com/org/repo/actions/runs/42"]
        }
        var secondPoll = false
        var failNetwork = false
        MockHTTP.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer demo")
            if failNetwork { throw URLError(.notConnectedToInternet) }
            let url = request.url!
            if url.path.hasSuffix("/deployments") {
                XCTAssertTrue(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "environment", value: env)))
                return (200, [:], secondPoll ? [row(3), row(2), row(1)] : [row(2), row(1)])
            }
            if url.path.contains("/2/statuses") {
                return (200, [:], [event(12, "success", "2026-11-18T21:52:23Z"), event(11, "in_progress", date)])
            }
            if url.path.contains("/3/statuses") { return (200, [:], [event(14, "failure", "2026-11-18T22:10:10Z")]) }
            return (200, [:], [event(9, "inactive", date)])
        }
        let clock = ISO8601DateFormatter()
        let (first, initialAlerts) = try await api.poll(watch, shared: [], previous: Reading(), token: "demo",
                                                        now: clock.date(from: "2026-11-18T21:53:00Z")!)
        XCTAssertTrue(initialAlerts.isEmpty)
        XCTAssertEqual(first.status.success?.date, clock.date(from: "2026-11-18T21:52:23Z"))
        secondPoll = true
        let (second, alerts) = try await api.poll(watch, shared: [], previous: first, token: "demo",
                                                  now: clock.date(from: "2026-11-18T22:11:00Z")!)
        XCTAssertEqual(alerts.map(\.alert), [.failed])
        XCTAssertEqual(second.status.success?.date, first.status.success?.date)
        XCTAssertEqual(second.status.latest?.phase, .failed)
        failNetwork = true
        do { _ = try await api.poll(watch, shared: [], previous: second, token: "demo"); XCTFail("Expected offline error") }
        catch { XCTAssertEqual(second.status.failure?.date, clock.date(from: "2026-11-18T22:10:10Z")) }
    }
}
