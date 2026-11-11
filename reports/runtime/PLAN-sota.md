# Plano: aceleração de agentes SLM no iPhone além da pilha (2026-11-10)

Objetivo do autor: um método de aceleração de inferência de SLMs no iPhone no nível de uma conferência forte, além da
pilha atual (prefixo persistente + DAC/guardas, −31% a −63% no TEST).

## Onde o tempo está agora (medido)

- **TEST, Qwen3.5 com a pilha quente (48 s/tarefa):** prefill 11,6 s; **decode 38,0 s (~75%)**
  ([test-qwen35.md](test-qwen35.md)).
- **Tokens gerados nos 204 passos quentes** ([decode-anatomy-qwen-test.json](../../results/runtime/decode-anatomy-qwen-test.json)):

  | Parte | Fatia | Observação |
  |---|---|---|
  | raciocínio | **60%** | |
  | resposta final ao usuário | 23% | 6339 tokens em 104 passos sem chamada; antes de chamadas, 1,5 token em média |
  | chamadas em XML | 17% | |

- **Custo de uma passada no iPhone** (Qwen3.5-2B-4bit, contexto 6,6k, `results/runtime/forward-cost.json`):

  | Tokens por passada (T) | 1 | 2 | 3 | 4 | 8 |
  |---|---|---|---|---|---|
  | ms | 32,8 | 32,5 | 36,7 | 45,9 | 87,6 |

  **Verificar 2 tokens custa o mesmo que gerar 1;** 3 custam +12%; daí para cima, o custo sobe rápido.
- **Rascunho por cópia do contexto** (simulado no Mac): 21–24% dos tokens aceitos → **~1,25× no decode**.
- O Qwen3.5-2B oficial traz **1 camada MTP**, que a conversão `mlx-community` 4 bits descarta. O `mlx-swift-lm`
  `main` tem um iterador especulativo MTP. Drafters "DSpark" existem para MiniCPM5 e LFM2.5 (oficiais) e LFM3
  (comunitário): em 2026, especulação em SLM é o estado da arte corrente, não uma contribuição por si só.

## Opções (com crítica independente, `idea-critic`)

| | Direção | Por que | Risco principal |
|---|---|---|---|
| **A′** | **Especulação guiada pelo custo do hardware.** A cada passada, escolher quantos tokens propor e de que fonte (MTP para texto livre e raciocínio; gramática para as tags das chamadas; cópia do contexto para nomes e IDs), a partir da curva medida do iPhone e da aceitação esperada por região | O decode é 75% do tempo; a curva plana até T = 2–3 é o que difere o celular de uma GPU de servidor | A MTP pode aceitar pouco em 4 bits; o estado recorrente do Qwen3.5 pode custar caro para reverter quando o rascunho é rejeitado |
| **E** | **Caracterização + modelo de latência/energia** de agentes no celular (prefill, decode, tokens por região, térmica), em 3–4 SLMs | Publicável como estudo de medição (MobiSys/IMWUT); é a base que A′ precisa de qualquer jeito | Menos "método", mais "medição" |
| C | Recuperação/compressão do catálogo de ferramentas | Prefill frio menor; pode ajudar o acerto | Conflita com o reuso do prefixo (mitigável: prefixos por subconjunto) |
| D | Pesos em 3 bits / mistos | O decode é limitado por banda | Commodity; risco de acerto |
| B | Controlar o raciocínio | — | Já falhou duas vezes (PACA, sinais no decode) |
| F | Limitar a resposta final ao usuário (23% dos tokens) | Ganho direto | Mexe no que o usuário lê; específico do benchmark. Só como opção de UX (respostas curtas), marcada |

**Escolha:** A′ como método, com E como a caracterização que o sustenta. A′ só segue se o teste 1 passar.

**Premortem de A′:**
1. a MTP aceita menos de 40% → ~1,15× no total;
2. a reversão do estado recorrente come a margem grátis de T = 2;
3. os revisores leem "MTP + cópia + gramática combinados", e cai por falta de novidade;
4. o ganho some sob estrangulamento térmico;
5. com 32 tarefas, a afirmação "sem perda de acerto" tem IC largo.

**Mitigações:**
- o núcleo da contribuição é o **escalonador por custo**, não as fontes de rascunho;
- reportar o resultado sob térmica real;
- verificação greedy sem perda: a saída tem de ser **idêntica**, o que torna o acerto igual por construção.

## Testes para decidir (em ordem)

