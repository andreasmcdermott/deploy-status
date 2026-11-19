import XCTest
@testable import DeployCore

final class DeploymentTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func attempt(_ id: Int, _ states: [(Int, String)]) -> Attempt {
        let deployment = Deployment(id: id, environment: "production", sha: "abcdef",
                                    createdAt: start.addingTimeInterval(Double(id)))
        return Attempt(deployment, statuses: states.map { offset, state in
            GitStatus(id: id * 100 + offset, state: state, createdAt: start.addingTimeInterval(Double(offset)), logUrl: nil)
        })
    }

    func testOverlappingAttemptsAndDelayedCompletion() throws {
        let earlier = attempt(1, [(1, "in_progress")])
        let newer = attempt(2, [(2, "success")])
        var status = Snapshot()
        XCTAssertTrue(status.update(recent: [earlier, newer], history: [], at: start.addingTimeInterval(5)).isEmpty)
        XCTAssertEqual(status.latest?.id, 2)
        XCTAssertEqual(status.active.map(\.id), [1])

        let finished = attempt(1, [(1, "in_progress"), (4, "failure"), (6, "failure")])
        let alerts = status.update(recent: [finished, newer], history: [], at: start.addingTimeInterval(7))
        XCTAssertEqual(alerts.map(\.alert), [.failed])
        XCTAssertEqual(status.failure?.date, start.addingTimeInterval(6))
        XCTAssertEqual(status.success?.date, start.addingTimeInterval(2))
        XCTAssertTrue(status.active.isEmpty)
        XCTAssertEqual(status.latest?.phase, .succeeded)
        XCTAssertTrue(status.update(recent: [finished, newer], history: [], at: start.addingTimeInterval(8)).isEmpty)
    }

    func testRetryAndOfflineCache() throws {
        var status = Snapshot()
        let original = attempt(1, [(1, "error")])
        _ = status.update(recent: [original], history: [], at: start.addingTimeInterval(2))
        let retry = attempt(1, [(1, "error"), (3, "queued"), (4, "in_progress"), (5, "success")])
        let restored = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(restored.failure?.date, start.addingTimeInterval(1))
        status = restored
        XCTAssertEqual(status.update(recent: [retry], history: [], at: start.addingTimeInterval(6)).map(\.alert),
                       [.started, .succeeded])
        let inactive = attempt(1, [(5, "success"), (7, "inactive")])
        XCTAssertTrue(status.update(recent: [inactive], history: [], at: start.addingTimeInterval(8)).isEmpty)
        XCTAssertEqual(status.latest?.phase, .inactive)
        XCTAssertEqual(status.success?.date, start.addingTimeInterval(5))
    }

    func testMissingSkippedAndUnrecognizedStatesNeverSynthesizeSuccess() {
        var status = Snapshot()
        _ = status.update(recent: [attempt(1, []), attempt(2, [(2, "skipped")])], history: [], at: start)
        XCTAssertNil(status.success)
        XCTAssertEqual(status.latest?.phase, .unknown)
    }
}
