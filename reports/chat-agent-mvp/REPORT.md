# MobileLLMBench — MVP de chat agêntico

Data: 2026-10-19 · iPhone 16 Pro (iOS 26.6.2) · Xcode 27

## Resultado

O critério de sucesso foi atingido no iPhone: uma solicitação livre leva o LLM local (Apple Foundation Model) a decidir pela ferramenta. A ação é confirmada, o EventKit real a executa e a resposta se baseia na releitura do que foi gravado. Isso está coberto por testes automatizados no aparelho contra uma agenda e lista descartáveis.

O fluxo pela interface (tocar em "Confirmar" no cartão) **não** foi exercitado por teste automatizado. Ele usa o mesmo `ToolGate`, mas falta validar manualmente no app (ver "Pendências").

O benchmark de 360 tarefas continua intacto: abas Executar, Ao vivo e Resultados sem mudanças funcionais. O app hospeda os testes, então `BenchmarkRunner.init` roda todos os `selfCheck` (incluindo `precondition(crossPlan.measured == 360)`) antes de cada execução da suíte, e todas passaram.

## Arquitetura

```
ChatView ──► ChatStore (@Observable: conversas, streaming, confirmação, métricas)
                │
                ▼
        AgentCoordinator ── InferencePolicy (FixedPolicy = direct)
          │  Apple: LanguageModelSession + FoundationModels.Tool
          │  MLX:   MLXPhoneBackend.chatTurn (Qwen3-1.7B / Gemma-4-e2b), até 4 rodadas
          ▼
        ToolGate  (toda chamada passa aqui, venha de qual backend vier)
          resolve → validação → resumo resolvido → anti-duplicata → confirmação → ToolRuntime.execute
          ▼
        ChatToolCatalog: consultarCompromissos, criarLembrete
          ▼
        CalendarStore: EventKitCalendarStore (real) | SimulatedCalendarStore (testes)
```

- **Reutilizado do harness:** `AgentTool`, `ToolRuntime.execute` (validação, execução e `ToolLog`), `ToolValue`/`ToolParameter`, `MLXPhoneBackend` (o mesmo modelo carregado é compartilhado com o benchmark), `AdaptiveRouteDecision`, `DeviceMetrics` e `BenchError`.
- **Chamadas estruturadas:** no Apple, via `@Generable Arguments`; no MLX, via `ToolCall` do mlx-swift-lm. Nada é extraído de texto livre.
- **Coordenador sem gabarito:** não conhece o gabarito do benchmark. As regras do sistema são 5 linhas genéricas (`AgentCoordinator.rules`).
- **Garantias do `ToolGate`:**
  - **Ferramenta desconhecida, argumento inválido ou horário no passado:** devolve `ERRO…` ao modelo e não executa nada.
  - **Confirmação:** obrigatória para efeitos colaterais. Mostra o resumo já resolvido, com data absoluta (“Criar lembrete “Revisar TCC” para 2026-10-20 09:00”).
  - **Anti-duplicata:** a chave é o resumo resolvido. Uma ação já executada devolve `JÁ EXECUTADO`; uma recusada devolve `CANCELADO` e não pergunta de novo.
  - **Falha transitória:** a tentativa se repete uma única vez, sem nova confirmação. Isso só acontece quando o store garante que nada foi gravado (`ChatToolError.notWritten`). Depois de duas falhas, a mesma ação fica bloqueada.
  - **Permissão negada:** devolve `SEM PERMISSÃO` e o modelo não tenta de novo.
  - **Limites:** 6 chamadas por tarefa; a partir de 8, a tarefa é abortada (`runaway`).
  - **Stop:** cancela a tarefa e nega a confirmação pendente.
- **Métricas** (`ChatMetricsRecord`, em `ApplicationSupport/ChatMetrics/metrics.json`), sem nenhum conteúdo da conversa:
  - tempos: carga do modelo, TTFT, geração, seleção da ferramenta, execução, espera pela confirmação, total e total sem a confirmação;
  - tokens (com a origem da contagem) e memória/térmica antes e depois;
  - política (`fixed_direct`) e sequência de ações.

  As conversas ficam em outro arquivo (`ApplicationSupport/Chat/conversations.json`), com `.completeFileProtection`.
- **Roteador futuro:** `protocol InferencePolicy { decide(prompt:agent:) -> AdaptiveRouteDecision }`. Hoje existe só `FixedPolicy` (direct, a melhor política fixa nos três modelos em `reports/adaptive-routing/REPORT.md`). O chat executa apenas direct.

## Arquivos

**Novos** (em `MobileLLMBench/`):

