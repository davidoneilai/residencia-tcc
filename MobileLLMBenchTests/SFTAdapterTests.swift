import MLXLMCommon
import XCTest
@testable import MobileLLMBench

/// Casos SFT (LoRA PEFT) no `Agent` e leitura das saídas registradas no smoke do Mac (results/sft-smoke).
@MainActor
final class SFTAdapterTests: XCTestCase {
    func testSFTAgentsMapToAdapters() {
        XCTAssertEqual(Agent.sftModels.map(\.sft), [.qwen35, .minicpm5, .xlam2])
        XCTAssertEqual(Agent.studyModels, Agent.slms + Agent.sftModels)
        XCTAssertFalse(Agent.allCases.contains(where: { $0.sft != nil }))
        XCTAssertTrue(Agent.slms.allSatisfy { $0.sft == nil })
        for agent in Agent.sftModels {
            let sft = try! XCTUnwrap(agent.sft)
            XCTAssertEqual(agent.hubID, sft.baseID)
            XCTAssertEqual(agent.revision, sft.baseRevision)
            XCTAssertTrue(agent.model.hasSuffix("+\(sft.adapterID)@\(sft.adapterRevision)"))
            XCTAssertEqual(Agent(rawValue: agent.rawValue), agent)
            XCTAssertTrue(Strategy.direct.supports(agent))
        }
    }

    func testPinnedRevisionsExceptProvisionalXLAMBase() {
        for sft in SFTAdapter.all {
            XCTAssertEqual(sft.adapterRevision.count, 40, sft.adapterID)
        }
        XCTAssertEqual(SFTAdapter.qwen35.baseRevision.count, 40)
        XCTAssertEqual(SFTAdapter.minicpm5.baseRevision.count, 40)
        // Base MLX 4 bits do xLAM ainda não publicada: revisão provisória.
        XCTAssertEqual(SFTAdapter.xlam2.baseRevision, "main")
    }

    func testRecoversXLAMBareJSONList() {
        let raw = #"[{"name": "get_weather", "arguments": {"city": "Rome"}}, {"name": "get_weather", "arguments": {"city": "Madrid"}}]"#
        let calls = MLXPhoneBackend.recoverToolCalls(from: raw, known: ["get_weather"])
        XCTAssertEqual(calls.map(\.function.name), ["get_weather", "get_weather"])
        XCTAssertEqual(calls.map { $0.function.arguments["city"] }, [.string("Rome"), .string("Madrid")])
    }

    func testRecoversMiniCPMXML() {
        let raw = #"<function name="send_email"><param name="to">bob@example.com</param><param name="subject">Hi</param><param name="body">See you at 6</param></function>"#
        let calls = MLXPhoneBackend.recoverToolCalls(from: raw, known: ["send_email", "get_weather"])
        XCTAssertEqual(calls.map(\.function.name), ["send_email"])
        XCTAssertEqual(calls.first?.function.arguments["to"], .string("bob@example.com"))
    }

    /// Falha vista no Qwen3.5 SFT sobre a base 4 bits com o template do treino: o nome sai sem aspas.
    func testQwen35InvalidJSONNameIsNotRecovered() {
        let raw = "<tool_call>\n{\"name\": <function-get_weather>, \"arguments\": {\"city\": \"Paris\"}}\n</tool_call>"
        XCTAssertTrue(MLXPhoneBackend.recoverToolCalls(from: raw, known: ["get_weather"]).isEmpty)
    }
}
