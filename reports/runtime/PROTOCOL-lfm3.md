# LFM3-1.7B no iPhone, build novo — protocolo (fixado em 2026-11-10, antes da execução)

**Pergunta.** O LFM3-1.7B (LiquidAI, 2026-10-27) acerta mais que o Qwen3.5-2B no BFCL Multi-Turn, e a pilha
(DAC + guardas + prefixo persistente) o acelera como acelera os outros SLMs?

## Build (diferente do usado até o TEST)

- Projeto `~/VSCODE/MobileLLMBench-lfm3`, cópia do projeto dos estudos com `mlx-swift-lm` fixado em
  `ec4c966a` (main de 2026-11-09, com o LFM3; o commit seguinte, #711, não compila no iOS) e a condição
  `MLX_LM_MAIN`.
- `MobileLLMCore/MLXCompat.swift` reproduz o 3.31.4 no `main`:
  - texto bruto com o raciocínio e o `</think>` (o `main` separa o raciocínio em `.reasoning`);
  - prefill em blocos `.remainder` (o `main` passou para `balanced`);
  - `newCache` com `throws`.
- **Os números deste build não se comparam com os do build antigo.** Mesmo com o modo `.remainder`, o Qwen3.5 dá
  outra saída greedy no smoke. Por isso o Qwen3.5 roda de novo aqui (`qnA`/`qnB`).
- Smoke 2026-11-10:
  - LFM3 com e sem raciocínio faz as 2 chamadas;
  - `think_budget` 64 fecha o `</think>` à força;
  - o prefixo persistente funciona: TTFT 14,3 → 0,9 s, carga em 9–12 ms, saída idêntica.

  Para o prefixo funcionar, o `PrefixStore` passou a aceitar `MambaCache` de um slot (camadas de convolução)
  conferindo o número de slots por camada.
- **Achado registrado:** pelo mesmo motivo, o LFM2.5 no DEV (`lfA`/`lfB`) **nunca usou** o prefixo persistente
  (`built` em 36/36 primeiros passos). O ganho dele (−46%/−44%) é só da DAC + guardas.

**Fatia:** as 12 entradas DEV. **As 32 TEST não rodam.**

## Execução

1. Prefixos do disco apagados.
2. `lmR`: LFM3 × {`rt-base-kv` (Reasoning, think_budget 512), `nt-base-kv` (NoThink)}.
3. **Regra de escolha (fixa):** a estratégia do LFM3 é a de mais acerto em `lmR`; no empate, a de menor tempo médio
   por entrada. Ela é gravada em `reports/runtime/lfm3-strategy.json`. A pilha usa a estratégia escolhida:
   `dacs-persist-kv` se Reasoning, `nt-dacs-persist-kv` se NoThink.
4. `lmA` (pilha fria) e `lmB` (pilha quente), pareadas contra a referência escolhida de `lmR`.
5. `qnA`: Qwen3.5 × {`rt-base-kv`, `dacs-persist-kv`} (fria); `qnB`: `dacs-persist-kv` (quente).

## Leitura

- LFM3 × Qwen3.5 em acerto (mesma fatia, mesmo build), pareado por entrada.
- Δ tempo da pilha fria e quente contra a referência, por modelo (IC95% bootstrap).
- Se o LFM3 acertar mais que o Qwen3.5 com a pilha funcionando, ele entra num TEST no build novo, com protocolo
  próprio.
