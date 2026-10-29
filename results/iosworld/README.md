# iOSWorld — trajetórias on-device

Agente: `qwen35` (`mlx-community/Qwen3.5-2B-4bit`) no iPhone 16 Pro via `InferenceServer` (`POST /v1/chat/completions`).
Apps e Appium: simulador `iPhone 17 Pro`, iOS 26.5, no Mac.
Judge: **não** correu no Mac (não há OpenAI). Corre na GPU com vLLM.

## Rodada pronta para julgar

| Campo | Valor |
|---|---|
| Pasta | [`qwen35-iphone16pro/single-task-20261029-120427-clock-001`](qwen35-iphone16pro/single-task-20261029-120427-clock-001) |
| Tarefa | `clock-001` (1 das 133 do iOSWorld) |
| Status do agente | `ok` (parou sozinho no passo 50) |
| Modelo | `qwen35`, MCP, greedy |
| Parede | 1217 s |

O alarme `gym` aparece em `list_alarms` a partir do passo 9. O SLM loopou `navigate_to_tab`/`list_alarms` até o orçamento de 50 passos. `agent_answer` ficou vazio.

## Julgar na GPU

Precisa do clone do [iOSWorld](https://github.com/ljang0/iOSWorld) (scripts + `tasks.json`) e deste repo (artefatos). Paths das screenshots são `results/single-task-…`; o script abaixo copia a pasta para o lugar certo.

```bash
# 1. vLLM (exemplo do próprio iOSWorld; ajuste TP / GPU)
vllm serve Qwen/Qwen3.5-35B-A3B \
  --host 0.0.0.0 --port 8000 \
  --served-model-name qwen3.5-35B-a3 \
  --max-model-len 32768

# 2. stage + judge (a partir da raiz do residencia-tcc)
chmod +x analysis/iosworld/judge.sh
IOSWORLD=/caminho/para/iOSWorld \
  EVAL_MODEL=qwen3.5-35B-a3 \
  VLLM_BASE_URL=http://127.0.0.1:8000/v1 \
  ./analysis/iosworld/judge.sh
```

`--re-judge` não é necessário nesta cópia: o `evaluation` dummy do OpenAI foi removido. Depois do judge, `01-clock-001/task.json` e `summary.json` no clone do iOSWorld ganham `success` / `score` / rubrica. Copie de volta para cá se quiser versionar a nota.
