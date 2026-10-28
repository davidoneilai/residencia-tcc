# Piloto de chat agêntico e roteamento adaptativo

Data: 2026-10-19 · iPhone (iOS 26.6.2) · Xcode 27 · Apple Foundation Model + store **simulado**

## Resultado em uma frase

As correções 1–2 passaram em **34/34** testes de regressão no iPhone (gate, Apple E2E, EventKit real, Qwen, Gemma diagnóstico). O piloto com **40 tarefas × 3 políticas** (120 corridas) no Apple FM mostra complementaridade `direct`/`plan_act`, oracle com ~90% de sucesso (reavaliação) e ganho potencial de latência vs a melhor fixa.

## 1–2. Correções implementadas (confirmadas no iPhone)

### Tempo determinístico

- Removida a heurística `anchorToEvent` / `ponytail:`.
- **Modo absoluto:** `titulo` + `data`/`hora` (horário de relógio).
- **Modo relativo:** `titulo` + `evento` (#N estável no turno) + `minutosAntes`; Swift subtrai do início do evento.
- Mistura de modos → `ERRO DE ARGUMENTO`.
- `EventRegistry`: numeração monotônica no turno; novas consultas não renumeram; antes da escrita, `stillPresent` revalida título+início no store.
- Confirmação mostra o horário já calculado.

### Ciclo agêntico

- Cache de consultas idênticas (`REUTILIZADO`); na 2ª repetição → `SEM PROGRESSO` + `stalled` (coordenador encerra).
- **Uma escrita `.ok` por turno** (`LIMITE DE ESCRITA`).
- MLX: após escrita verificada (ou stall), **rodada final sem tools**; se o modelo emite tool calls ou texto vazio, usa fallback fundamentado no output da ferramenta.
- Qwen: cadeia e lembrete passam sem depender do bloqueador de duplicatas para “concluir”.

### Validação no aparelho (regressão)

| Suite | Resultado |
|---|---|
| ToolGateTests (19) | 0 falhas |
| ChatAgentE2ETests Apple simulado (9) | 0 falhas |
| RealEventKitE2ETests (4) | 0 falhas |
| MLXChatE2ETests Qwen (3 cenários) | **passou** (incl. cadeia relativa `#evento` + resposta final) |
| MLXChatE2ETests Gemma | lembrete absoluto e consulta OK; **cadeia ainda falha por orquestração** (pede esclarecimento sem chamar tools) — registrado, sem fine-tune |

## 3. Diagnóstico Gemma-4-E2B

| Cenário | Observação | Classe de falha |
|---|---|---|
| Lembrete absoluto | `criarLembrete(data,hora)` correto + resposta final | OK (geração estruturada) |
| Consulta | Chama a tool; às vezes texto vazio (mitigado pelo fallback fundamentado) | Orquestração / geração de texto |
| Cadeia “30 min antes” | Não chama tools; pergunta qual compromisso | **Seleção / orquestração**, não schema |

Não houve mudança extensiva de backend nesta etapa.

## 4. Benchmark de chat (40 tarefas)

Arquivo: `MobileLLMBenchTests/ChatBenchSuite.swift` (separado do 360).

Categorias: noTool (6), singleQuery (8), singleReminder (8), sequential (8), ambiguous (6), confirmCancel (2), recovery (2).

Critérios objetivos (não só texto): ordem de tools (subsequência), ≤1 escrita ok, horário do lembrete, confirmação, cancelamento, recuperação.

Dados brutos: `results.jsonl` (120 linhas).

## 5. Piloto Direct vs Plan+Act (+ heurística)

- **Modelo fixo:** Apple Foundation Model (sem troca de modelo).
- **Políticas:** `fixed_direct`, `fixed_plan_act` (plano curto sem tools + ação), `heuristic_chat` (features do prompt apenas).
- Store simulado; confirmações auto-aprovadas exceto `confirmCancel`.
- Duração: ~520 s.

### Matriz agregada (sucesso / latência total sem confirmação)

| Política | Sucesso (scorer original) | Sucesso (reavaliação*) | Latência total | Média/tarefa |
|---|---|---|---|---|
| fixed_direct | 29/40 (72.5%) | **32/40 (80%)** | 132,9 s | 3,3 s |
| fixed_plan_act | 30/40 (75%) | **34/40 (85%)** | 240,2 s | 6,0 s |
| heuristic_chat | 29/40 (72.5%) | **32/40 (80%)** | 146,0 s | 3,7 s |
| oracle (menor latência entre políticas corretas) | 32/40 (80%) | **36/40 (90%)** | ~155–164 s | — |

\*Reavaliação: `confirmCancel` usa `steps` (cancelamento não entra no ToolLog); `recovery` exige escrita `.ok` (o scorer original exigia horário exato e penalizava cancelamentos). O scorer em código foi corrigido para as próximas corridas; os números com \* são a leitura metodologicamente correta deste piloto.

Melhor fixa por sucesso: **plan_act (85%)**. Melhor fixa por latência com sucesso alto: **direct (80%, ~45% menos latência que plan_act)**.

Ganho potencial de latência do oracle vs fixed_plan_act: **~85 s** no conjunto (~35% da latência da melhor fixa por sucesso).

Complementaridade direct/plan (sucesso original): only_direct=2, only_plan=3, both=27, neither=8.

### Por categoria (scorer original)

| Categoria | direct | plan_act | heurística |
|---|---|---|---|
| noTool | 100% | 100% | 100% |
| singleQuery | 100% | 100% | 100% |
| sequential | 100% | 100% | 100% |
| ambiguous | 83% | 67% | 83% |
| singleReminder | 25% | 50% | 25% |
| confirmCancel / recovery | 0%* | 0%* | 0%* |

\*Falsos negativos do scorer original; na reavaliação, cancel/recovery sobem (direct ~+3, plan ~+4).

**singleReminder** continua o gargalo real: o modelo às vezes só consulta, ou grava horário errado. plan_act ajuda um pouco (50% vs 25%).

### Heurística

`ChatHeuristicPolicy`: sequencial/longo → plan_act; ambíguo/curto → direct. Overhead de decisão &lt; 1 ms (medido em `routerDecisionMs`). No Apple, sucesso igual ao direct e latência um pouco maior (escolhe plan em sequenciais). **Não** foi treinado um classificador neste conjunto (evita vazamento train=eval).

## Limitações

- Piloto só Apple FM + simulado (não EventKit real, não Qwen/Gemma na matriz 40×3).
- Uma repetição por célula (sem IC).
- plan_act no chat é um rascunho curto sem tools; não é o mesmo grafo do benchmark de 360.
- Heurística do `AdaptiveRouter` legado força direct em Apple; a do chat é independente.
- Volume (40) insuficiente para treinar roteador aprendido com hold-out honesto.

## Próximos experimentos

1. Reexecutar o piloto com o scorer corrigido e 2–3 seeds.
2. Aumentar para ~100 tarefas chat; split por família de template.
3. Incluir Qwen só no subconjunto sequencial+reminder (custo alto).
4. Features de chat (lembrete absoluto vs relativo) no roteador.
5. XCUITest do cartão de confirmação.

## Arquivos tocados

- `ChatTools.swift` — modos absoluto/relativo, `EventRegistry`, local opcional
- `AgentCoordinator.swift` — cache/stall, limite de escrita, final MLX, `planAct`, `ChatHeuristicPolicy`
- `ChatView.swift` — status `reused`/`stalled`/`writeLimit`
- `ChatStore.swift` — registry compartilhado
- Testes: `ToolGateTests`, `ChatAgentE2ETests`, `ChatBenchSuite.swift`