1. **Aceitação da MTP** em 4 bits, nos 204 passos reais do TEST, no Mac (teacher forcing).
   **Passa se ≥ 0,6 com T = 2.** Abaixo de 0,4, A′ cai e E vira o foco.
   Script: [`analysis/runtime/mtp_check.py`](../../analysis/runtime/mtp_check.py).
2. **Custo da especulação no iPhone:** passada de verificação T = 2/3 com a MTP, reversão do estado recorrente,
   saída idêntica.
3. **Térmica:** 20 min de decode contínuo, tok/s e estado térmico.
4. **Texto após as chamadas:** feito; não há falatório (1,5 token em média antes das chamadas). A resposta final ao
   usuário é a opção F.

## Resultados dos testes (2026-11-10)

1. **Aceitação da MTP: passou com folga.** Ela supera o limiar de 0,6.
   - **85,3%** de aceitação de 1 rascunho (T = 2), com o alvo em 4 bits, nos 204 passos quentes do TEST:
     raciocínio 80,2%, texto 93,1%, chamadas 92,4%
     ([mtp-accept-qwen-test-4bit.json](../../results/runtime/mtp-accept-qwen-test-4bit.json)).
   - O alvo reproduz 90,4% dos próprios tokens, porque o prompt é reconstruído no Mac. A aceitação é medida contra os
     tokens que o iPhone gerou de fato.
   - Os tensores MTP usados batem byte a byte com o checkpoint oficial `Qwen/Qwen3.5-2B`.
   - **Ressalvas:**
     - o rascunho da MTP precisa da projeção no vocabulário (248k × 2048), que custa uma fração relevante de uma
       passada;
     - o decode real no iPhone é em pipeline (~23,6 ms/token, não 32,8);
     - **o ganho de ponta a ponta só se sabe medindo no aparelho.**
2. **Custo da especulação no iPhone:** pendente (protótipo). O `mlx-swift-lm` reverte o estado recorrente com um
   checkpoint dentro da própria passada de verificação (`checkpointAfter`), sem reprocessar.
3. **Térmica: o fator dominante.** Com decode contínuo sem pausa, o Qwen3.5 caiu de **45,8 tok/s** (frio) para
   ~30 tok/s em 1 minuto e para **14,0 tok/s** depois de ~17 minutos, ou seja, −69%
   ([thermal-soak-qwen.jsonl](../../results/runtime/thermal-soak-qwen.jsonl)).
   - Os benchmarks com espera térmica medem o regime "morno".
   - **Qualquer método precisa ser avaliado também sob estrangulamento,** e reduzir o trabalho total (não só a
     latência) passa a importar.
4. **Texto antes ou depois das chamadas:** não há falatório (1,5 token em média antes das chamadas).

## MTP no iPhone: a primeira medição real (2026-11-10)

O protótipo (`MobileLLMCore/MTPDraft.swift`, opção `mtp_block` do servidor, build `MLX_LM_MAIN`) esbarrou em três
limites do `mlx-swift-lm` no celular:

