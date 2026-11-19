import XCTest
@testable import DeployCore

final class WorkflowInputTests: XCTestCase {
    func testDispatchSchemaAndRevisionSpecificConditionalTitle() throws {
        let definition = try WorkflowDefinition(yaml: """
        'on':
          workflow_dispatch:
            inputs:
              target: {type: choice, required: true, options: [sandbox, live]}
              rebuild: {type: boolean, default: false}
              retries: {type: number, default: 3}
              notes: {type: string}
          workflow_call:
            inputs: {unrelated: {type: string}}
        run-name: >-
          api → ${{ github.event_name == 'pull_request' && 'preview' || inputs.target || 'sandbox' }}${{ inputs.target == 'live' && (inputs.rebuild && ' forced' || ' promotion') || '' }}
        """)
        XCTAssertEqual(definition.inputs.map(\.id), ["target", "rebuild", "retries", "notes"])
        XCTAssertEqual(definition.inputs.map(\.options), [["sandbox", "live"], ["true", "false"], [], []])
        let title = RunTemplate(try XCTUnwrap(definition.title))
        let context = ["github.event_name": "workflow_dispatch"]
        XCTAssertEqual(title.finiteValues(for: "api → live promotion", inputs: definition.inputs, context: context),
                       ["target": "live", "rebuild": "false"])
        XCTAssertEqual(title.finiteValues(for: "api → sandbox", inputs: definition.inputs, context: context), ["target": "sandbox"])
        XCTAssertEqual(title.finiteValues(for: "api → preview", inputs: definition.inputs, context: context), [:])
    }

    func testUnpublishedInputsAndMaskedOrAmbiguousOutputAreUnknown() throws {
        let inputs = try WorkflowDefinition(yaml: """
        on: {workflow_dispatch: {inputs: {region: {type: string, default: west}, name: {type: string}}}}
        """).inputs
        XCTAssertEqual(RunTemplate("Release").match("Release", inputs: inputs, context: [:]), [:])
        let line = RunTemplate(#"  REGION="${{ inputs.region }}""#)
        XCTAssertEqual(line.match(#"  REGION="east""#, inputs: inputs, context: [:]), ["region": "east"])
        XCTAssertEqual(line.match(#"  REGION="***""#, inputs: inputs, context: [:]), [:])
        let ambiguous = RunTemplate("${{ inputs.region }}${{ inputs.name }}")
        XCTAssertEqual(ambiguous.match("eastwest", inputs: inputs, context: [:]), [:])
    }

    func testOldFilterNamesMigrateAndArbitraryInputNamesRoundTrip() throws {
        let old = try JSONDecoder().decode(WorkflowFilter.self, from: Data(#"{"field":"Environment","value":"production"}"#.utf8))
        XCTAssertEqual(old.field, .input("environment"))
        for field in [RunField.title, .input("title"), .input("deployment_group"), .input("force")] {
            let filter = WorkflowFilter(field: field, value: "true")
            XCTAssertEqual(try JSONDecoder().decode(WorkflowFilter.self, from: JSONEncoder().encode(filter)), filter)
        }
    }

    func testGuardFollowsVerifiedOutputForwardingInAnUnrelatedWorkflow() throws {
        let definition = try WorkflowDefinition(yaml: """
        on: {workflow_dispatch: {inputs: {region: {type: choice, required: true, options: [east, west]}}}}
        jobs:
          plan:
            outputs: {place: '${{ steps.select.outputs.place }}'}
            steps:
              - id: select
                run: echo "place=${{ inputs.region || 'west' }}" >> $GITHUB_OUTPUT
          ship:
            needs: plan
            steps:
              - name: Route east
                if: needs.plan.outputs.place == 'east'
              - name: Unrelated
                if: needs.plan.outputs.place == 'west' || always()
        """)
        XCTAssertEqual(definition.guards.count, 1)
        XCTAssertEqual(definition.guards.first?.input, "region")
        XCTAssertEqual(definition.guards.first?.value, "east")
    }
}
