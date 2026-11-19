import DeployCore
import XCTest
@testable import DeployStatus

final class WatchlistTests: XCTestCase {
    private let repo = "org/monorepo"

    private func workflow(_ id: Int, repo: String = "org/monorepo") -> Watch {
        Watch(repository: repo, environment: "workflow-\(id).yml", service: "Deploy", stage: "Workflow", workflowID: id)
    }

    func testBatchAndPreferenceSurviveReopen() throws {
        var state = StateFile()
        XCTAssertTrue(state.add([workflow(1)]))
        XCTAssertTrue(state.add([workflow(1), workflow(2), workflow(3), workflow(2)]))
        XCTAssertFalse(state.add([workflow(3)]))
        let restored = try JSONDecoder().decode(StateFile.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.watches.compactMap(\.workflowID), [1, 2, 3])
        XCTAssertEqual(restored.preferredRepository(in: ["a/first", repo]), repo)
        XCTAssertEqual(restored.preferredRepository(in: ["a/first"]), "a/first")
        XCTAssertEqual(restored.preferredRepository(in: []), "")
    }

    func testFilterChangeClearsOldReadingAndSurvivesReopen() throws {
        var state = StateFile()
        let target = workflow(2)
        _ = state.add([target])
        state.readings[target.id] = Reading()
        let filter = WorkflowFilter(field: .title, value: " production ")
        XCTAssertTrue(state.setFilter(filter, for: target.id))
        XCTAssertNil(state.readings[target.id])
        var restored = try JSONDecoder().decode(StateFile.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.watches.first?.runFilter?.value, "production")
        restored.readings[target.id] = Reading()
        XCTAssertFalse(restored.setFilter(filter, for: target.id))
        XCTAssertNotNil(restored.readings[target.id])
        XCTAssertTrue(restored.setFilter(nil, for: target.id))
        XCTAssertNil(restored.readings[target.id])
    }

    func testRenameAfterBatchFollowSurvivesReopen() throws {
        var state = StateFile()
        var target = workflow(2)
        target.alerts = [.failed]
        _ = state.add([workflow(1), target])
        state.readings[target.id] = Reading()

        XCTAssertTrue(state.rename(target.id, to: "  Production API  "))
        XCTAssertFalse(state.rename(target.id, to: "  "))
        let restored = try JSONDecoder().decode(StateFile.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.watches.map(\.service), ["Deploy", "Production API"])
        XCTAssertEqual(restored.watches.last?.id, target.id)
        XCTAssertEqual(restored.watches.last?.workflowID, 2)
        XCTAssertEqual(restored.watches.last?.alerts, [.failed])
        XCTAssertNotNil(restored.readings[target.id])
    }

    func testOldWatchlistAndExplicitSelectionWithoutAFollow() throws {
        var state = StateFile()
        _ = state.add([workflow(1)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "lastRepository")
        var restored = try JSONDecoder().decode(StateFile.self, from: JSONSerialization.data(withJSONObject: json))
        let available = ["a/first", repo, "org/second"]
        XCTAssertEqual(restored.preferredRepository(in: available), repo)
        restored.lastRepository = "org/second"
        restored.watches.removeAll()
        XCTAssertEqual(restored.preferredRepository(in: available), "org/second")
    }
}
