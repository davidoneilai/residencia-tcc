import Foundation

enum Strategy: String, CaseIterable, Identifiable {
    case direct
    case planAct = "plan_act"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direto"
        case .planAct: "Plano e ação"
        }
    }
}

enum PhoneTask: String, CaseIterable, Identifiable {
    case ligar, faceTime, email, mensagem, calendario, lembrete, mapas, safari

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ligar: "Ligar"
        case .faceTime: "FaceTime"
        case .email: "E-mail"
        case .mensagem: "Mensagem"
        case .calendario: "Calendário"
        case .lembrete: "Lembrete"
        case .mapas: "Mapas"
        case .safari: "Safari"
        }
    }

    var prompt: String {
        switch self {
        case .ligar: "Ligue para +15550100."
        case .faceTime: "Faça uma chamada de FaceTime áudio para +15550102."
        case .email: "Envie um e-mail para test@example.com com assunto Teste iPhone e corpo Olá, isto é um teste."
        case .mensagem: "Envie uma mensagem para +15550101 dizendo Olá, isto é um teste."
        case .calendario: "Crie um evento no calendário chamado Teste MobileLLMBench daqui a 60 minutos."
        case .lembrete: "Crie um lembrete chamado Teste MobileLLMBench para daqui a 60 minutos."
        case .mapas: "Abra uma rota de carro no Mapas até Apple Park, Cupertino."
        case .safari: "Abra a página https://www.apple.com no Safari."
        }
    }
}

struct BenchmarkResult: Codable {
    var id = UUID()
    var timestamp = Date()
    var device: String
    var osVersion: String
    var backend: String
    var model: String
    var experiment: String
    var strategy: String
    var plan: String?
    var promptCharacters: Int
    var inputTokens: Int?
    var outputTokens: Int?
    var modelLoadMs: Double?
    var ttftMs: Double?
    var firstTextMs: Double?
    var totalMs: Double = 0
    var prefillTokensPerSecond: Double?
    var decodeTokensPerSecond: Double?
    var memoryBeforeMB: Double?
    var memoryAfterMB: Double?
    var thermalBefore: String
    var thermalAfter = "unknown"
    var batteryBefore: Float?
    var batteryAfter: Float?
    var toolCallCount: Int?
    var toolExecutionMs: Double?
    var toolTrace: [String]?
    var toolCallingMode: String?
    var stopReason: String?
    var response = ""
    var success = false
    var error: String?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, device, osVersion, backend, model, experiment, strategy, plan, promptCharacters
        case inputTokens, outputTokens, modelLoadMs, ttftMs, firstTextMs, totalMs
        case prefillTokensPerSecond, decodeTokensPerSecond, memoryBeforeMB, memoryAfterMB
        case thermalBefore, thermalAfter, batteryBefore, batteryAfter
        case toolCallCount, toolExecutionMs, toolTrace, toolCallingMode, stopReason
        case response, success, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(device, forKey: .device)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(backend, forKey: .backend)
        try c.encode(model, forKey: .model)
        try c.encode(experiment, forKey: .experiment)
        try c.encode(strategy, forKey: .strategy)
        try c.encode(plan, forKey: .plan)
        try c.encode(promptCharacters, forKey: .promptCharacters)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(modelLoadMs, forKey: .modelLoadMs)
        try c.encode(ttftMs, forKey: .ttftMs)
        try c.encode(firstTextMs, forKey: .firstTextMs)
        try c.encode(totalMs, forKey: .totalMs)
        try c.encode(prefillTokensPerSecond, forKey: .prefillTokensPerSecond)
        try c.encode(decodeTokensPerSecond, forKey: .decodeTokensPerSecond)
        try c.encode(memoryBeforeMB, forKey: .memoryBeforeMB)
        try c.encode(memoryAfterMB, forKey: .memoryAfterMB)
        try c.encode(thermalBefore, forKey: .thermalBefore)
        try c.encode(thermalAfter, forKey: .thermalAfter)
        try c.encode(batteryBefore, forKey: .batteryBefore)
        try c.encode(batteryAfter, forKey: .batteryAfter)
        try c.encode(toolCallCount, forKey: .toolCallCount)
        try c.encode(toolExecutionMs, forKey: .toolExecutionMs)
        try c.encode(toolTrace, forKey: .toolTrace)
        try c.encode(toolCallingMode, forKey: .toolCallingMode)
        try c.encode(stopReason, forKey: .stopReason)
        try c.encode(response, forKey: .response)
        try c.encode(success, forKey: .success)
        try c.encode(error, forKey: .error)
    }
}

enum BenchError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): message }
    }
}
