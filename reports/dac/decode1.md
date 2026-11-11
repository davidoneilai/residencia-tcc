# Sinais durante o decode — diagnóstico (2026-11-06)

Rodada única `results/bfcl-mt/dac/decode1/`: Qwen3.5-2B, iPhone 16 Pro, `reason-b512-kv` (Reasoning, `think_budget=512`,
KV incremental, sem guarda), DEV 124, 163, 169, 197. O servidor passou a gravar o texto gerado inteiro (`raw_text`;
antes cortava em 500 caracteres); a geração não mudou. Análise: `analysis/bfcl_mt/decode_signals.py decode1 reason-b512-kv`.

Acerto: 124 ✓, 163 ✓, 169 ✗, 197 ✗ (igual às rodadas DEV). 42 passos, 8 com raciocínio fechado à força em 512.

## Sinais no raciocínio

- Entradas certas (124, 163): nenhuma hesitação além de 1, no máximo 12 8-gramas repetidos, 1 frase repetida.
  Raciocínio longo (163: 273/218/161 tokens) é produtivo: os argumentos ficam prontos 13–22 tokens antes do fechamento.
- Estouros (169.0, 197 ×7): 3–15 hesitações, 25–392 8-gramas repetidos a partir do token 93–180, até 17 frases repetidas.
- Regra "20º 8-grama repetido" dispara em 9 passos, nenhum em entrada certa, e cobre os 8 estouros; o disparo
  vem no token 134–473 (mediana ~190).

## Intervenção e economia

- Fechar o raciocínio à força (mecanismo já existente) preserva o formato: 8/8 passos fechados à força emitiram
  chamadas válidas. Que preserve a chamada *correta* não dá para mostrar: todos os disparos estão em entradas que
  falham em todas as condições.
- Economia (fração do tempo total das 4 entradas, 481 s): orçamento fixo 256 = 15%; detecção online além do 256 = 3,1%,
  toda na 197. Nas entradas certas, 0.

## Gargalos restantes (tempo do cliente por entrada)

| Entrada | Total | Decode raciocínio | Decode chamadas | Decode texto | Prefill (system+tools) | Template + sondas/cópias KV |
|---|---|---|---|---|---|---|
| 124 ✓ | 43 s | 21% | 11% | 14% | 43% (31%) | 10% |
| 163 ✓ | 63 s | 38% | 17% | 11% | 27% (15%) | 5% |
| 169 ✗ | 93 s | 32% | 18% | 13% | 31% (19%) | 5% |
| 197 ✗ | 281 s | 58% | 29% | 0% | 7% (0%, reaproveitado da 169) | 5% |

Chamadas no formato XML do Qwen3.5: 78 tokens por chamada; 61% são tags e quebras de linha fixas pela gramática,
13% nomes de função/parâmetro, 26% valores. Decode ~0,034 s/token; prefill ~15× mais rápido por token.
