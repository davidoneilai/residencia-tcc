# DAC — protocolo do estudo DEV (fixado em 2026-11-06, antes das rodadas DEV completas)

**Pergunta.** Uma estratégia de inferência adaptativa sem treino, sem mudar pesos nem o runtime MLX Swift, reduz a
latência de tarefas agênticas multi-turn de um SLM no iPhone sem perder acerto?

**Modelo e ambiente.** Qwen3.5-2B-4bit (`mlx-community/Qwen3.5-2B-4bit@674aaa7`), iPhone 16 Pro, `InferenceServer`
do MobileLLMBench (`POST /v1/chat/completions`), decode greedy, teto de 1024 tokens gerados por passo.
Harness, simulador de ferramentas e scorer: `bfcl-eval` 2026.3.23, `multi_turn_base`, sem alterações.

**Fatia.** `results/bfcl-mt/slice.json`, congelada em 2026-11-04 (seed 20261104): 12 entradas DEV, 32 TEST.
**As 32 TEST não rodam neste estudo.** Só rodam depois de a política ser congelada com base no DEV.

## Condições

| Chave | Condição | Servidor | Cliente |
|---|---|---|---|
| `reason-off` | Reasoning fixo, sem cache | `qwen35:direct` | estratégia fixa |
| `reason-kv` | Reasoning + cache incremental validado | `qwen35:direct:kv` | estratégia fixa |
| `a-kv` | Política A original (inalterada, `controller.py`) | `qwen35:direct:kv` | A: para na 3ª chamada idêntica / 3º erro seguido |
| `dac-kv` | DAC: cache + recuperação | `qwen35:direct:kv` | `dac.py`: detecta, intervém uma vez, tentativa extra, para se falhar |
| `dacs-kv` | DAC + computação seletiva | `qwen35:direct:kv` + `think_budget=512`, `repeat_guard` | `dac.py` |

`reason-prefix` (prefix cache antigo, sem âncora de turno) só entra no teste controlado de cache.

## Parâmetros fixados

- Recuperação (`dac.py`): detecção na 2ª ocorrência da mesma chamada no turno ou no 2º erro seguido; uma nota por turno
  (papel user, prefixo `[Harness note]`, cita a chamada/erro e o resultado já devolvido, sem resposta-modelo);
  uma tentativa extra; depois da nota, qualquer repetição ou erro encerra o turno. O resultado das ferramentas não muda.
- Seletiva: `think_budget = 512`. Escolhido nas trajetórias DEV de Reasoning já gravadas (190 passos < 400 tokens,
  12 no teto de 1024; nenhum terminou o raciocínio entre 400 e 1023). No estouro, o servidor fecha `</think>` e a
  resposta continua do mesmo KV (sem reprocessar). `repeat_guard`: corta o decode quando a mesma chamada (nome +
  argumentos) sai de novo na mesma resposta. Nenhuma chamada extra de LLM.
- No-think por estado **não** entra: no DEV, Qwen3.5 NoThink faz 2/12 contra 4/12 do Reasoning, e o AST já mostrou −20 pp.

## Execução

- 3 rodadas (`r1`, `r2`, `r3`) × 12 entradas, condições intercaladas por entrada. `reason-off` só em `r1`:
  é 4–5× mais lenta e o efeito do cache já está medido no teste controlado (−79%: Δ −135 s/entrada, IC95% [−178; −95], 4 entradas);
  `r2` e `r3` rodam as 4 condições com cache. Na entrada *i* da rodada *r*,
  as condições giram *(i + r)* posições (`run_dac.sh`).
- Antes de cada entrada (bloco de condições), o runner espera a térmica do iPhone sair de `serious`/`critical`
  (até 15 min) e registra a espera; a térmica de cada passo vai para o `trace.jsonl`.
- Um aquecimento por rodada. Mac com `caffeinate`, cabo, Auto-Lock em Nunca.

## Achados do diagnóstico que condicionam a leitura

- Decode greedy é determinístico **dentro** de um caminho numérico: o prefix cache reproduziu, token a token
  (chamadas e argumentos), as trajetórias de 4–5/11. Repetições medem variância de latência, não de acerto.
- Caminhos numéricos diferentes (sem cache, prefix, kv: blocos de prefill em pontos diferentes) mudam a trajetória
  greedy nas entradas frágeis (11, 45, 46, 163, 169, 197). Nas 4 entradas estáveis do teste de cache, 7/8 trajetórias
  com cache foram idênticas às sem cache. Diferenças de ±1–2 entradas em 12 são ruído numérico, não efeito de política.
- O prompt é determinístico entre lançamentos do app (swift-jinja ordena as chaves dos dicionários); só o JSON devolvido
  ao cliente tem ordem de chaves aleatória, e o histórico é reordenado ao renderizar.

## Métricas

Acerto BFCL (estado + resposta, por entrada); tempo total por entrada (cliente); TTFT por passo; prefill, decode e
overhead (template/sondas) do servidor; tokens de entrada, de prefill e de saída; passos; loops (mesma chamada ≥ 3× no
turno); passos no teto; detecções, intervenções, recuperações e stops; pico de memória; térmica por passo.

Comparações pareadas por entrada × rodada: McNemar exato sobre os pares discordantes e bootstrap (10 mil) do Δ de tempo.
Com 12 entradas, diferenças de acerto menores que ~3 entradas não são distinguíveis do acaso: o DEV decide o mecanismo
pela latência e pelos modos de falha. A conclusão sobre acerto fica para o TEST.

## Atribuição

- Cache: `reason-off` → `reason-kv` (mesma política).
- Parada da A: `reason-kv` → `a-kv`.
- Recuperação: `a-kv` → `dac-kv` (mesmo cache) e `reason-kv` → `dac-kv`.
- Seletiva: `dac-kv` → `dacs-kv`.
