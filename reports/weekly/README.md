# Relatórios semanais

Ponto de entrada para a banca. Cada semana aponta para as evidências onde elas já estão (`results/`, `reports/`, `mobile-adaptive-inference/`); nada é copiado.

Semana 1 = 2026-W37 (início do repositório, 2026-09-10). A semana de cada artefato vem da data do commit ou, para o que ainda não estava versionado, da data do arquivo.

| Semana | ISO | Período | O que foi feito | Evidência |
|---|---|---|---|---|
| 1 | 2026-W37 | 07–13 set | Início do repositório; MVP Android | [AndroidLLMBench](../../AndroidLLMBench/README.md) |
| 2 | 2026-W38 | 14–20 set | Sem artefato versionado | — |
| 3 | 2026-W39 | 21–27 set | Sem artefato versionado | — |
| 4 | 2026-W40 | 28 set–04 out | Plano; BFCL v4 (fatia de 40) em GPU com vLLM, Qwen3-1.7B e Gemma 4 E2B | [plano](../../docs/plans/2026-09-29-mobile-adaptive-inference.md), [relatório GPU](../../mobile-adaptive-inference/results/relatorio-bfcl.md), [protocolo](../../mobile-adaptive-inference/README.md) |
| 5 | 2026-W41 | 05–11 out | Primeiras matrizes no iPhone (Apple FM, Qwen3, Gemma 4; estratégias de raciocínio do Qwen) | [entrega 08/10](../../docs/entrega_2026-10-08.txt), [matriz](../../results/iphone16pro_matriz_2026-10-08.json), [Qwen thinking](../../results/iphone16pro_qwen_thinking_2026-10-08.json) |
| 6 | 2026-W42 | 12–18 out | Smoke do protocolo 2; sessão cross-model | [smoke](../../results/smoke-2026-10-12/report.md), [cross-model](../../results/cross-model-2026-10-13.json) |
| 7 | 2026-W43 | 19–25 out | Roteamento adaptativo (offline, on-device 3 reps, v2, held-out v3); MVP de chat agêntico; piloto de orçamento reativo | [roteamento](../adaptive-routing/REPORT.md), [variância 3 reps](../adaptive-routing/on-device/VARIANCE_3REP.md), [v2](../adaptive-routing/v2/REPORT.md), [v3 held-out](../adaptive-routing/v3/REPORT.md), [chat MVP](../chat-agent-mvp/REPORT.md), [chat adaptativo](../chat-adaptive-pilot/REPORT.md), [orçamento reativo](../adaptive-inference/pilot/REPORT.md) |
| 8 | 2026-W44 | 26 out–01 nov | AdaptiveStep e ActionAware; SLMs no BFCL v4 AST (880 execuções) | **[relatório da semana](2026-W44/README.md)**, [AdaptiveStep](../adaptive-inference/step-pilot/REPORT.md), [ActionAware](../adaptive-inference/action-aware/REPORT.md), [estudo SLM](../slm-bfcl/REPORT.md) |

Só a Semana 8 tem relatório gerado por script, com manifesto de reprodutibilidade. As anteriores têm os relatórios da época, cada um com sua sessão bruta ao lado.

## Gerar ou atualizar uma semana

```bash
python3 analysis/weekly/generate.py 2026-W44
python3 analysis/weekly/generate.py --check
```

A definição da semana (arquivos lidos, repetições esperadas) está em `analysis/weekly/weeks/YYYY-WXX.json`. O gerador só lê arquivos já gravados; não relança inferência no iPhone.

| Arquivo da semana | Conteúdo |
|---|---|
| `README.md` | Relatório |
| `tables.md` | Tabelas completas (mesmo cálculo de `analysis/slm_bfcl/analyze.py`) |
| `figures/` | Qualidade × latência, estratégias, decomposição da latência |
| `MANIFEST.md` | Checkpoints, versões, seeds, hashes, comandos |
| `summary.json` | Números serializados para conferência |
