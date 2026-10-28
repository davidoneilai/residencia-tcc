# Inferência adaptativa de LLMs em dispositivos móveis

Residência / TCC. Pergunta central: estratégias de inferência (sem thinking, orçamento de tokens, plano+ação, roteadores adaptativos) reduzem a latência de tarefas agênticas em LLMs pequenos **rodando no iPhone** sem perder qualidade?

## Para a banca: por onde começar

1. **[Relatórios semanais](reports/weekly/README.md)**: linha do tempo das 8 semanas, com link para a evidência de cada uma.
2. **[Semana 8 (2026-W44)](reports/weekly/2026-W44/README.md)**: relatório mais recente, gerado por script a partir dos dados, com [manifesto de reprodutibilidade](reports/weekly/2026-W44/MANIFEST.md).

## Onde a inferência e a avaliação acontecem

| Etapa | Máquina | Código |
|---|---|---|
| Inferência | iPhone 16 Pro, MLX Swift (`mlx-swift-lm` 3.31.4) e Apple Foundation Models | [`MobileLLMBench/`](MobileLLMBench) |
| Inferência de referência | GPU NVIDIA B200 (vLLM), semana 4 | [`mobile-adaptive-inference/`](mobile-adaptive-inference/README.md) |
| Avaliação e análise | Mac (Python; `ast_checker` oficial do `bfcl-eval` no BFCL) | [`analysis/`](analysis/README.md) |

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `MobileLLMBench/` | Fontes do app iOS (runner, backends MLX/Apple, estratégias, roteadores, datasets) |
| `MobileLLMBenchTests/` | Testes XCTest do app |
| `results/` | Sessões brutas exportadas do iPhone. **Não editar.** |
| `reports/` | Relatórios por estudo, cada um com as sessões e os resumos usados |
| `reports/weekly/` | Relatórios semanais para a banca |
| `analysis/` | Scripts de avaliação e análise (rodam no Mac) |
| `mobile-adaptive-inference/` | Experimentos em GPU com vLLM e benchmarks oficiais |
| `AndroidLLMBench/` | MVP Android (semana 1) |
| `docs/` | Plano inicial e entregas |

## Reproduzir as análises (sem iPhone)

```bash
python3 analysis/weekly/generate.py --check     # recalcula a Semana 8 e valida números e links
python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl
```

Para reavaliar sessões do BFCL com o checker oficial, use o ambiente `.bfcl-venv` (`pip install bfcl-eval==2026.3.23`), descrito no [manifesto](reports/weekly/2026-W44/MANIFEST.md). Para rodar novas sessões no aparelho: `IPHONE_UDID=<udid> analysis/slm_bfcl/run_sessions.sh ...` (o UDID não fica versionado).

## Dados não versionados

- `Google.xcconfig` (Client ID do Google Sign-In) e qualquer `*.xcconfig`/`.env`.
- O projeto Xcode (`MobileLLMBench.xcodeproj`) fica em um repositório separado; este repositório tem os fontes que ele compila.
- Conversas do chat guardadas no iPhone (`Chat/conversations.json`): são uso pessoal, não experimento.

---

# App iOS: MobileLLMBench

A primeira versão (semana 5) comparou **direto** e **plano e ação** em três modelos: o `SystemLanguageModel` da Apple, `mlx-community/Qwen3-1.7B-4bit` e `mlx-community/gemma-4-e2b-it-4bit` (os dois últimos pelo MLX, `mlx-swift-lm` 3.31.4). Depois o app ganhou o protocolo 2, os datasets Apple e BFCL, estratégias de raciocínio, roteadores adaptativos e o chat agêntico (ver os relatórios em `reports/`).

## Ferramentas

| Tool | API da Apple | O que acontece |
| --- | --- | --- |
| `ligar` | `tel:` | Abre o Telefone e disca |
| `ligarFaceTime` | `facetime-audio:` | Abre o FaceTime áudio |
| `enviarEmail` | `mailto:` | Abre o Mail com a mensagem preenchida |
| `enviarMensagem` | `sms:` | Abre o Mensagens com o texto preenchido |
| `criarEvento` | EventKit | Grava um evento |
| `criarLembrete` | EventKit | Grava um lembrete |
| `abrirRota` | `https://maps.apple.com` | Abre uma rota de carro |
| `abrirSafari` | `https` | Abre a página no Safari |
| `buscarContato` | agenda sintética | Devolve o número de Ana, Bruno ou Carla; não lê os contatos do aparelho |

## Tarefas

| Tipo | Tarefas | Acerto |
| --- | --- | --- |
| `single_tool` | Ligar, FaceTime, E-mail, Mensagem, Calendário, Lembrete, Mapas, Safari | Chamou exatamente a ferramenta esperada |
| `multi_tool` | Evento + lembrete; Lembrete + mensagem | Chamou exatamente as duas ferramentas, em qualquer ordem |
| `sequential` | Contato → ligar; Contato → mensagem; Contato → lembrete → FaceTime | Chamou as ferramentas esperadas e a ação usou o número que só a busca devolve |

O acerto está em `PhoneTask.grade`; ferramenta repetida ou faltando conta como falha. Os números são `+15550100` a `+15550102`, o e-mail é `test@example.com`. Mail e Mensagens abrem o rascunho; o envio continua na mão de quem testa. Calendário e Lembretes gravam de verdade.

**Direto** manda o pedido já com as tools. **Plano e ação** gera um plano de até 128 tokens sem tools e só então gera com as tools, como em `strategies.py`. No MLX, o resultado de cada ferramenta volta ao modelo como mensagem `tool`, em até 4 rodadas; no modelo da Apple a `LanguageModelSession` faz esse ciclo sozinha. Amostragem gulosa nos três.