| Arquivo | Conteúdo |
|---|---|
| `ChatTools.swift` | Ferramentas, stores real e simulado, datas relativas, sandbox E2E |
| `AgentCoordinator.swift` | `ToolGate`, coordenador Apple/MLX, política, métricas |
| `ChatStore.swift` | Estado, persistência, confirmação |
| `ChatView.swift` | Interface, com `accessibilityIdentifier` em entrada, envio, confirmação e passos |

**Testes** (em `MobileLLMBenchTests/`):

| Arquivo | Conteúdo |
|---|---|
| `ToolGateTests.swift` | Testes determinísticos |
| `ChatAgentE2ETests.swift` | E2E com LLM: simulado, EventKit real e MLX |

**Alterados:**

- `ContentView.swift`: aba Chat, a primeira; as abas do benchmark foram mantidas.
- `BenchmarkRunner.swift`: `mlx` deixou de ser `private`.
- `MLXPhoneBackend.swift`: ganhou `ChatLine` e `chatTurn`.
- `MobileLLMBench.xcodeproj`: alvo `MobileLLMBenchTests` (hospedado no app) e scheme compartilhado.

## O que foi validado e como

Existem três níveis, e eles não se confundem:

- **Determinístico:** sem LLM, com o `ToolGate` e o store simulado.
- **LLM + simulado:** LLM real no iPhone, com a agenda em memória.
- **LLM + EventKit real:** LLM real no iPhone, com o Calendário e os Lembretes reais restritos à agenda e à lista descartáveis `MobileLLMBench E2E`, criadas no `setUp` e apagadas no `tearDown`. Nenhum dado pessoal foi lido nem alterado.

Todos rodaram **no iPhone** via `xcodebuild test`. A suíte completa (15 determinísticos, 9 LLM + simulado e 4 LLM + EventKit real, com Apple FM) passou **28/28 em 3 execuções seguidas** (a decodificação é gulosa).

| Cenário | Determinístico | LLM + simulado | LLM + EventKit real | O que se verifica além do texto |
|---|---|---|---|---|
| 1 Conversa com contexto | — | ✅ | — | Sem ferramenta; o segundo turno usa o primeiro |
| 2 Lembrete amanhã 9h | ✅ | ✅ | ✅ | `criarLembrete` ok, 1 confirmação, lembrete lido de volta às 09:00 |
| 3 Compromissos de amanhã | ✅ | ✅ | ✅ | `consultarCompromissos(data=amanhã)`; a resposta cita o evento de amanhã e não o de depois |
| 4 Próximo compromisso − 30 min | ✅ | ✅ | ✅ | Consulta seguida de criação; lembrete às 09:30 para o evento das 10:00 |
| 5 Pedido ambíguo | — | ✅ | — | Nenhuma ferramenta; o modelo pergunta |
| 6 Permissão negada (Calendário e Lembretes) | ✅ | ✅ | — ¹ | `permission_denied`; a resposta diz isso |
| 7 Cancelamento | ✅ | ✅ | ✅ | `cancelled`; 0 lembretes gravados |
| 8 Falha e recuperação sem duplicar | ✅ | ✅ | — ¹ | `failed` e depois `ok`; 1 lembrete, 2 tentativas, 1 confirmação |
| 8b Falha persistente | ✅ | ✅ | — ¹ | 2 tentativas no máximo; nada gravado; o modelo relata a falha |
| Limite, ferramenta desconhecida, argumento inválido, horário passado, métricas sem conteúdo, `<think>` oculto | ✅ | — | — | |

¹ Negar permissão ou forçar uma falha de escrita no EventKit real exige mexer em Ajustes, então esses cenários só são cobertos no simulado.

**MLX no chat** (LLM + simulado, iPhone, cenários 2, 3 e 4):

- **Qwen3-1.7B:** passa nos três. No 4, criou o lembrete certo (09:30) mas seguiu chamando `criarLembrete`. O anti-duplicata barrou as duas repetições (1 lembrete gravado) e o limite de 4 rodadas encerrou o turno com uma mensagem de fallback em vez de uma resposta final.
- **Gemma-4-e2b:** consulta a agenda corretamente, mas no 2 enviou argumentos inválidos e desistiu, e no 4 pediu esclarecimento depois da consulta. **Não validado** para escrita.

## Métricas (iPhone, execução 3 da suíte completa)

| Caminho | Total sem confirmação | TTFT | Seleção da ferramenta | Execução da ferramenta | Tokens entrada/saída | Memória |
|---|---|---|---|---|---|---|
| Apple FM + simulado | 1,2–4,2 s | 0,7–3,3 s | 0,8–2,0 s | < 1 ms | 600–880 / 15–67 | 57–85 MB |
| Apple FM + EventKit real | 2,6–4,6 s | 2,2–3,5 s | 1,2–1,4 s | 2–35 ms | 706–853 / 29–62 | 58–72 MB |
| Qwen3-1.7B (MLX) + simulado | 9–50 s | 8–15 s | 4,7–5,2 s | < 1 ms | 1500–3800 / 83–843 | ~1,5 GB |
| Gemma-4-e2b (MLX) + simulado | 9–10 s | ~8,8 s | 7,5–8,0 s | < 1 ms | ~1200 / 24–36 | ~3,0 GB |

