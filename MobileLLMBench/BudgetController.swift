import Foundation

/// Teto comum às quatro políticas do piloto. Plano e recuperação entram na conta.
enum BudgetCaps {
    static let perRound = 512
    static let totalGenerated = PhonePrompt.maxToolRounds * perRound
    static var maxToolRounds: Int { PhonePrompt.maxToolRounds }
    static let plan = 128
    static let shortPlan = 64
    static let recovery = 256
    static let maxRecoveries = 2
}

enum ToolErrorPolicy {
    static func absorbs(_ strategy: Strategy) -> Bool {
        switch strategy {
        case .noThinkRuntime, .actionAware, .adaptiveStep: true
        default: false
        }
    }
}

enum BudgetKind {
    case direct, planAct, budgetedDirect, reactiveBudget, adaptiveStep, actionAware

    static func from(_ strategy: Strategy) -> BudgetKind {
        switch strategy {
        case .planAct: .planAct
        case .budgetedDirect: .budgetedDirect
        case .reactiveBudget: .reactiveBudget
        case .adaptiveStep: .adaptiveStep
        case .actionAware: .actionAware
        default: .direct
        }
    }
}

/// Decisão por rodada de `adaptive_step`. Sem treino; só estado observável.
struct StepDecision: Equatable {
    enum Mode: String, Equatable { case stop, fast, slow, recover }
    var mode: Mode
    var trigger: String

    var thinking: Bool { mode == .slow }
    var thinkBudget: Int? { mode == .slow ? BudgetCaps.shortPlan : nil }
}

struct BudgetTrajectory {
    var prompt: String
    var roundsDone: Int
    var remainingTokens: Int
    var remainingRounds: Int
    var lastStop: String?
    var lastHadCalls: Bool
    var lastText: String
    var planned: Bool
    var toolOutputs: [(name: String, output: String)]
}

/// Controlador sem treino. Só vê prompt, orçamento restante e saídas de ferramentas — nunca o gabarito.
enum BudgetController {
    static func nextLimit(remaining: Int) -> Int {
        min(BudgetCaps.perRound, max(0, remaining))
    }

    static func planLimit(kind: BudgetKind, remaining: Int) -> Int {
        let cap = kind == .reactiveBudget ? BudgetCaps.shortPlan : BudgetCaps.plan
        return min(cap, max(0, remaining))
    }

    /// P3: decide com o estado atual. P2 usa `recover` no mesmo gatilho de no_progress.
    static func observe(_ view: BudgetTrajectory, kind: BudgetKind) -> (action: String, trigger: String?) {
        if view.remainingTokens < 8 || view.remainingRounds <= 0 {
            return ("stop", "budget")
        }
        if kind == .direct || kind == .planAct {
            return ("continue", nil)
        }
        if view.lastHadCalls {
            if kind != .reactiveBudget { return ("continue", nil) }
            if let trigger = toolError(view.toolOutputs.last?.output) {
                return view.planned ? ("continue", trigger) : ("plan", trigger)
            }
            if unresolvedDependency(view) {
                return view.planned ? ("continue", "unresolved_dependency") : ("plan", "unresolved_dependency")
            }
            return ("continue", nil)
        }
        if view.roundsDone == 0 {
            return ("continue", nil)
        }
        if noProgress(view) {
            if kind == .budgetedDirect { return ("recover", "no_progress") }
            return view.planned ? ("recover", "no_progress") : ("plan", "no_progress")
        }
        return ("continue", nil)
    }

    static func noProgress(_ view: BudgetTrajectory) -> Bool {
        if view.lastHadCalls { return false }
        // Já houve ferramenta e a geração parou com stop: é conclusão, não bloqueio.
        if !view.toolOutputs.isEmpty, view.lastStop != "length" { return false }
        if view.lastStop == "length" { return true }
        let text = view.lastText
        return text.contains("<think>") || text.contains("</think>") || text.count > 80
    }

    static func toolError(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let lower = output.lowercased()
        let needles = [
            "não encontrado", "nao encontrado", "inválid", "invalid",
            "precisa começar", "precisa comecar", "failed", "erro", "falha",
            "sem permissão", "sem permissao",
        ]
        return needles.contains(where: { lower.contains($0) }) ? "tool_error" : nil
    }