1. **Cache quente:** com o prefixo persistente ou o cache incremental, a biblioteca recusa a MTP ("stateful MTP
   drafter cannot initialize from a warm target suffix"). O drafter tem cache próprio e precisa do prompt inteiro.
2. **Memória:** sem cache, com o prompt de 6,7k tokens do BFCL, o iOS mata o app (jetsam, 5,7 GB). Para entregar o
   estado ao drafter, o alvo calcula os logits do vocabulário inteiro (248k) em todas as posições do prompt.
3. **Velocidade, prompt curto, sem ferramentas, 400 tokens:**
   - aceitação real de **74,6%** (170 de 228 rascunhos);
   - mas **42 tok/s contra 46 sem MTP**;
   - e a saída **não é idêntica**: a numérica da verificação em lote muda a trajetória greedy.

**Por que não acelerou, e o modelo de custo que explica:**
- No iPhone, o decode comum é **em pipeline**: a CPU monta a próxima passada enquanto a GPU calcula. Custa
  ~21,7 ms/token, bem abaixo dos 32,8 ms de uma passada sincronizada.
- Cada rodada especulativa precisa **sincronizar** para saber o que foi aceito. Ela custa verificar T = 2 (32,5 ms)
  mais o rascunho (~8 ms, quase todo na projeção no vocabulário de 248k), ~41 ms, e produz 1,75 token. Isso dá
  23,5 ms/token, ou seja, **0,92×**, como foi medido.
- **Para ganhar,** é preciso tirar a sincronização (especulação em pipeline) e baratear o rascunho (projetar só num
  vocabulário reduzido de candidatos). Com ~23 ms de verificação e ~2 ms de rascunho, o mesmo 1,75 token/rodada dá
  ~1,5×.

**Isso redefine a contribuição:** não é "usar MTP", é tornar a especulação vantajosa num celular. São três
ingredientes:
1. modelo de custo do aparelho (pipeline × sincronização);
2. rascunho com vocabulário reduzido;
3. estado do drafter persistido junto com o prefixo e entre turnos.

## Depois dos testes

Se A′ passar: protótipo no servidor do iPhone (MTP + rascunho por cópia + gramática, escalonador por custo),
verificação de saída idêntica no DEV, depois um TEST congelado com protocolo próprio, no build novo e nos modelos que
tiverem drafter.

## Etapa 1: cabeça MTP própria e especulação em pipeline (2026-11-10)

**O que foi feito** (build `MLX_LM_MAIN`, só no Qwen3.5-2B):
- [`MobileLLMCore/MTPHead.swift`](../../MobileLLMCore/MTPHead.swift): a camada MTP oficial reescrita em Swift (pesos
  `mtp.*` do checkpoint `Qwen/Qwen3.5-2B`) e o embedding atado do alvo em 4 bits para a projeção do rascunho.
- [`MobileLLMCore/MTPPipeline.swift`](../../MobileLLMCore/MTPPipeline.swift): o iterador `MTPPipelineIterator`
  (opção `mtp_pipe` do servidor):
  - cada rodada verifica `[y, d]` e roda a MTP no mesmo grafo;
  - o próximo par sai na GPU com `which`, nos dois desfechos;
  - a rodada seguinte entra na fila antes de a CPU ler a atual, e a CPU espera ~1 ms por geração;
  - na rejeição, a rodada seguinte é descartada e o estado recorrente volta pelo checkpoint que o próprio modelo
    salva dentro da passada, sem reprocessar;
  - rascunho no vocabulário inteiro (`full`) ou reduzido (`subset`: tokens do prompt e já gerados, ~600 ids).
- Diagnóstico `/v1/debug/mtp` ([`analysis/runtime/mtp_head_check.py`](../../analysis/runtime/mtp_head_check.py)) e
  comparação A/B ([`analysis/runtime/mtp_device.py`](../../analysis/runtime/mtp_device.py)).

**Medido no iPhone:**
1. **Cabeça própria, sem especular** (5 passos do TEST, contexto de 5,5k a 7,9k tokens,
   [mtp-head-device.jsonl](../../results/runtime/mtp-head-device.jsonl)):

   | | Aceitação | Custo sincronizado |
   |---|---|---|
   | vocabulário inteiro | 87–95% | 5,8–6,3 ms |
   | vocabulário reduzido | 80–90% | **0,31–0,45 ms** |

   A camada MTP custa 3,5–4,4 ms e o passo do alvo, 29,5–36 ms.
2. **Pipeline, primeiro passo, aparelho frio:** 42,2 tok/s sem MTP, 49,4 com o vocabulário inteiro e
   **54,8 (1,30×) com o reduzido**, com saída idêntica.
3. **10 passos** ([mtp-pipe-dev10.jsonl](../../results/runtime/mtp-pipe-dev10.jsonl)):
   - de 1,34× a 0,69×;
   - o aquecimento confunde a comparação (o próprio baseline cai de 42 para 30 tok/s);
   - aceitação real de 58–84%, abaixo do diagnóstico;
   - 5 de 10 saídas diferem do baseline (numérica da passada de 2 tokens).
4. **Contexto da MTP:** com 256 tokens ou com o prompt inteiro, a aceitação é a mesma (75/75, 84/79, 80/83%), então
   **persistir o estado do drafter (etapa 3) não compensa e foi cortado.**

**Modelo de custo do pipeline:**
- Com aceitação *a*, cada rejeição descarta a rodada que já estava na fila.
- O rendimento é (1 + a)/(2 − a) tokens por rodada de GPU: 1,5 com a = 0,8, e 1,73 com a = 0,9.
- No aparelho frio, a rodada custou 1,15× um passo do decode comum (27,3 contra 23,7 ms). A previsão é de ~1,3×,
  como medido. **A aceitação é a alavanca.**

## Etapa 2: vocabulário reduzido e escalonador por custo (2026-11-10)

**Vocabulário reduzido + ids frequentes** (10 passos, aparelho morno,
[mtp-pipe-top.jsonl](../../results/runtime/mtp-pipe-top.jsonl)):

| Condição | Ganho (média geométrica) | Aceitação |
|---|---|---|
| reduzido | 1,048× | 77,7% |
| + ids 0–4095 | 1,029× | 80,0% |
| + ids 0–16383 | 1,059× | 81,4% |

**Escalonador por custo (`mtp_gate`).** A rodada seguinte só entra na fila antes da leitura da atual se a
confiança da MTP no rascunho for ≥ limiar.
- Enfileirar arrisca perder uma rodada (r ≈ 27 ms); não enfileirar custa a espera da CPU (b ≈ 9 ms).
- Pelo modelo de custo, vale enfileirar se P(aceite) > 1 − b/r ≈ 0,67.
- A confiança já foi calculada na rodada anterior, que já foi lida: decidir não custa nada.

Resultado (10 passos, reduzido + 16k, [mtp-pipe-gate.jsonl](../../results/runtime/mtp-pipe-gate.jsonl)):

| Limiar | Ganho | Pior passo | Rodadas desperdiçadas |
|---|---|---|---|
| 0 (sempre na fila) | 1,041× | 0,88× | 257 |
| 0,5 | 1,150× | 1,00× | 121 |
| **0,7** | **1,179×** | **1,03×** | 74 |

**Calibração:** a aceitação sobe de forma monotônica com a confiança da MTP, de 0,26 (confiança 0,2–0,3) a 0,96
(0,9–1,0, que concentra 59% dos rascunhos). Ela cruza ~0,67 entre 0,6 e 0,7, onde o modelo de custo previa.

**Pendente:** só 3 de 10 saídas são idênticas às do decode sem MTP (a passada de 2 tokens muda a numérica). O acerto
tem de ser medido no DEV.

## DEV da especulação MTP (2026-11-11, [mtp-dev.md](mtp-dev.md), [decisão](mtp-dev-decision.json))

- **Acerto:** 8/24 nas duas condições, sem nenhuma tarefa perdida ou ganha. 14 de 24 trajetórias são idênticas.
- **Decode:** 36,5 → 29,2 s por tarefa (−20%).
- **Tempo por tarefa:** 49,2 s → −4,8 s (−9,7%), com IC95% [−10,5; +1,3] s. **O critério H1 falhou por pouco** e, pela
  regra pré-registrada, o TEST não rodou.
- **Leitura:** o ganho no decode existe, mas com 24 pares e variância alta entre tarefas o IC cruza zero. O próximo
  passo tem de decidir entre aumentar n (mais repetições no DEV) e aumentar o ganho, antes de qualquer TEST.

## Rumo (2026-11-11, pedido do autor): uma estratégia só, comprovada em todos os SLMs

- **A estratégia final é a combinação das opções do servidor:** prefixo persistente + guardas de decode + DAC +
  especulação em pipeline com escalonador por custo. Para ser usável no app, o app principal tem de passar para o
  `mlx-swift-lm` novo (hoje a MTP só existe no build `MLX_LM_MAIN`; os ajustes de compatibilidade estão em
  `MLXCompat.swift`).
- **A contribuição é o pipeline sem sincronização + o escalonador**, que não dependem da fonte do rascunho; basta um
  rascunho com confiança. Fontes por modelo:

  | SLM | Rascunho |
  |---|---|
  | Qwen3.5-2B | camada MTP oficial (feito) |
  | MiniCPM5, LFM2.5 | drafters oficiais DSpark |
  | LFM3 | drafter da comunidade |
  | Gemma 4 E2B | modelo assistente (suporte no `mlx-swift-lm` novo) |

- **Ordem:**
  1. Qwen3.5: cortar o custo do prefill da MTP, depois um DEV novo com prefixo aquecido e 4 repetições, depois o TEST;
  2. o mesmo iterador com cada drafter, com DEV e TEST por modelo;
  3. migração do app principal.

## DEV 2 (2026-11-11, prefixo aquecido, [mtp-dev2.md](mtp-dev2.md)): passou

Resultado com 48 pares, térmica toda nominal:
- **Acerto:** 16/48 nas duas condições, sem nenhuma tarefa perdida.
- **Tempo por tarefa:** 47,3 s → −6,2 s (**−13,1%**), IC95% [−8,4; −4,0] s.
- **Decode:** 37,1 → 30,0 s.
- **Trajetórias:** 28 de 48 idênticas.

TEST 2 congelado em [PROTOCOL-TEST-mtp2.md](PROTOCOL-TEST-mtp2.md) e iniciado às 10:36.
