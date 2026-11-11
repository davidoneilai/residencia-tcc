# Protocolo: DEV 2 da especulação MTP com prefixo aquecido (2026-11-11, registrado antes da execução)

**Por que um DEV 2.** O DEV 1 ([PROTOCOL-mtp.md](PROTOCOL-mtp.md), [mtp-dev.md](mtp-dev.md)) falhou no tempo (IC95%
[−10,5; +1,3] s). Na rodada A, o prefixo frio de cada catálogo cai na condição que roda primeiro: a pilha + MTP
pré-preencheu 4017 tokens por tarefa e a pilha, 2943. Na rodada B (prefixo pronto), −14,4%.

Essa leitura é **exploratória** (vista depois dos dados): ela motiva o desenho abaixo, não é resultado. As 12 tarefas
DEV são as mesmas; o TEST segue intocado para a MTP.

## Desenho

- **Build, modelo e condições:** os do PROTOCOL-mtp.md (`dacs-persist-kv` contra `dacs-persist-mtp-kv`: subset,
  top 16384, gate 0,9, contexto 256), sem mudança de código.
- **Aquecimento** (rodada `mw0`, não analisada): prefixos em disco apagados, depois cada tarefa uma vez só com
  `dacs-persist-kv`. Os prefixos de todos os catálogos ficam no disco para as duas condições (a chave é o modelo, e a
  MTP não muda o prefixo).
- **Medição:** rodadas `mw1`…`mw4`, cada uma com 12 tarefas × 2 condições, ordem girada pelo `run_eval.py`; são
  48 pares.

## Critério (o mesmo do DEV 1, `mtp_decide.py`, perda máxima 1)

1. Tempo: IC95% bootstrap do Δ médio por par inteiro abaixo de zero.
2. Acerto: perda líquida ≤ 1 e, se positiva, McNemar exato com p ≥ 0,05.

Se passar, segue um TEST congelado novo com o mesmo desenho (aquecimento + rodadas medidas).