    /// Think Fast and Slow sem treino: fast = sem thinking; slow = s1 budget 64; recover = nothink curto.
    static func step(_ view: BudgetTrajectory) -> StepDecision {
        if view.remainingTokens < 8 || view.remainingRounds <= 0 {
            return StepDecision(mode: .stop, trigger: "budget")
        }
        if view.roundsDone > 0, noProgress(view) {
            return StepDecision(mode: .recover, trigger: "no_progress")
        }
        if view.roundsDone > 0, !view.lastHadCalls, !view.toolOutputs.isEmpty, view.lastStop != "length" {
            return StepDecision(mode: .stop, trigger: "done")
        }
        if let trigger = toolError(view.toolOutputs.last?.output) {
            return StepDecision(mode: .slow, trigger: trigger)
        }
        if unresolvedDependency(view) {
            return StepDecision(mode: .fast, trigger: "unresolved_dependency")
        }
        if view.roundsDone == 0 {
            let f = AdaptiveFeatures.extract(view.prompt)
            if f.seqCueCount >= 1 || f.contactNameHits >= 1 {
                return StepDecision(mode: .slow, trigger: "sequential_or_contact")
            }
            if f.toolCueCount >= 2 {
                return StepDecision(mode: .slow, trigger: "multi_tool")
            }
            return StepDecision(mode: .fast, trigger: "short_single")
        }
        if view.lastHadCalls {
            return StepDecision(mode: .fast, trigger: "continue")
        }
        return StepDecision(mode: .fast, trigger: "default")
    }

    static func unresolvedDependency(_ view: BudgetTrajectory) -> Bool {
        guard let hit = view.toolOutputs.last(where: { $0.name == "buscarContato" }) else { return false }
        if toolError(hit.output) != nil { return false }
        let hasPhone = hit.output.contains("+") && hit.output.contains(where: { $0.isNumber })
        guard hasPhone else { return false }
        let follow = ["ligar", "ligarFaceTime", "enviarMensagem", "enviarWhatsApp"]
        let after = view.toolOutputs.drop(while: { $0.name != "buscarContato" }).dropFirst()
        return !after.contains { follow.contains($0.name) }
    }

