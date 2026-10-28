# ActionAware — recuperação por estado de ferramenta

Exploratório. Mesmo recorte `apple_step_pilot_12` (fora do held-out 90 e do residency-60).
Sessão `02800F8E-2DC6-4F00-9645-D8523B1B660B` · 36/36 · `finished: true`.
Qwen3-1.7B-4bit, iPhone 16 Pro, greedy, prefix KV, simulado, 1 rep.
Térmica: 20 `ready`, 16 `proceed_hot`. Freeze v3 e Chat intocados.

## O que mudou no runtime (comum a NoThink+runtime e ActionAware)

1. Throw de ferramenta vira saída observável e o lote segue. NoThink original ainda aborta (`failureKind=execution`).
2. Geração vazia com `stop` e tools já vistas encerra o loop (também no AdaptiveStep). Sequencial/multi que ainda emitem tools na rodada seguinte não são cortados.

O avaliador não mudou: extra, duplicata e argumento inválido continuam a zerar `taskSuccess`.

## Resultados

| Política | Sucesso | Latência (s) | Tokens | Rodadas | Extra calls | Recuperações |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| nothink | 0.750 (9/12) | 2.7 | 64 | 2.00 | 1 | 0 |
| nothink_runtime | 0.750 (9/12) | 3.2 | 70 | 2.33 | 3 | 0 |
| action_aware | 0.833 (10/12) | 4.8 | 97 | 2.50 | 5 | 3 |

Por categoria (sucesso): NoThink e runtime 3/4 · 4/4 · 2/4; ActionAware 3/4 · 4/4 · **3/4** (single / multi / sequential).

**ActionAware supera NoThink+runtime? sim**, +1/12. O runtime sozinho **não** subiu a acurácia.

## De onde veio o ganho

Única conversão falha→acerto: `step_seq_001` (buscar Ana, depois `ligar`).

- NoThink e runtime: `buscarContato` devolve `+15550100`; a rodada seguinte escreve texto e não chama `ligar`. `grade`.
- ActionAware: mesmo r0/r1; r2 `recover:unresolved_dependency` (s1 64) emite `ligar` no número da agenda. Trajetória completa, 0 extra/dup.

`step_single_001` permanece `grade` nas três políticas (`enviarWhatsApp` no lugar de `ligar`). A tool “válida” errada não dispara recover.

## Custo de cada recuperação

| Tarefa | Recovers | Trigger | Δ latência vs runtime | Extra/dup | Resultado |
| --- | ---: | --- | ---: | ---: | --- |
| `step_seq_001` | 1 | `unresolved_dependency` | **+13.4 s** | 0 | sucesso |
| `step_seq_004` | 2 | `tool_error` | **+8.6 s** | 4 dups | `grade` |

Média das recuperações (n=2): +11.0 s. Overhead do controlador: 0.05 ms.

`step_seq_004` mostra o teto da política: o runtime já deixa o erro de FaceTime (`##`) no histórico e chega a chamar `buscarContato`; ActionAware gasta duas recuperações s1 e **repete** `criarLembrete`+FaceTime inválido. O número certo nunca entra em `ligarFaceTime`. Duplicatas contam; não há acerto parcial.

## Runtime vs NoThink

Empate em 9/12. Em `seq_004` o throw deixa de ser `execution` e vira `grade`, com 2 FaceTime extras ainda inválidos. Continuar depois do throw **não** recupera argumento placeholder se o modelo não troca o número.

## Recomendação

Neste recorte, ActionAware vale o custo **só** no buraco “lookup ok, ação seguinte omitida”. Não generaliza para placeholder/`tool_error` nem para tool errada que executa. Não se adicionou heurística nova para empurrar o recorte. Sem integração Chat e sem mexer no freeze v3.

Artefatos: `selection.json`, `action-aware-session.json`, `summary.json`. Preset `action-aware-pilot`.