## Build no Xcode

1. Crie **iOS App → MobileLLMBench → SwiftUI / Swift**, sem armazenamento e sem testes.
2. **iOS Deployment Target = 26.0**, **Swift Language Version = Swift 6**, **Default Actor Isolation = Nonisolated**.
3. Adicione o pacote `https://github.com/ml-explore/mlx-swift-lm` (3.31.4) com `MLXLLM`, `MLXLMCommon` e `MLXHuggingFace`. Coloque no target todos os `.swift` de `MobileLLMBench/` e os datasets `BFCLSubset.json` e `BFCLv4AST.json`. Os testes de `MobileLLMBenchTests/` vão num target de testes. O chat com Google Calendar precisa de um `Google.xcconfig` próprio com `GOOGLE_IOS_CLIENT_ID` e `GOOGLE_IOS_REVERSED_CLIENT_ID` (não versionado).
4. No target, em Info, adicione:
   - `NSCalendarsFullAccessUsageDescription` = `O teste grava um evento para verificar a ferramenta de calendário.`
   - `NSRemindersFullAccessUsageDescription` = `O teste grava um lembrete para verificar a ferramenta de lembretes.`
5. Configure o **Signing Team**, conecte o iPhone, ative o Developer Mode se o sistema pedir e selecione o aparelho.
6. Ative o Apple Intelligence e espere o modelo do sistema ficar disponível.
7. Rode pelo Xcode. O projeto usado nos experimentos fica em um repositório separado (`MobileLLMBench.xcodeproj`) e compila os fontes desta pasta.
8. No app há três modos. **Demo** escolhe o modelo, a estratégia e uma tarefa. **Prompt** manda um texto livre com as mesmas ferramentas. **Matriz** roda 3 modelos × 2 estratégias × 13 tarefas = 78 execuções. Qwen e Gemma baixam na primeira execução e ficam um por vez na memória. **Export JSON** junta as execuções da sessão.

## Métricas por execução

Protocolo `2.0`. O array exportado continua sendo a lista de execuções; cada linha traz os campos antigos e os novos. Uma sessão incompleta fica em Application Support (`session.json`) e o app oferece continuar. Energia por tarefa não é calculada: o iOS não entrega joules, e a variação de bateria não entra como energia. O intervalo `task` do `OSSignposter` segue disponível para o Power Profiler.

Não some os tempos abaixo. Cada um cobre um intervalo diferente:

| Campo | O que mede |
| --- | --- |
| `modelLoadMs` | Carga ou download. Fica de fora de `totalLatencyMs`. |
| `thermalWaitMs` | Espera ociosa pela térmica. Fica de fora da latência e do intervalo `task`. |
| `prefillLatencyMs` | `promptTime` do primeiro turno de ação no MLX. Não inclui o plano. |
| `repeatedPrefillMs` | `promptTime` dos turnos de ação seguintes. Budget e early-exit reprocessam o prefixo; esse custo não entra em `prefillLatencyMs` nem em `decodeLatencyMs`. |
| `decodeLatencyMs` | Soma de `generateTime` dos turnos de ação. |
| `planLatencyMs` | Relógio de parede só do plano. |
| `toolExecutionMs` | Soma do corpo das tools. |
| `inferenceMs` / `timeToFirstToolCallMs` | Do modelo já residente até a primeira tool. |
| `totalLatencyMs` | Relógio de parede da tentativa, sem carga e sem espera térmica. |
| `totalMs` | O mesmo intervalo mais a carga. É o total do protocolo 1. |

Valor ausente fica `null`. A amostragem é gulosa (`temperature` 0). O seed gravado só reproduz a ordem da matriz; no MLX 3.31.4 ele não muda os tokens do argmax. A matriz embaralha as repetições, pode aquecer uma vez fora da análise e, se a opção estiver ligada, espera no máximo 180 s por térmica `nominal` ou `fair` antes de pular a tentativa.

## Fase 2 — ferramentas, simulação e trajetórias

O aquecimento da matriz é sempre simulado: o modelo carrega, mas as nove ferramentas não abrem Telefone, Mail, Calendário, Mapas nem Safari. A matriz legado pode ser real ou simulada. Os datasets Apple (150 tarefas: 40 de uma ferramenta, 40 independentes, 50 sequenciais, 20 ambíguas) e o subconjunto BFCL (20 tarefas, cinco em cada categoria `simple`, `multiple`, `parallel` e `parallel_multiple`) rodam só no modo simulado. Cada tarefa Apple tem fixtures próprias. O avaliador de trajetória confere seleção, argumentos, dependências, ordem e estado final por regras, sem outro modelo. `parallel` do BFCL não exige ordem fixa. O checker local usa a allow-list do `possible_answer` e trata `""` como argumento opcional; não é o `ast_checker` Python. O Apple Foundation Models não recebe o BFCL, porque as ferramentas daquele backend são estáticas.

## Energia no iPhone

O iOS não expõe potência para o app. Cada execução abre um intervalo `task` em Points of Interest (`OSSignposter`, subsystem `MobileLLMBench`), com modelo, estratégia e tarefa no rótulo. Para energia por tarefa:

1. Grave um trace com o template **Power Profiler** do Instruments enquanto a matriz roda, com o instrumento **Points of Interest** junto.
2. Selecione cada intervalo `task` e anote a energia do intervalo.
3. Energia por token = energia do intervalo ÷ `outputTokens` da mesma execução no JSON.

Essa parte é manual: nenhum script lê o trace.

O MVP Android continua em [AndroidLLMBench](AndroidLLMBench/README.md).