    static func selfCheck() {
        let prompt = "Busque o contato Ana e depois ligue para ela."
        let empty = BudgetTrajectory(
            prompt: prompt, roundsDone: 1, remainingTokens: 1536, remainingRounds: 3,
            lastStop: "length", lastHadCalls: false, lastText: "<think>plano longo",
            planned: false, toolOutputs: [])
        let a = observe(empty, kind: .reactiveBudget)
        precondition(a.action == "plan" && a.trigger == "no_progress", "\(a)")
        let b = observe(empty, kind: .budgetedDirect)
        precondition(b.action == "recover" && b.trigger == "no_progress", "\(b)")

        let found = BudgetTrajectory(
            prompt: prompt, roundsDone: 1, remainingTokens: 1400, remainingRounds: 3,
            lastStop: "stop", lastHadCalls: true, lastText: "", planned: false,
            toolOutputs: [("buscarContato", "Ana: +15550100")])
        let c = observe(found, kind: .reactiveBudget)
        precondition(c.action == "plan" && c.trigger == "unresolved_dependency", "\(c)")

        let missing = BudgetTrajectory(
            prompt: prompt, roundsDone: 1, remainingTokens: 1400, remainingRounds: 3,
            lastStop: "stop", lastHadCalls: true, lastText: "", planned: false,
            toolOutputs: [("buscarContato", "Contato não encontrado: Ana.")])
        let d = observe(missing, kind: .reactiveBudget)
        precondition(d.action == "plan" && d.trigger == "tool_error", "\(d)")

        let done = BudgetTrajectory(
            prompt: prompt, roundsDone: 2, remainingTokens: 900, remainingRounds: 2,
            lastStop: "stop", lastHadCalls: true, lastText: "", planned: false,
            toolOutputs: [("buscarContato", "Ana: +15550100"), ("ligar", "tel:+15550100")])
        let e = observe(done, kind: .reactiveBudget)
        precondition(e.action == "continue" && e.trigger == nil, "\(e)")
        let afterOk = BudgetTrajectory(
            prompt: prompt, roundsDone: 2, remainingTokens: 900, remainingRounds: 2,
            lastStop: "stop", lastHadCalls: false, lastText: "feito", planned: false,
            toolOutputs: [("criarEvento", "evento Defesa")])
        let f = observe(afterOk, kind: .budgetedDirect)
        precondition(f.action == "continue", "\(f)")
        precondition(nextLimit(remaining: 100) == 100)
        precondition(nextLimit(remaining: 9000) == 512)
        precondition(a.action != c.action || a.trigger != c.trigger)

        let short = step(BudgetTrajectory(
            prompt: "Ligue para +15550100.", roundsDone: 0, remainingTokens: 2048, remainingRounds: 4,
            lastStop: nil, lastHadCalls: false, lastText: "", planned: false, toolOutputs: []))
        precondition(short.mode == .fast && short.trigger == "short_single" && !short.thinking, "\(short)")
        let seq = step(BudgetTrajectory(
            prompt: "Busque o contato Ana e depois ligue para ela.", roundsDone: 0, remainingTokens: 2048,
            remainingRounds: 4, lastStop: nil, lastHadCalls: false, lastText: "", planned: false, toolOutputs: []))
        precondition(seq.mode == .slow && seq.trigger == "sequential_or_contact" && seq.thinkBudget == 64, "\(seq)")
        let stuck = step(empty)
        precondition(stuck.mode == .recover && stuck.trigger == "no_progress" && !stuck.thinking, "\(stuck)")
        let afterContact = step(found)
        precondition(afterContact.mode == .fast && afterContact.trigger == "unresolved_dependency", "\(afterContact)")
        let missingContact = step(missing)
        precondition(missingContact.mode == .slow && missingContact.trigger == "tool_error", "\(missingContact)")
        let emptyAfterTools = step(BudgetTrajectory(
            prompt: prompt, roundsDone: 2, remainingTokens: 900, remainingRounds: 2,
            lastStop: "stop", lastHadCalls: false, lastText: "Ligue para +15550100", planned: false,
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        precondition(emptyAfterTools.mode == .stop && emptyAfterTools.trigger == "done", "\(emptyAfterTools)")

        let start = action(BudgetTrajectory(
            prompt: "Ligue para +15550100.", roundsDone: 0, remainingTokens: 2048, remainingRounds: 4,
            lastStop: nil, lastHadCalls: false, lastText: "", planned: false, toolOutputs: []))
        precondition(start.mode == .fast && start.trigger == "default" && !start.thinking, "\(start)")
        let afterLookup = action(found)
        precondition(afterLookup.mode == .fast && afterLookup.trigger == "continue", "\(afterLookup)")
        let missingFollow = action(BudgetTrajectory(
            prompt: prompt, roundsDone: 2, remainingTokens: 900, remainingRounds: 2,
            lastStop: "stop", lastHadCalls: false, lastText: "Ligue para +15550100", planned: false,
            toolOutputs: [("buscarContato", "Ana: +15550100")]))
        precondition(missingFollow.mode == .recover && missingFollow.trigger == "unresolved_dependency", "\(missingFollow)")
        let finished = action(afterOk)
        precondition(finished.mode == .stop && finished.trigger == "done", "\(finished)")
        precondition(ToolErrorPolicy.absorbs(.actionAware) && !ToolErrorPolicy.absorbs(.noThink))
    }

    /// NoThink por padrão. Thinking só depois de falha observável (erro, dependência, zero tools). Sem gold.
    static func action(_ view: BudgetTrajectory, recoveries: Int = 0) -> StepDecision {
        if view.remainingTokens < 8 || view.remainingRounds <= 0 {
            return StepDecision(mode: .stop, trigger: "budget")
        }
        if recoveries >= BudgetCaps.maxRecoveries {
            if view.lastHadCalls { return StepDecision(mode: .fast, trigger: "continue") }
            return StepDecision(mode: .stop, trigger: "recover_cap")
        }
        if let trigger = toolError(view.toolOutputs.last?.output), view.lastHadCalls {
            return StepDecision(mode: .recover, trigger: trigger)
        }
        if !view.lastHadCalls, unresolvedDependency(view) {
            return StepDecision(mode: .recover, trigger: "unresolved_dependency")
        }
        if view.roundsDone > 0, !view.lastHadCalls, view.toolOutputs.isEmpty {
            return StepDecision(mode: .recover, trigger: "missing_call")
        }
        if view.roundsDone > 0, !view.lastHadCalls, !view.toolOutputs.isEmpty, view.lastStop != "length" {
            return StepDecision(mode: .stop, trigger: "done")
        }
        if view.lastHadCalls {
            return StepDecision(mode: .fast, trigger: "continue")
        }
        return StepDecision(mode: .fast, trigger: "default")
    }
}
