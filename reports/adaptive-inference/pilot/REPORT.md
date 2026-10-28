# Adaptive inference piloto — orçamento reativo

Estudo exploratório em 20 tarefas **já medidas**. Não é evidência de generalização.

## Diagnóstico que orientou as políticas

Nas 90 held-out, Direct sequencial falha sobretudo por `stopReason=length` + `no_tool` (22/30):
o modelo gasta os 512 tokens da primeira chamada em thinking e o loop **para** sem ferramenta.
Plan+Act soma 128 tokens de plano e cai no mesmo teto (640, 22/30 no_tool).
Quando a trajetória avança, a falha típica é dependência: `buscarContato` devolve um número e a
chamada seguinte rejeita o formato, ou o Direct duplica FaceTime. O MLX só limita `maxTokens`
por chamada — thinking/ação/final não são canais separados — então P2/P3 controlam **entre** chamadas.

## Método

Qwen3-1.7B-4bit, iPhone 16 Pro, Release, greedy, prefix KV, ferramentas simuladas, 1 rep.
Teto comum: 2048 tokens gerados (plano incluso) e 4 rodadas de ferramentas.
P0 Direct e P1 Plan+Act = baselines. P2 recupera com `enable_thinking=false` se a geração esvaziar.
P3 só planeja (64 tokens) se observar no_progress, tool_error ou dependência de contato não usada.
Nota: P2 também inseriu plano em 4 sequenciais (`unresolved_dependency`). O efeito limpo de orçamento é o fim de `length`/`no_tool` (11→0); os +2 sucessos podem misturar recuperação e esse plano.
Seleção em `selection.json` (gravada antes da execução).

## Resultados

| Política | Sucesso | Latência (s) | Tokens | Tools | Planos | length | no_tool | exec | overhead (ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| direct | 0.300 (6/20) | 24.6 | 500 | 0.85 | 0 | 11 | 10 | 0 | 0.01 |
| plan_act | 0.300 (6/20) | 32.6 | 638 | 1.10 | 20 | 11 | 8 | 2 | 0.01 |
| budgeted_direct | 0.400 (8/20) | 43.2 | 772 | 1.95 | 4 | 0 | 0 | 5 | 0.08 |
| reactive_budget | 0.250 (5/20) | 43.2 | 781 | 1.80 | 15 | 0 | 1 | 4 | 0.09 |

## Perguntas

1. A redistribuição de orçamento (P2 vs P0) melhora o desempenho? **sim** (P0 0.300 → P2 0.400).
2. Planejar de forma reativa é melhor que sempre ou nunca? **não claramente** (P0 0.300, P1 0.300, P3 0.250).
3. A política muda com o estado? sim. Self-check: no_progress→plan, contato ok→unresolved_dependency, contato ausente→tool_error, tarefa concluída→continue. On-device seq_021: com Ana encontrada a P3 planejou `unresolved_dependency` e ligou; sem contato a ferramenta falhou (`Contato não encontrado`) e o loop parou.
4. Vale ampliar? P2 sim, num recorte novo (length/no_tool desapareceu e o sucesso subiu). P3 ainda não: planeja demais e perde para Direct neste recorte.

## Probe P3 (mesmo pedido, resultado de ferramenta diferente)

Mesmo pedido `apple_seq_021`.
- Contato encontrado: tools=['buscarContato: Ana: +15550100', 'ligarFaceTime: facetime-audio:+15550100']; eventos=['r0:gen:limit=512:got=276:calls=1:stop=stop:left=1772', 'r1:plan:unresolved_dependency:limit=64:left=1708', 'r1:gen:limit=512:got=141:calls=1:stop=stop:left=1567', 'r2:gen:limit=512:got=205:calls=0:stop=stop:left=1362']
- Contato ausente: tools=['buscarContato: Contato não encontrado: Ana.']; eventos=[]
Trajetórias diferentes. No caso ausente o backend lança na ferramenta, então o controlador não chega a um segundo turno (limitação: tool_error que throw interrompe o loop).

Artefatos: `selection.json`, `pilot-session.json`, `probe-empty.json`, `summary.json`.

