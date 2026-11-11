# Protocolo: especulação MTP em pipeline com escalonador por custo (DEV, 2026-11-11)

Registrado antes da execução. Build `MLX_LM_MAIN` (`~/VSCODE/MobileLLMBench-lfm3`, mlx-swift-lm `ec4c966a`), iPhone 16 Pro,
Qwen3.5-2B-4bit, pelo cabo USB (`iphone_proxy.py`).

## Condições

| Condição | O que é |
|---|---|
| `dacs-persist-kv` | pilha atual (DAC + `think_budget` 512 + `repeat_guard` + prefixo persistente) |
| `dacs-persist-mtp-kv` | a mesma pilha + `MTPPipelineIterator`: cabeça MTP oficial, rascunho no vocabulário reduzido (prompt + gerados + ids 0–16383), rodada seguinte na fila só com confiança da MTP ≥ 0,9 |

Configuração escolhida nos microbenchmarks de [PLAN-sota.md](PLAN-sota.md) (etapas 1 e 2).

**Ressalva:** esses passos vêm de requisições gravadas de tarefas do TEST (`results/runtime/decode1-requests.json`). O
limiar só mexe no tempo, mas não é independente do TEST. Ganhos de 1,20–1,21× com limiar de 0,7 a 0,9: a escolha
pouco importa.

## Execução

- 12 tarefas DEV (`results/bfcl-mt/slice.json`) × 2 condições × 2 repetições (rodadas `mtA`, `mtB`);
- ordem girada pelo `run_eval.py`, reset dos KV em memória antes de cada tarefa, espera térmica do `cool()`;
- prefixos em disco apagados no início.

## Hipóteses e decisão

- **H1 (tempo):** tempo médio por tarefa menor com MTP, IC 95% bootstrap pareado (tarefa × repetição) abaixo de 0.
- **H2 (acerto):** a MTP não perde mais de 1 tarefa de 24 em relação à pilha (a saída pode diferir: verificação em
  lote de 2).
- **Se H1 e H2 passarem,** segue para um TEST congelado (32 tarefas) com protocolo próprio. Se H2 falhar, investigar
  a divergência antes de qualquer TEST.

Análise: `analysis/bfcl_mt/analyze_dac.py` (`--ref dacs-persist-kv`).
