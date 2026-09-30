# Relatório BFCL — inferência adaptativa (29 set 2026)

Fatia pequena do BFCL v4 non-live, não o benchmark inteiro. 10 primeiros IDs de cada categoria: `simple_python`, `multiple`, `parallel`, `parallel_multiple`. 40 tarefas por condição. Temperatura 0, concorrência 1, `max_tokens` 512. GPU: NVIDIA B200 MIG 3g.90gb, vLLM 0.29. Modelos: `Qwen/Qwen3-1.7B` e `google/gemma-4-E2B-it`.

Estratégias isoladas, uma de cada vez: direct, prefix cache, speculative (Qwen ngram; Gemma MTP com `google/gemma-4-E2B-it-assistant`), plan+act (duas chamadas: plano até 128 tokens, depois a ação).

τ² não rodou (`TAU2_SKIPPED`, sem `OPENAI_API_KEY`). AppWorld não rodou. Não há energia.

Os números abaixo vêm dos JSONL em `results/`. O `score/data_overall.csv` e o `data_non_live.csv` são só a última estratégia que o checker oficial gravou (plan+act). Não usar esses CSV como ranking das quatro estratégias.

Acerto = o checker oficial do BFCL marcou o ID como válido. Latência = só o tempo de inferência do agente (`agent_inference_ms`), média.

## Qwen3-1.7B

| Estratégia | Acerto | simple | multiple | parallel | parallel_multiple | Latência média | Tokens de saída | Chamadas de ferramenta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| direct | 30/40 (75%) | 10/10 | 6/10 | 6/10 | 8/10 | 720 ms | 327 | 1.40 (5 tarefas com 0) |
| prefix | 34/40 (85%) | 10/10 | 7/10 | 9/10 | 8/10 | 743 ms | 323 | 1.55 (2 com 0) |
| speculative | 32/40 (80%) | 9/10 | 8/10 | 8/10 | 7/10 | 1290 ms | 338 | 1.40 (5 com 0) |
| plan+act | 4/40 (10%) | 0/10 | 3/10 | 0/10 | 1/10 | 288 ms | 120 | 0.20 (34 com 0) |

Direct é a referência. O modelo emite `<think>` longo e em geral um `<tool_call>` JSON. Das 10 falhas, 8 ainda tinham tool call e o checker rejeitou o conteúdo (`multiple_0`, `multiple_5`, `multiple_7`, `parallel_1`, `parallel_2`, `parallel_6`, `parallel_multiple_3`, `parallel_multiple_6`). Só `multiple_1` e `parallel_3` falharam sem nenhuma tag. `simple_python_1` e `simple_python_5` ficaram com `tool_calls` 0 no nosso contador e mesmo assim o checker marcou certo: a coluna conta tags `<tool_call>` no texto da completion, e o acerto vem do BFCL.

Prefix cache não reduziu latência (cerca de +4% vs direct). Subiu o acerto em 4 IDs (`multiple_1`, `parallel_1`, `parallel_2`, `parallel_3`) e não perdeu nenhum. Com n=40 e temperatura 0, essa diferença é o resultado observado, não uma conclusão de que cache melhora qualidade.

Speculative (ngram, 5 tokens) ficou ~1.86× mais lento que direct, com acerto 80%. Ganhou `multiple_0`, `multiple_1`, `parallel_1`, `parallel_3` e perdeu `simple_python_2`, `parallel_multiple_0`.

Plan+act faz duas chamadas (`model_calls` = 2). O prompt médio sobe de 330 para 762 tokens. A latência cai porque a saída encolhe (120 vs 327 tokens): em 34/40 tarefas não houve tool call. Acerto 10%, e o checker oficial dessa última rodada bate com o JSONL (simple 0/10, multiple 3/10, parallel 0/10, parallel_multiple 1/10).

## Gemma 4 E2B

| Estratégia | Acerto | Latência média | Tokens de saída | Tokens de prompt | Chamadas contadas |
|---|---:|---:|---:|---:|---:|
| direct | 0/40 | 170 ms | 36 | 798 | 0 |
| prefix | 0/40 | 153 ms | 36 | 798 | 0 |
| speculative | 0/40 | 122 ms | 36 | 798 | 0 |
| plan+act | 0/40 | 181 ms | 37 | 1617 | 0.03 (1 tarefa) |

0% nas quatro estratégias. O modelo responde, e rápido, porque a saída é curta (~35 tokens, sem o `<think>` longo do Qwen). O prompt é maior (~800 tokens) por causa do template com as ferramentas.

O texto que ficou salvo (última estratégia, plan+act) não é o markup que o checker do Gemma espera. Exemplos: `[calculate_triangle_area(base=10, height=5)]`, `[math.triangle_area_heron(side1=3, side2=4, side3=5)]`. O contador de `tool_calls` procura `<tool_call>{json}</tool_call>` (e, se não achar, o parser `gemma4`). Esse formato Python não entra na conta e o checker oficial também marca inválido. O teste de chat anterior (`add(a=2, b=3)`) tinha funcionado; o caminho do BFCL é `/v1/completions`, com o prompt já formatado.

Prefix e speculative no Gemma só mudam latência nessa fatia (153 ms e 122 ms vs 170 ms) em cima de acerto zero. Plan+act dobra o prompt e continua em 0/40.

## Leitura curta

Na fatia de 40 IDs, Qwen direct já chama ferramenta e fica em 75%. Prefix não acelerou. Speculative ngram atrasou. Plan+act derrubou o acerto para 10% porque a segunda chamada muitas vezes não emite a tool call.

Gemma está mais rápido e não pontua: a geração não sai no formato que o avaliador e o contador reconhecem. Tratar 0% como “não houve chamada no formato esperado”, não como “o modelo não tentou responder”.

Não comparar esses percentuais com o leaderboard cheio do BFCL. São 10 IDs por categoria, non-live apenas.
