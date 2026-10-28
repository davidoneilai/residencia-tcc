# Adaptive routing (Experimentos A/B)

Pipeline offline sobre o JSON exportado pelo MobileLLMBench. O roteador **não** chama o LLM: escolhe entre políticas já medidas e soma o overhead da decisão.

```bash
cd analysis/adaptive_routing
python3 run_experiment.py --check
python3 run_experiment.py \
  --input ../../results/cross-model-2026-10-13.json \
  --out ../../reports/adaptive-routing
python3 export_swift_weights.py   # se o learned for logistic no Qwen
python3 run_v2.py --check
python3 run_v2.py                 # auditoria 3-rep + logística com custo de sucesso → reports/adaptive-routing/v2/
```

Saídas em `reports/adaptive-routing/`:

| Arquivo | Conteúdo |
| --- | --- |
| `REPORT.md` | Metodologia, tabelas, limitações |
| `comparison_test.csv` | Hold-out por modelo |
| `comparison_all.csv` | train/val/test |
| `artifacts/*_task_policy_matrix.csv` | Matriz tarefa × política |
| `artifacts/*_summary.json` | Oracle, LOFO, splits |
| `artifacts/*_learned.json` | Pesos/árvore do roteador |

No app: estratégia **Adaptativo** (`Strategy.adaptive`) + preset **Adaptativo**. A lógica vive em `AdaptiveRouter.swift`, fora dos backends.
