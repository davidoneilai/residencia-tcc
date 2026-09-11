# Mobile LLM Bench

O repositório também contém um MVP Android independente: [AndroidLLMBench](AndroidLLMBench/README.md), com Kotlin, LiteRT-LM e CPU. As instruções abaixo continuam sendo do MVP iOS.

Primeiro MVP de **Inferência Adaptativa de LLMs em Dispositivos Mobile**: somente characterization, com três experimentos locais, oito arquivos Swift e exportação JSON. Fontes criadas e revisadas estaticamente no Windows.

**Não foi possível validar a compilação iOS porque o ambiente atual é Windows.** Compilação, resolução completa do SwiftPM, execução e medições no iPhone ainda estão pendentes. Nenhum resultado experimental foi simulado.

## APIs e versões conferidas

- Apple: `SystemLanguageModel.default.availability`, `LanguageModelSession`, `streamResponse`, `GenerationOptions` e `Tool` com argumentos `@Generable`. [Framework](https://developer.apple.com/documentation/foundationmodels), [session](https://developer.apple.com/documentation/foundationmodels/languagemodelsession), [options](https://developer.apple.com/documentation/foundationmodels/generationoptions).
- No iOS 27, `AdditionProfile` usa `.required` e muda para `.disallowed` após a chamada; sem essa transição, o modo obrigatório pode continuar chamando tools. No iOS 26, usamos instruções explícitas e verificamos a execução real. [Tool calling oficial](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling).
- MLX: download/carregamento pela macro oficial `#huggingFaceLoadModelContainer`; `ModelContainer.prepare` aplica o tokenizer/chat template; `generate` produz texto e `.info(GenerateCompletionInfo)`. Padrão mínimo do [LLMEval consultado](https://github.com/ml-explore/mlx-swift-examples/blob/378f2449c257788c5067b9f8b086731d76b39b33/Applications/LLMEval/ViewModels/LLMEvaluator.swift), com métricas da biblioteca. [Integração oficial](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Libraries/MLXLMCommon/Documentation.docc/using.md).
- Modelo: **`mlx-community/gemma-3-1b-it-qat-4bit`**, configuração oficial **`LLMRegistry.gemma3_1B_qat_4bit`**. Nenhuma substituição. [Registro na versão fixada](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Libraries/MLXLLM/LLMModelFactory.swift).
- Deployment target: **iOS 26.0**. Para compilar estes fontes, use **Xcode 27 com SDK iOS 27**; os símbolos novos têm proteção de disponibilidade em runtime. A documentação consultada identifica **Xcode 27 RC**, Swift 6.4, exigindo macOS Tahoe 26.6+. [Requisitos oficiais](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes). Xcode 26 não contém todos os símbolos usados nestes fontes.

Dependências diretas via SwiftPM (selecione **Exact Version**):

| Repositório | Versão | Produtos a adicionar ao target |
| --- | --- | --- |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | **3.31.4** | `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace` |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | **0.9.0** | `HuggingFace` |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | **1.3.0** | `Tokenizers` |

Commit de `mlx-swift-lm` 3.31.4: `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57`. MLX Swift e Swift Syntax chegam transitivamente; suas versões efetivamente resolvidas devem ser preservadas no `Package.resolved` criado no Mac. Foundation Models, SwiftUI, Observation, UIKit e Mach são do SDK. O repositório de exemplos é apenas referência, não dependência.

## Primeiro teste no Mac/iPhone

1. No Xcode 27, crie **iOS App → MobileLLMBench → SwiftUI / Swift**, sem armazenamento ou testes adicionais.
2. Defina **iOS Deployment Target = 26.0**, **Swift Language Version = Swift 6** e **Default Actor Isolation = Nonisolated**. Os pontos de UI já têm isolamento explícito.
3. Adicione os três pacotes e produtos da tabela por **Package Dependencies**; autorize as macros oficiais quando o Xcode solicitar.
4. Substitua os fontes gerados pelos oito arquivos em `MobileLLMBench/`, todos no target do app; mantenha apenas um `@main` e uma `ContentView`.
5. Configure **Signing Team**. Conecte o iPhone 16 Pro por cabo ou Wi-Fi, habilite Developer Mode se solicitado e selecione o dispositivo físico.
6. Ative Apple Intelligence e aguarde o modelo do sistema ficar disponível. Deixe internet disponível para o primeiro download MLX; a inferência acontece no aparelho.
7. Execute pelo Xcode. Toque **Run All**: Apple baseline, Apple tool e MLX baseline, uma vez cada. Aguarde `Loading model...` na primeira execução MLX.
8. Confira respostas, três conjuntos de métricas, trace `137 + 284 = 421` (ou operandos invertidos) e resposta final `421` no teste da tool. Toque **Export JSON** e salve o array de resultados.
9. Toque **Run MLX Baseline** novamente: o container é reutilizado e `modelLoadMs` deve ser `null`. O JSON deve conter as quatro execuções da sessão.
10. Para dados de pesquisa, mude o scheme para **Release**, desmarque **Debug Executable** e execute no iPhone; também pode abrir o app instalado pela tela inicial.

## Como interpretar os dados

- `totalMs`: tempo observado desde a entrada no backend até seu retorno/erro; inclui carregamento/download quando necessário, preparação, geração e, na Apple, conferência da tool. Exclui leitura inicial/final do dispositivo, formatação do log e escrita JSON.
- `modelLoadMs`: somente um carregamento MLX concluído, incluindo download e tokenizer quando necessários. É `null` na Apple, no reuso do container e se o carregamento falhar; nesse último caso, a espera aparece em `totalMs` e o erro é exportado.
- `ttftMs`: no MLX, `GenerateCompletionInfo.promptTime × 1000`, incluindo prefill e primeiro token conforme a biblioteca; exclui carregamento e tokenização. Na Apple é `null`: snapshots não expõem o instante exato do primeiro token.
- `firstTextMs`: tempo observado até o primeiro trecho não vazio, sem carregamento MLX; inclui preparação/tokenização. Na Apple inclui criação da sessão e pode incluir o ciclo da tool. Não é intercambiável com TTFT.
- MLX: tokens e taxas vêm de `.info`; prefill/decode seguem as convenções da [versão fixada](https://github.com/ml-explore/mlx-swift-lm/blob/3.31.4/Libraries/MLXLMCommon/Evaluate.swift), sem contar chunks nem retokenizar a resposta. Ambos os baselines usam o mesmo prompt e limite de 128 tokens; Apple usa greedy, MLX temperatura zero. `stopReason = length` indica o limite MLX atingido, não erro.
- Apple: no iOS 27, tokens vêm de `session.usage` em uma sessão nova por execução e incluem o trabalho interno registrado pelo framework, inclusive tool calling; no iOS 26 são `null`. Taxas de prefill/decode permanecem `null`. [Usage](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/usage-swift.property).
- `toolExecutionMs`: soma do tempo dentro da tool para somar e converter o retorno em texto. Exclui agendamento, geração dos argumentos e resposta final do LLM; não é latência completa de tool calling. `toolTrace` e `toolCallCount` comprovam chamadas reais. O teste exige os operandos corretos e resposta final exatamente `421`, descontando espaços/quebras de linha; divergências são exportadas como falha.
- Memória: `task_info / phys_footprint` do **processo do app**, em MB decimais, antes/depois; não é pico. Não inclui necessariamente os serviços do sistema usados pela Apple, portanto os dois valores não representam a mesma cobertura de memória dos backends.
- Bateria: fração de 0 a 1, ou `null` se desconhecida; uma execução curta pode não mudar a leitura. `device` contém o identificador real de hardware de `hw.machine`; `osVersion` contém a versão do sistema.
- Falhas também geram resultados, preservando texto parcial disponível. `Run All` continua para o próximo experimento. Campos indisponíveis são exportados explicitamente como `null`.
- Resultados ficam em memória apenas durante a sessão; o JSON temporário contém todas as execuções dessa sessão. Exporte antes de fechar o app. O container MLX continua vivo, mas cada geração usa uma entrada nova, sem histórico de chat compartilhado.

## Cuidados mínimos de pesquisa

Use dispositivo físico, Release, preferencialmente sem debugger; feche apps desnecessários. Preserve o JSON, a versão/build do iOS e Xcode, o estado térmico inicial e o `Package.resolved` junto dos dados. Anote também conexão ao carregador e modo de baixo consumo. O armazenamento de 1 TB não equivale à RAM disponível.

O registro MLX usa a revisão padrão `main` dos pesos: registre a revisão do snapshot baixado antes de comparar sessões em instalações diferentes; fixar a versão SwiftPM não fixa os pesos. O modelo Apple é gerenciado pelo sistema e pode mudar entre versões do iOS. O `Run All` é uma verificação funcional em ordem fixa, não um protocolo experimental balanceado; a ordem e o container residente afetam memória/temperatura das execuções seguintes.

Depois do download inicial, confirme uma geração com a rede desligada para validar o uso local e do cache. Não há acesso a dados pessoais pela tool. Perfil de energia, memória dos serviços Apple e latências internas ficam para [Foundation Models Instrument / Instruments](https://developer.apple.com/documentation/foundationmodels/analyzing-the-runtime-performance-of-your-foundation-models-app).

Revisão no Windows: conferência das APIs nas fontes oficiais, importações/produtos, campos do JSON e caminhos de erro; removidas camadas extras. O único actor adicional é a própria tool, para proteger o trace contra chamadas concorrentes permitidas pelo framework. Não há runtime próprio, servidor, banco, repetições automáticas ou fase adaptativa. A conclusão funcional do MVP depende dos testes acima no iPhone.
