# SLMs agênticos no iPhone 16 Pro: BFCL v4 AST

Inferência 100% on-device (iPhone 16 Pro, A18 Pro, 8 GB, iOS 26.6.2) com MLX Swift / `mlx-swift-lm` 3.31.4, sem atualizar dependências. Avaliação com o `ast_checker` oficial (`bfcl-eval` 2026.3.23) no Mac. Geração greedy (temperature 0), uma sessão por modelo, com warmup e ordem embaralhada por seed fixa.

## Resposta curta

1. **Melhor SLM em tool calling:** Qwen3.5-2B com Direct (thinking ligado), 35/40 (88%). O MiniCPM5-2B com NoThink chega a 34/40 (85%) em **7,5 s por tarefa, 2,8× mais rápido**. A diferença de 1 tarefa não é significativa. No custo-benefício, o MiniCPM5 + NoThink é o melhor ponto.
2. **Estratégias que aceleram sem perder acurácia:**
   - MiniCPM5 e Gemma 4: desligar o thinking (NoThink) é **mais rápido e mais preciso** que Direct (−34,6 s e −24,3 s por tarefa).
   - LFM2.5: o roteador AST mantém 33/40 com −2,8 s (IC95% [−5,0; −1,0]).
   - Qwen3.5: nenhuma estratégia mais rápida mantém a acurácia. NoThink perde 20 pp e Budget64 perde 12,5 pp.
   - Plan+Act piorou ou não ajudou em todos os modelos, além de ser a mais lenta.
3. **As adaptativas superam a melhor fixa? Não.** Nenhuma política adaptativa superou a melhor fixa em acurácia em nenhum modelo (Δ entre −20 e 0 pp). O único ganho foi de latência no LFM2.5, sem perda (roteador AST). Resultado negativo registrado.
4. **Complementaridade:**
   - Dentro de cada modelo, ela existe mas é pequena. O Oracle entre fixas ganha +1 a +4 tarefas sobre a melhor fixa (36–38/40).
   - Entre modelos, a melhor fixa de cada resolve 25 tarefas em comum e 38 na união. Só uma tarefa é exclusiva de um modelo.
   - A melhor estratégia muda com a arquitetura: NoThink no MiniCPM5 e no Gemma 4, Direct no Qwen3.5 e no LFM2.5. Essa é a complementaridade que se mantém.
5. **Justifica treinar um controlador (SFT/RL)? Ainda não, com esta evidência.**
   - O teto do Oracle é de 1 a 4 tarefas em 40 por modelo, ou seja, 2,5–10 pp. Isso está dentro do ruído de uma amostra de 40.
   - Uma regra fixa por modelo ("NoThink se o modelo aceita, salvo no Qwen3.5") captura quase todo o ganho.
   - Antes de treinar, é preciso uma amostra maior, separada da avaliação, para confirmar se esse teto é real.

## Modelos e compatibilidade

| Modelo | Checkpoint (revisão fixa) | `model_type` | Parser de tools | Thinking | Pico mem. |
|---|---|---|---|---|---|
| MiniCPM5-2B | `openbmb/MiniCPM5-2B-MLX@8a9ad75` | `llama` | **nativo lido no Mac** | `enable_thinking` on/off | 1,8 GB |
| LFM2.5-2.6B | `LiquidAI/LFM2.5-2.6B-MLX-4bit@04efa23` | `lfm2` | **nativo lido no Mac** | sempre ligado | 2,1 GB |
| Gemma 4 E2B | `mlx-community/gemma-4-e2b-it-4bit@2387675` | `gemma4` | `gemma4` (pacote) | `enable_thinking` on/off | 3,1 GB |
| Qwen3.5-2B | `mlx-community/Qwen3.5-2B-4bit@674aaa7` | `qwen3_5` | `xmlFunction` (pacote) | `enable_thinking` on/off (padrão off) | 2,6 GB |

Incompatibilidades encontradas, nenhuma contornada por troca de modelo ou versão:

