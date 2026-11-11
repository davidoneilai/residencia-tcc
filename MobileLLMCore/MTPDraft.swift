import Foundation
import MLX
import MLXLMCommon
#if MLX_LM_MAIN
import MLXHuggingFace
import MLXLLM
import Tokenizers
#endif

/// Cabeças MTP (multi-token prediction) para decodificação especulativa no servidor do bench.
///
/// O Qwen3.5-2B oficial traz 1 camada MTP que a conversão `mlx-community` 4 bits descarta. A pasta
/// `Documents/mtp/<agent>/` do app recebe, pelo cabo, o `config.json` do `Qwen/Qwen3.5-2B` e um `.safetensors` só com os
/// tensores `mtp.*` (normas como desvio; o `mlx-swift-lm` soma 1). Só existe no build `MLX_LM_MAIN`: o 3.31.4 não tem o
/// iterador especulativo MTP, e ali `load` devolve nil.
enum MTPDrafters {
    static func directory(for agent: Agent) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mtp/\(agent.rawValue)", isDirectory: true)
    }

    /// O drafter (`any MTPDrafterModel`) ou nil se não houver cabeça para o modelo neste build.
    static func load(for agent: Agent) async throws -> Any? {
        #if MLX_LM_MAIN
        let directory = directory(for: agent)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path) else {
            return nil
        }
        await Qwen35TextMTPRegistration.register()
        let context = try await MTPDrafterModelFactory.shared.load(
            from: directory, using: #huggingFaceTokenizerLoader())
        return context.model
        #else
        return nil
        #endif
    }

    /// Iterador especulativo: `blockSize` tokens por passada de verificação (2 = 1 rascunho). Greedy e sem perda.
    static func iterator(
        input: LMInput, model: any LanguageModel, drafter: Any, cache: [any KVCache],
        parameters: GenerateParameters, blockSize: Int
    ) throws -> any TokenIteratorProtocol {
        #if MLX_LM_MAIN
        guard let drafter = drafter as? any MTPDrafterModel else { throw MTPError.notADrafter }
        return try MTPSpeculativeTokenIterator(
            input: input, mainModel: model, drafter: drafter, mainCache: cache, parameters: parameters,
            blockSize: blockSize)
        #else
        throw MTPError.unavailable
        #endif
    }

    enum MTPError: Error {
        case unavailable, notADrafter
    }
}
