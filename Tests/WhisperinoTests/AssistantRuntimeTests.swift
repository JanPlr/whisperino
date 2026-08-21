import XCTest
@testable import Whisperino

final class AssistantRuntimeTests: XCTestCase {
    private func makeRegistry() -> AssistantToolRegistry {
        AssistantToolRegistry(tools: [
            LocalFinderAssistantTool(),
            OpenLocalFileAssistantTool(),
            CreateCalendarEventAssistantTool(),
            WebSearchAssistantTool(),
        ])
    }

    func testPlannerRoutesExplicitFileSearchToRegisteredTool() throws {
        let planner = AssistantPlanner(descriptors: makeRegistry().descriptors)

        let plan = try XCTUnwrap(planner.plan("Find my tax PDF on my Mac"))

        XCTAssertEqual(plan.requests.count, 1)
        XCTAssertEqual(plan.requests[0].toolID, LocalFinderAssistantTool.id)
        XCTAssertEqual(plan.requests[0].arguments["query"], .string("my tax PDF"))
    }

    func testPlannerLeavesGeneralQuestionsForAnswerPath() {
        let planner = AssistantPlanner(descriptors: makeRegistry().descriptors)

        XCTAssertNil(planner.plan("Find out why this Swift task is slow"))
    }

    func testPlannerPreparesCalendarAction() throws {
        let planner = AssistantPlanner(descriptors: makeRegistry().descriptors)
        let plan = try XCTUnwrap(
            planner.plan("Schedule a design review meeting tomorrow at 2 PM")
        )

        XCTAssertEqual(plan.requests.first?.toolID, CreateCalendarEventAssistantTool.id)
        let invocation = try makeRegistry().prepare(plan.requests[0], sessionID: UUID())
        XCTAssertEqual(invocation.effect, .externalAction)
    }

    func testPlannerPreparesWebSearchAction() throws {
        let planner = AssistantPlanner(descriptors: makeRegistry().descriptors)
        let plan = try XCTUnwrap(planner.plan("Find and open Ada Lovelace on LinkedIn"))

        XCTAssertEqual(plan.requests.first?.toolID, WebSearchAssistantTool.id)
        XCTAssertEqual(plan.requests.first?.arguments["query"], .string("Ada Lovelace on LinkedIn"))
    }

    func testRegistryRejectsUnregisteredCapabilities() {
        let request = ToolRequest(toolID: "shell.execute", arguments: [:])

        XCTAssertThrowsError(try makeRegistry().prepare(request, sessionID: UUID())) { error in
            XCTAssertEqual(error as? AssistantRuntimeError, .unknownTool("shell.execute"))
        }
    }

    func testRegistryRejectsUnexpectedArguments() {
        let request = ToolRequest(
            toolID: LocalFinderAssistantTool.id,
            arguments: ["query": .string("tax"), "command": .string("rm")]
        )

        XCTAssertThrowsError(try makeRegistry().prepare(request, sessionID: UUID()))
    }

    @MainActor
    func testExternalActionCannotExecuteWithoutConfirmation() async throws {
        let registry = makeRegistry()
        let request = ToolRequest(
            toolID: OpenLocalFileAssistantTool.id,
            arguments: [
                "path": .string(#filePath),
                "name": .string("AssistantRuntimeTests.swift"),
                "detail": .string("Swift · Tests"),
                "symbol": .string("doc.fill"),
            ]
        )
        let invocation = try registry.prepare(request, sessionID: UUID())

        do {
            _ = try await registry.execute(invocation, confirmed: false)
            XCTFail("Expected the runtime to require confirmation")
        } catch {
            XCTAssertEqual(
                error as? AssistantRuntimeError,
                .confirmationRequired("Open file")
            )
        }
    }
}