- **MiniCPM5:** declara `llama`, e o `infer` do pacote escolheria o parser `llama3`. O formato nativo `<function name="…"><param name="…">` não tem parser no `mlx-swift-lm`. O app grava o texto e o Mac decodifica.
- **LFM2.5:** o `PythonicToolCallParser` do pacote lê só a **primeira** chamada de `[f(..), g(..)]` e rejeita nomes com ponto (`math.factorial`). No smoke, isso derrubava o Direct de 4/5 para 1/5. O texto nativo passa a ser decodificado com `ast` no Mac.
- **LFM2.5 não tem modo sem thinking.** NoThink e AdaptiveStep ficam **não aplicáveis**, sem simulação.
- **Gemma 4 (3,5 GB de pesos com torres de áudio e visão):** o app era encerrado pelo iOS perto de 3 GB. Foi resolvido com o entitlement `com.apple.developer.kernel.increased-memory-limit`.
- **Prefix KV-cache não aplicável** neste benchmark:
  - Cada tarefa AST tem catálogo próprio e um único prefill, então não há prefixo reaproveitável.
  - Qwen3.5 e LFM2.5 usam `MambaCache` (não truncável) e Gemma 4 usa `RotatingKVCache`.
  - O cache ficou desligado em todas as condições, de forma consistente.

## Protocolo

- **Amostra congelada antes da execução** (`selection.json`, `analysis/slm_bfcl/freeze_sample.py`):
  - 8 IDs por categoria (`simple_python`, `multiple`, `parallel`, `parallel_multiple`, `irrelevance`), seed 20261027.
  - Os dados oficiais, com SHA-256 registrado, são os do pacote `bfcl-eval`.
  - Foram excluídos os 40 IDs já usados nos testes anteriores (os 10 primeiros de cada categoria). O gold não foi alterado.
- **Fidelidade ao BFCL:**
  - Turno único, como no handler OSS-FC oficial. A função BFCL vai crua ao chat template nativo do modelo.
  - Não há system prompt do harness nem execução de ferramenta. Vale a primeira resposta do modelo.
  - Em `irrelevance`, o acerto é não chamar nenhuma função (regra de `relevance_file_runner`).
- **Normalização igual para os quatro modelos** (`evaluate.py`):
  - Chamadas nativas do parser MLX, ou do texto no formato nativo (MiniCPM5 e LFM2.5).
  - Valores string de parâmetros não-string são decodificados como JSON ou literal Python, como o parser XML do Qwen3.5 já faz.
- **Estratégias:**
  - Direct: thinking ligado quando o template permite.
  - NoThink: `enable_thinking=false`.
  - Budget64: s1 com o marcador nativo, `</think>` ou `<channel|>` no Gemma.
  - Plan+Act: plano de 128 tokens sem thinking, depois ação no modo Direct.
  - Teto de 1024 tokens de saída por resposta em todas.
- **Adaptativas:**
  - O **roteador heurístico antigo** (`AdaptiveRouter`) não foi rodado. Ele devolve `direct` para todo modelo que não é Qwen3 e usa pistas das ferramentas Apple, então seria idêntico ao Direct.
  - O **roteador AST** é uma regra fixada antes da execução, sem olhar resultados: ≥2 funções ou pistas de pedido múltiplo levam a Direct; caso contrário, à política rápida (NoThink, ou Budget64 sem switch).
  - **AdaptiveStep** é o controlador existente, sem mudanças, na rodada 0: fast leva a NoThink e slow a Budget64.
  - **ActionAware** não foi rodado. É recuperação entre chamadas e não tem significado em AST de turno único (fica para o ToolSandbox).
- **Térmica:** o iPhone carrega pelo cabo durante o teste e ficou em `serious` em 880 de 880 jobs. Por decisão do protocolo, não há espera térmica; o estado é só registrado. As latências valem para o **aparelho quente e carregando**, que é o regime de uso sustentado.

## Tabela principal (repetição 1, 40 tarefas, checker oficial)