- **Leitura dos tempos:**
  - "Seleção da ferramenta" vai do envio até a primeira chamada.
  - No Apple, o TTFT inclui a rodada de ferramenta, porque o primeiro texto só sai depois dela.
  - A escrita real custa 29–35 ms, já com a releitura de verificação.
- **Tokens:** no iOS 26, `session.usage` não existe. Os tokens do Apple FM são uma estimativa de `SystemLanguageModel.tokenCount(for: transcript)` (`tokenSource = tokenCount_transcript`). No MLX, a contagem é exata.
- **Carga do modelo:** o tempo de carga do modelo MLX é registrado no `ChatMetricsRecord`, mas não foi impresso nesta bateria.

## Falhas encontradas e decisões

1. **Variantes de prompt (A–E), Apple FM.** O contexto de data no prompt do usuário (A, E) fazia o modelo não criar o lembrete. Na instrução de sistema (B, C), a cadeia funcionava. A variante C (regras curtas e a ferramenta de lembrete listada primeiro) foi a única que também criou o lembrete das 9h; a D (consulta primeiro) errou o horário da cadeia. Adotei a C.
2. **"Amanhã" virava um intervalo de 2 dias** com `dataInicio`/`dataFim`, porque o modelo trata o fim ora como inclusivo, ora como exclusivo. O esquema mudou para `data` + `dias`.
3. **"30 minutos antes"** foi a falha mais teimosa, e só apareceu no EventKit real. Medi três esquemas:

   | Esquema | O que o modelo fazia | Resultado |
   |---|---|---|
   | `hora` + `minutosAntes` | passava `hora=09:30` *e* `minutosAntes=30` | a ferramenta subtraía de novo: 09:00 |
   | só `hora` (o modelo faz a conta) | somava em vez de subtrair, conforme o título do evento | 10:30 |
   | campo separado `horaDoCompromisso` | parava depois da consulta | regrediu também o cenário 6 |

   Mudar a descrição dos campos piorou os resultados. A solução ficou no código: `hora` + `minutosAntes`, mais um passo `resolve` no `ToolGate` (`ChatToolCatalog.anchorToEvent`). Se nenhum evento começa em `hora` e algum começa em `hora + minutosAntes`, o modelo já subtraiu, e `hora` volta ao início do evento. Como o `resolve` roda antes da confirmação, o usuário vê o horário final correto, e a chave anti-duplicata também usa esse horário. Isso é uma heurística, marcada com `ponytail:`. Ela erraria se o usuário quisesse de fato "X min antes" de um horário que já fica X min antes de um evento.
4. **Leitura extra:** o Apple FM costuma chamar `consultarCompromissos` antes de criar um lembrete simples. É inofensivo (não tem efeito colateral), custa cerca de 1 s e os testes aceitam.
5. **O modelo não tentava de novo** depois de uma falha (cenário 8). Por isso a nova tentativa ficou no gate e não no modelo, e só quando a falha garante que nada foi gravado.
6. **MLX sem `enable_thinking: false`:** o Qwen3 gastava os 512 tokens pensando e devolvia texto vazio. Agora o chat usa o mesmo ajuste da estratégia direct do benchmark.
7. **Certificado de desenvolvedor:** em uma execução, o iPhone recusou o certificado ("not trusted"). Na tentativa seguinte, voltou a funcionar.

## Pendências e próximos passos

- **Validação manual na interface (recomendado antes de declarar o fluxo visual validado):**
  1. No app, aba Chat, use o modo Real (painel de desenvolvimento).
  2. Envie "Crie um lembrete para amanhã às 9h para revisar o TCC.", confira o cartão e toque em Confirmar.
  3. Confira o lembrete no app Lembretes. **Isso grava na lista padrão real**, e o teste automatizado não o faz por esse motivo.
- **XCUITest:** os identificadores de acessibilidade já existem. Falta o alvo de UI test, que deveria rodar só no modo simulado.
- **MLX:** reduzir as rodadas repetidas do Qwen depois de `JÁ EXECUTADO` (por exemplo, encerrar o turno quando todas as chamadas de uma rodada forem duplicatas) e investigar os argumentos inválidos do Gemma.
- **Roteador adaptativo:** implementar `InferencePolicy` com o roteador do TCC e fazer o coordenador executar `plan`/`think`, além de direct.
- **Métricas:** imprimir `modelLoadMs` nos E2E e medir a primeira carga a frio dos modelos MLX.
