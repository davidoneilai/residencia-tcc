# TEST final da pilha no iPhone — protocolo congelado (2026-11-09, antes de qualquer execução TEST)

**Pergunta.** A pilha (DAC + guardas de decode + prefixo persistente), congelada no DEV, reduz o tempo por tarefa
sem perder acerto em tarefas nunca usadas para escolher nada?

**Fatia:** as **32 entradas TEST** de `results/bfcl-mt/slice.json` (seed 20261104, congelada em 2026-11-04). Nenhuma
delas rodou antes em nenhuma condição. `bfcl-eval` 2026.3.23 `multi_turn_base`, harness/simulador/scorer sem alterações.
iPhone 16 Pro, greedy, teto 1024 por passo, build do app de 2026-11-08 12:55 (mlx-swift-lm 3.31.4), git `bbf28c2` +
mudanças locais com os hashes abaixo.

## Política congelada (escolhida no DEV, sem mudança daqui em diante)

| Modelo | Estratégia | Referência | Pilha |
|---|---|---|---|
| `qwen35` Qwen3.5-2B-4bit @674aaa7 | Reasoning | `rt-base-kv` (think_budget 512, kv) | `dacs-persist-kv` |
| `minicpm5` MiniCPM5-2B-MLX @8a9ad75 | NoThink | `nt-base-kv` | `nt-dacs-persist-kv` |
| `gemma4` Gemma 4 E2B 4bit @2387675 | NoThink | `nt-base-kv` | `nt-dacs-persist-kv` |

Pilha = DAC (`dac.py`: nota e uma tentativa extra na 2ª repetição/2º erro; depois para) + `repeat_guard` +
`think_budget` 512 (só onde há raciocínio) + prefixo persistente (`PrefixStore`, até 48 arquivos, chave por modelo).
LFM2.5 fica fora (283 s/tarefa e 2/12 no DEV); SFT fica fora (piora o acerto no DEV, ver `PROTOCOL-sft.md`).

**Desvio registrado.** O critério do protocolo `PROTOCOL-stack.md` (prefixo sozinho ≥ 20% quente) não passou no DEV
(−12%); a decisão de levar a pilha completa ao TEST foi tomada depois de ver o DEV. O DEV existe para essa escolha e as
32 TEST seguiam intocadas; o critério abaixo é o que vale para o TEST.

## Execução

- Antes de começar: prefixos em disco apagados. Por modelo (Qwen, MiniCPM5, Gemma 4): rodada A = referência + pilha
  (pilha fria: 1ª vez de cada catálogo), rodada B = só a pilha (quente). Condições giram por entrada.
- Espera térmica (até 10 min) antes de cada execução; até 3 tentativas por execução (falha de rede/timeout recomeça
  a entrada do zero); o runner espera o iPhone voltar por até 1 h.
- Mac com `caffeinate -dims` e tampa aberta; app em primeiro plano na aba Ao vivo.

## Critério de sucesso (por modelo; Qwen3.5 é o primário)

1. Tempo: Δ médio por entrada da pilha **quente** (B) contra a referência (A), pareado por entrada, IC95% bootstrap
   (10 000 reamostras, seed 0) **inteiro abaixo de zero**.
2. Acerto: pilha (A e B) contra referência, pareado por entrada: perda líquida de no máximo 1 entrada em 32 e McNemar
   exato sem perda significativa (p ≥ 0,05).
Relatados também: Δ frio (A), prefill/decode/passos/tokens, térmica, falhas e tentativas.
Análise: `analysis/bfcl_mt/analyze_dac.py` + `analysis/runtime/cold_warm.py`.

## Hashes (sha256, 16 primeiros)

| Arquivo | sha256 |
|---|---|
| `analysis/bfcl_mt/bfcl.py` | `83d048fd17112d29` |
| `analysis/bfcl_mt/dac.py` | `70504c98762efc7a` |
| `analysis/bfcl_mt/controller.py` | `c192f99fe2eb8745` |
| `analysis/runtime/run_eval.py` | `6944953c4704e13d` |
| `analysis/runtime/microbench.py` | `b85f6faa3443694f` |
| `MobileLLMCore/MLXPhoneBackend.swift` | `104fa34fe11cc75c` |
| `MobileLLMCore/PrefixStore.swift` | `88a0fcbce845bd3e` |
| `MobileLLMCore/ToolCallDraft.swift` | `d31090bfcb4a31ea` |
| `MobileLLMBench/InferenceServer.swift` | `07b0e987b0533b4f` |
| `results/bfcl-mt/slice.json` | `327b555bf26e97bf` |