| Modelo | Estratégia | Acurácia | Latência média (s) | Prefill (s) | Decode (s) | Tokens in/out |
|---|---|---|---|---|---|---|
| **Qwen3.5-2B** | **direct** | **35/40 (88%)** | 21,2 | 3,3 | 17,9 | 459/342 |
| Qwen3.5-2B | plan_act | 28/40 (70%) | 30,4 | 3,8 | 19,2 | 1033/454 |
| Qwen3.5-2B | nothink | 27/40 (68%) | 17,7 | 3,2 | 14,5 | 461/291 |
| Qwen3.5-2B | budget_64 | 30/40 (75%) | 15,9 | 3,3 | 8,5 | 459/196 |
| Qwen3.5-2B | ast_router | 33/40 (82%) | 18,5 | 3,4 | 15,0 | 459/289 |
| Qwen3.5-2B | adaptive_step | 27/40 (68%) | 17,1 | 3,3 | 13,2 | 460/264 |
| MiniCPM5-2B | direct | 31/40 (78%) | 42,2 | 4,0 | 38,2 | 395/565 |
| MiniCPM5-2B | plan_act | 33/40 (82%) | 48,6 | 4,4 | 35,5 | 904/603 |
| **MiniCPM5-2B** | **nothink** | **34/40 (85%)** | **7,5** | 4,0 | 3,5 | 397/65 |
| MiniCPM5-2B | budget_64 | 29/40 (72%) | 14,8 | 4,0 | 6,5 | 395/118 |
| MiniCPM5-2B | ast_router | 31/40 (78%) | 30,0 | 3,9 | 26,0 | 395/389 |
| MiniCPM5-2B | adaptive_step | 34/40 (85%) | 8,7 | 4,1 | 4,0 | 396/72 |
| **LFM2.5-2.6B** | **direct** | **33/40 (82%)** | 16,2 | 2,8 | 13,4 | 264/249 |
| LFM2.5-2.6B | plan_act | 20/40 (50%) | 39,2 | 3,8 | 26,0 | 692/606 |
| LFM2.5-2.6B | budget_64 | 29/40 (72%) | 12,4 | 2,8 | 5,9 | 264/136 |
| LFM2.5-2.6B | ast_router | 33/40 (82%) | 13,4 | 2,8 | 9,8 | 264/193 |
| Gemma 4 E2B | direct | 28/40 (70%) | 37,9 | 1,7 | 26,3 | 245/437 |
| Gemma 4 E2B | plan_act | 25/40 (62%) | 45,4 | 3,0 | 25,2 | 623/532 |
| **Gemma 4 E2B** | **nothink** | **31/40 (78%)** | 13,6 | 1,7 | 5,1 | 243/92 |
| Gemma 4 E2B | budget_64 | 25/40 (62%) | 24,7 | 1,8 | 10,4 | 245/188 |
| Gemma 4 E2B | ast_router | 29/40 (72%) | 29,7 | 1,8 | 20,5 | 245/355 |
| Gemma 4 E2B | adaptive_step | 31/40 (78%) | 17,6 | 1,6 | 5,5 | 243/101 |

A latência média inclui o tempo de prefill, de decode e o overhead do app. O Plan+Act soma o turno do plano. Falhas por categoria, por tipo (argumento inválido, chamada ausente, formato, função errada, chamada em `irrelevance`) e os ICs estão em `tables-r1.md`.

## Adaptativas × melhor fixa (pareado por tarefa, IC95% bootstrap)

| Modelo | Melhor fixa | Política | Δ acurácia | Δ latência | Decisões |
|---|---|---|---|---|---|
| LFM2.5 | direct | ast_router | +0,0 pp [−7,5; +7,5] | **−2,8 s [−5,0; −1,0]** | direct 29, budget_64 11 |
| MiniCPM5 | nothink | adaptive_step | +0,0 pp | +1,2 s [+0,3; +2,2] | nothink 35, budget_64 5 |
| MiniCPM5 | nothink | ast_router | −7,5 pp [−17,5; +2,5] | +22,4 s | direct 29, nothink 11 |
| Qwen3.5 | direct | ast_router | −5,0 pp [−12,5; 0,0] | −2,8 s [−7,1; +1,6] | direct 29, nothink 11 |
| Qwen3.5 | direct | adaptive_step | **−20,0 pp [−32,5; −7,5]** | −4,1 s | nothink 35, budget_64 5 |
| Gemma 4 | nothink | adaptive_step | +0,0 pp | +4,0 s [+1,0; +7,0] | nothink 35, budget_64 5 |
| Gemma 4 | nothink | ast_router | −5,0 pp [−17,5; +7,5] | +16,0 s | direct 29, nothink 11 |

O roteador AST e o AdaptiveStep tomam as mesmas decisões em todos os modelos, porque dependem só do prompt. O resultado de cada um depende de qual política fixa é a melhor naquele modelo.

## Oracle retrospectivo (limite superior; não é uma política executável)

| Modelo | Melhor fixa | Oracle entre fixas | Ganho possível |
|---|---|---|---|
| LFM2.5 | 33/40 | 37/40 | +4 |
| MiniCPM5 | 34/40 | 38/40 | +4 |
| Qwen3.5 | 35/40 | 36/40 | +1 |
| Gemma 4 | 31/40 | 34/40 | +3 |

Somar as adaptativas ao Oracle não acrescenta nenhuma tarefa. Entre modelos, a melhor fixa de cada um dá 38/40 na união e 25/40 na interseção. Duas tarefas nenhum modelo resolve.

## Estabilidade (repetição 2, nova ordem)

Greedy + temperature 0. A repetição usa seed `r2-20261027` (ordem diferente da r1).

| Modelo | Estratégia | r1 | r2 | Concordância tarefa a tarefa | Latência r1 → r2 |
|---|---|---|---|---|---|
| MiniCPM5-2B | nothink | 34/40 | 34/40 | **40/40** | 7,5 s → 6,0 s |
| MiniCPM5-2B | adaptive_step | 34/40 | 34/40 | **40/40** | 8,7 s → 6,9 s |

No MiniCPM5 a acurácia é determinística nesta amostra: nenhuma tarefa mudou de certo para errado, nem o contrário. A latência caiu ~20% na r2 (aparelho mais frio no início da noite); o ranking NoThink ≈ AdaptiveStep se mantém.

Gemma 4, Qwen3.5 e LFM2.5 da r2 ainda não fecharam: o iPhone bloqueou a tela após o MiniCPM5 na noite de 27/10. A sessão do Gemma 4 r2 foi relançada em 28/10 ~8h40 e estava em andamento no aparelho.

## Limitações

- **n = 40 por condição.** Diferenças abaixo de ~10 pp não são distinguíveis (ver ICs).
- **Latências com o aparelho em `serious`**, sem controle térmico. Comparações dentro do mesmo modelo foram feitas na mesma sessão e com ordem embaralhada.
- **MiniCPM5 e LFM2.5 dependem do parser do Mac** para o formato nativo, porque o pacote não oferece um. No app de produção, isso exigiria um parser Swift equivalente.
- **ToolSandbox:** a integração ainda não foi feita. Ele depende de um orquestrador Python com simulador de usuário (LLM) e estado das ferramentas em Python. Para ser fiel, o iPhone teria de atender como servidor de inferência para o orquestrador no Mac, com o avaliador oficial inalterado. É a próxima etapa, e só nela o ActionAware tem significado.

## Reprodutibilidade

- **Amostra:** `analysis/slm_bfcl/freeze_sample.py` → `reports/slm-bfcl/selection.json`, `MobileLLMBench/BFCLv4AST.json`
- **Execução:** `analysis/slm_bfcl/run_sessions.sh` (`auto-run.json` `{"run":"bfcl-ast",...}`), `device.sh`
- **Sessões brutas:** `results/slm-bfcl/main-r1-*.json` (inclui configuração, ordem, texto e chamadas por job). Smoke: `smoke*.json`. Estabilidade MiniCPM5: `rep2-minicpm5.json`
- **Avaliação oficial:** `.bfcl-venv/bin/python analysis/slm_bfcl/evaluate.py … --out results/slm-bfcl/main-r1-graded.jsonl`
- **Tabelas:** `python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl`
