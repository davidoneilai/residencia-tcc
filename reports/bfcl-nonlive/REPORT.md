# BFCL v4 Non-Live no iPhone: Direct × Reasoning × Adaptive

Qwen3.5-2B-4bit, iPhone 16 Pro, scorer oficial (`ast_checker` do `bfcl-eval` 2026.3.23), 2026-11-05.
Piloto (40) → DEV (80) → TESTE (160), com critérios escritos antes de cada etapa em `PREREGISTRATION.md`.
Tabelas geradas pelos scripts: `pilot-qwen35-tables.md`, `dev-qwen35-tables.md`, `test-qwen35-tables.md`.

## Conclusão (TESTE, 160 tarefas)

**A Adaptive mantém o acerto da Reasoning, mas não a torna mais barata. Não recomendo seguir com ela como otimização
de custo neste benchmark.** A Reasoning fixa é a configuração a reportar.

| TESTE (160) | Direct | Reasoning | Adaptive | Oracle D/R |
|---|---|---|---|---|
| Acerto | 108 (68 %) | 129 (81 %) | **130 (81 %)** | 141 (88 %) |
| Latência média | 23,4 s | 25,9 s | 27,6 s | |
| Até a 1ª chamada (mediana) | 9,4 s | 18,9 s | 18,4 s | |
| Tokens de saída (média) | 223 | 305 | 293 | |

- **H1, não inferioridade: passa.** Adaptive − Reasoning = +0,6 pp (IC95 −2,5 a +3,8), acima da margem de −5 pp.
- **H2, mais rápida que a Reasoning: não passa.** +1,7 s (IC95 −1,6 a +5,1).
  Em tokens, que não dependem da térmica: −13 por tarefa (IC95 −35 a +11), cerca de −4 %.
- Reasoning × Direct: +13,1 pp (IC95 +5,6 a +21,2; McNemar p = 0,002). O ganho está quase todo em `parallel` (14 → 29 de 32).
  Direct só ganha em `irrelevance` (24 × 18).
- A complementaridade existe: oracle 141/160, isto é, +12 tarefas sobre a Reasoning.
  - Só Reasoning acerta em 33 tarefas, 15 delas `parallel`.
  - Só Direct acerta em 12: 7 `irrelevance` e 4 `parallel_multiple`.

  A regra leve congelada captura só +1 dessas 12.

Por que a Adaptive não economiza:

1. **Roteia pouco.** Só 39 das 160 tarefas vão para Direct (24 `irrelevance`, 11 `multiple`, 4 `simple_python`).
   Nas outras 121 ela faz exatamente o que a Reasoning faz.
2. **Direct não é barata onde a regra a usa.** Em `irrelevance`, Direct responde em prosa longa:
   303 tokens contra 396 da Reasoning, e 4 respostas batem no teto de 1024.
   Nas 39 roteadas, a economia é de 18 % dos tokens, que vira 4 % no total.
3. **A latência ficou dominada pela térmica.** Nas 121 tarefas em que Adaptive e Reasoning geram os mesmos tokens
   (121/121 idênticos), a latência medida ainda difere em +3,0 s em média, com desvio de 19 s.
   O ganho de −14 % visto no DEV (sessões de ~25 min) não é detectável numa sessão de 3,7 h com throttling.

O que vale para o TCC:

- Num SLM de 2B no iPhone, o raciocínio completo paga: +13 pp no Non-Live, quase todo em chamadas paralelas.
- Uma regra leve antes da geração não captura a complementaridade que existe (+7,5 pp de oracle).
- Medir latência no aparelho exige sessões curtas ou pausas de resfriamento, e tokens como métrica de custo
  independente da térmica.

Se quiser insistir na Adaptive, o caminho não é outra regra de comprimento. Seriam duas linhas:
- um detector de irrelevância (onde Direct ganha);
- ou uma cascata pós-geração (Direct; se não chamou função e o pedido é acionável, refaz com Reasoning).

Qualquer uma precisa de novo DEV: o TESTE já foi usado.

## Recomendação após o piloto (histórico)

**Prosseguir, com uma condição.** Pelo critério pré-registrado o piloto passa (C1–C4: sim), mas por margem
mínima. Antes de gastar o TESTE:

1. Rodar Direct e Reasoning nos 40 IDs `dev_prior` com este build (~25 min). O DEV vira 80 tarefas.
2. Recalibrar a regra nas 80 e congelá-la. Se nenhuma regra que roteia superar as duas fixas no DEV de 80, **parar**.
   Conclusão nesse caso: no Non-Live, a escolha antes da geração não compensa e a Reasoning fixa basta.
3. Se passar, rodar Direct, Reasoning e Adaptive nas 160 de teste (~2,5 h). Hipótese a congelar:
   Adaptive não é inferior à Reasoning (margem de 5 pp) e é mais rápida que ela, com latência pareada.

Por que não um "sim" limpo: a melhor regra ganha da Reasoning por **1 tarefa** (`irrelevance_112`).
Nos 40 IDs `dev_prior` (dados do estudo SLM × AST, com o loader antigo do Qwen3.5), a mesma regra fica
**2 tarefas abaixo** da Reasoning e não é mais rápida (22,0 s × 21,2 s).

## Resultado

| | Direct | Reasoning | Oracle | Melhor regra (`n_params≥3→R`) |
|---|---|---|---|---|
| Acerto | 28/40 (70 %) | **31/40 (78 %)** | 33/40 (82 %) | 32/40 (80 %) |
| Latência média | **13,3 s** | 21,5 s | 12,7 s (de custo) | 19,0 s |
| Latência mediana | **8,2 s** | 13,8 s | | |
| Até a 1ª chamada (mediana) | **5,2 s** | 11,8 s | | |
| Tokens de entrada / saída | 491 / 208 | 489 / 354 (221 de raciocínio) | | |
| Parada por teto (1024) | 3 | 5 | | |

- Reasoning acerta 3 tarefas a mais e custa **+8,2 s por tarefa** (IC95 bootstrap pareado +4,1 a +12,7 s).
  A diferença de acerto não é significativa (McNemar exato p = 0,45; n = 40).
- **Complementaridade:** 26 ambas, **5 só Reasoning**, **2 só Direct**, 7 nenhuma.
  - Só Reasoning: simple_python ×2, multiple ×2, parallel ×1.
  - Só Direct: `multiple_186` e `irrelevance_112`.
- **Oracle:** 33/40, +2 sobre a melhor fixa. O oracle de custo (Direct quando ela acerta) mantém 33/40 em 12,7 s.
  Ele manda só 5 tarefas para Reasoning. É o teto do que uma Adaptive pode ganhar aqui.
- **Por categoria:** Reasoning ajuda em simple_python (+2) e multiple (+1, saldo de +2 e −1); empata em parallel_multiple;
  piora em irrelevance (4/8 × 5/8, chama função quando não devia).
- **Falhas da Direct (12):** 4 respondem em prosa em vez de chamar (`missing_call`; 2 delas a Reasoning acerta),
  3 chamam função em irrelevance, 3 erram argumentos, 1 erra a função e 1 bate no teto. Responder em prosa só se vê
  depois de gerar, então não é sinal antes da geração.

## A política Adaptive

Família fixada no pré-registro: só características do pedido e dos schemas, antes de gerar.

- A melhor regra no piloto: **total de parâmetros nos schemas ≥ 3 → Reasoning; senão Direct**.
  Manda 10 tarefas para Direct (6 ambas, 3 nenhuma, 1 só Direct).
  Resultado: 32/40 e 19,0 s, isto é, +1 tarefa e −2,5 s (−12 %) contra a Reasoning.
- Leave-one-out: escolhe a mesma regra nas 40 dobras; 32/40, 19,0 s. A seleção é estável, mas o ganho
  depende de uma tarefa.
- O `ASTRouter` já existente (funções ≥ 2 ou pista de pedido múltiplo): 30/40, 18,6 s. Abaixo da Reasoning.
- **Custo adicional da política:** 1,3 µs por tarefa no Mac (Python). No iPhone, o `ASTRouter` equivalente mediu
  0,015 ms (mediana de 40, estudo SLM × AST). Desprezível frente a segundos de geração.
- A Adaptive foi **simulada** a partir das duas fixas (greedy: a rota repete a saída da fixa escolhida).
  No experimento principal ela roda no aparelho.

| Critério pré-registrado | Valor | Passa |
|---|---|---|
| C1 complementaridade nos dois sentidos (≥ 2 e ≥ 2) | 2 só D, 5 só R | sim |
| C2 oracle − melhor fixa ≥ 2 | +2 | sim (no limite) |
| C3 R > D e oracle de custo ≥ 20 % mais rápido que R | 12,7 s × 21,5 s (−41 %) | sim |
| C4 regra que roteia recupera ≥ 50 % do ganho do oracle | +1 de +2 = 50 % (piloto e LOO) | sim (no limite) |

## Validade

- n = 40: o IC95 de cada acerto tem ~30 pp de largura. O piloto mede viabilidade, não superioridade.
- Térmica `serious` em 80/80 execuções; Direct e Reasoning intercaladas na mesma sessão (seed `20261105`),
  então a térmica pesa igual nas duas.
- Uma repetição, decodificação greedy. Latência da 1ª chamada: medida no stream (`astFirstCallMs`), n = tarefas com chamada.
- Tokens de raciocínio: contados no Mac com o tokenizer da mesma revisão do modelo, no texto até `</think>`. Quando o modelo pensa até o teto sem fechar `</think>`, conta a resposta inteira. Uma versão anterior contava 0 nesse caso e subestimava a média (corrigido em 2026-11-05).
- Parser: chamadas nativas do MLX em todas as linhas com chamada (63/63). Nenhum erro do app.

## O que mudou no harness

- `analysis/bfcl_nonlive/freeze_split.py`: split congelado em `selection.json`, com 3 grupos disjuntos.
  - `pilot`: 40 tarefas, DEV.
  - `test`: 160 tarefas, 32 por categoria, intocado.
  - `dev_prior`: os 40 IDs do estudo antigo.

  Exclui os 80 IDs usados antes. O app lê `BFCLv4NonLive.json` junto com o `BFCLv4AST.json`, que não foi alterado.
- `astFirstCallMs`: tempo até a 1ª chamada completa no stream. O campo antigo `timeToFirstToolCallMs` é cópia de
  `inferenceMs` e não serve para isso.
- `taskSetId` opcional no auto-run `bfcl-ast`; `OUTDIR` no `run_sessions.sh`, que se recusa a sobrescrever.
- `evaluate.py` ganhou colunas (1ª chamada, 1º texto, carga, task set). Os vereditos não mudam.
- Nada de HTTP nem simulador: o app gera no iPhone; o Mac avalia com o checker oficial.
- O BFCL Multi-Turn (`analysis/bfcl_mt`, `results/bfcl-mt`) ficou intacto.

## Reprodução

```sh
.bfcl-venv/bin/python analysis/bfcl_nonlive/freeze_split.py          # já feito; recusa sobrescrever
IPHONE_UDID=… OUTDIR=results/bfcl-nonlive analysis/slm_bfcl/run_sessions.sh pilot \
  '{"run":"bfcl-ast","strategies":["nothink","direct"],"taskIDs":[…pilot…],"seed":"20261105","taskSetId":"bfcl_v4_nonlive_pilot_40"}' qwen35
.bfcl-venv/bin/python analysis/bfcl_nonlive/pilot.py results/bfcl-nonlive/pilot-qwen35.json
```

| Arquivo | Conteúdo |
|---|---|
| `results/bfcl-nonlive/pilot-qwen35.json` | sessão crua do iPhone (sha256 `339eccb7…`) |
| `results/bfcl-nonlive/pilot-qwen35-graded.jsonl` | 80 linhas avaliadas, com config, versões e seed |
| `results/bfcl-nonlive/pilot-qwen35-rows.csv` | o mesmo em CSV |
| `results/bfcl-nonlive/pilot-qwen35-paired.csv` | 1 linha por tarefa: D × R, classe, features, oracle |
| `reports/bfcl-nonlive/pilot-qwen35-summary.json` | todas as métricas, regras e critérios |
| `results/bfcl-nonlive/smoke-qwen35.json` | smoke de 2 tarefas usado para validar o pipeline |

## Etapa 2: DEV de 80 e política congelada (2026-11-05, 13:56)

`dev_prior` rerodado com o mesmo build (80/80 execuções, sem erro; térmica `serious` em 76/80).
DEV = pilot + dev_prior = 80 tarefas. Tabelas: `dev-qwen35-tables.md`.

| DEV (80) | Direct | Reasoning | Oracle | Regra congelada |
|---|---|---|---|---|
| Acerto | 54 (68 %) | **65 (81 %)** | 68 (85 %) | **65 (81 %)** |
| Latência média | 12,8 s | 18,7 s | 12,1 s (de custo) | **16,1 s (−14 % × Reasoning)** |
| Até a 1ª chamada (mediana) | 4,7 s | 10,9 s | | |

- Complementaridade: 51 ambas, 3 só Direct, **14 só Reasoning**, 12 nenhuma.
  No DEV de 80 a Reasoning domina mais do que no piloto.
- **Regra congelada:** pedido com 64 code points ou mais → Reasoning; senão Direct. Manda 18/80 para Direct.
  - Empata com a Reasoning em acerto, com 14 % menos latência.
  - Leave-one-out: 65/80, 15,9 s (limiar 64 em 60 dobras e 68 em 20).
- **Portão pré-registrado: passa.** Acerto = melhor fixa e latência ≥ 10 % menor; LOO a no máximo 1 tarefa.
- **Ressalva:** 14 das 18 tarefas que vão para Direct são `irrelevance`. A regra funciona como detector de
  "pergunta curta, sem ferramenta aplicável". É legítima, porque o comprimento é conhecido antes de gerar.
  Em parte, porém, reflete a distribuição do BFCL, onde as perguntas irrelevantes são curtas.
- Os critérios C1–C4 do piloto, recalculados no DEV de 80, dão C4 = não: nenhuma regra recupera 50 % do ganho do oracle em acerto.
  O ganho possível aqui é de **latência com o acerto da Reasoning**, não de acerto. É isso que H1 e H2 testam.
- Política e rota prevista para cada tarefa do TESTE (121 → Reasoning, 39 → Direct):
  `FROZEN_POLICY.json`, gerado antes de qualquer execução no TESTE.

## Etapa 3: TESTE (160), política congelada executada no iPhone

Sessão `96516063…`, `bfcl_v4_nonlive_test_160`. 480 execuções + warmup, ordem embaralhada (seed `20261105`), sem erro do app.
Tabelas completas: `test-qwen35-tables.md`; por tarefa: `results/bfcl-nonlive/test-qwen35-pertask.csv`.

- **Integridade da política:**
  - as 160 rotas da Adaptive batem com `FROZEN_POLICY.json` (121 → Reasoning, 39 → Direct);
  - a Adaptive executada reproduz a simulada em 160/160 vereditos e 160/160 contagens de tokens;
  - custo da decisão no iPhone: mediana 0,006 ms, máximo 0,037 ms.
- **Por categoria (acerto D / R / A):**

  | Categoria | Direct | Reasoning | Adaptive |
  |---|---|---|---|
  | simple_python | 25 | 29 | 29 |
  | multiple | 28 | 31 | 29 |
  | parallel | 14 | 29 | 29 |
  | parallel_multiple | 17 | 22 | 22 |
  | irrelevance | 24 | 18 | 21 |

  Em `multiple` a Adaptive perde 2 tarefas por mandar pedidos curtos para Direct.
  Em `irrelevance` ela ganha 3 sobre a Reasoning.
- **Interrupções** (`results/bfcl-nonlive/test-resumes.log`). A sessão foi retomada com `resume`, sem refazer
  jobs já gravados:
  - queda do cabo (~14:06); o app seguiu rodando e parou às 14:27;
  - app fechado (14:50);
  - pausa para resfriar (16:15), encerrada a pedido após ~1 min.

  O Mac dormiu entre 15:52 e 16:13; o iPhone seguiu rodando.
- **Throttling:** o decode caiu de 32 para 13 tok/s ao longo da sessão, com a térmica em `serious` o tempo todo.
  A ordem embaralhada espalha isso pelas três estratégias, mas a latência fica ruidosa (ver Conclusão).
  Decode médio: Direct 23,5, Reasoning 19,6 e Adaptive 19,5 tok/s.
  As gerações curtas da Direct rodam mais rápido por token.

### Reprodução do TESTE

```sh
IPHONE_UDID=… OUTDIR=results/bfcl-nonlive analysis/slm_bfcl/run_sessions.sh test \
  '{"run":"bfcl-ast","strategies":["nothink","direct","adaptive_nonlive"],"taskIDs":[…test…],"seed":"20261105","taskSetId":"bfcl_v4_nonlive_test_160"}' qwen35
.bfcl-venv/bin/python analysis/bfcl_nonlive/test.py results/bfcl-nonlive/test-qwen35.json
```

| Arquivo | Conteúdo |
|---|---|
| `results/bfcl-nonlive/test-qwen35.json` | sessão crua do iPhone |
| `results/bfcl-nonlive/test-qwen35-graded.jsonl` / `-rows.csv` | 480 linhas avaliadas pelo checker oficial |
| `results/bfcl-nonlive/test-qwen35-pertask.csv` | 1 linha por tarefa: D, R, A, rota, latências, tokens |
| `reports/bfcl-nonlive/test-qwen35-summary.json` | H1, H2, comparações pareadas, integridade |
| `reports/bfcl-nonlive/FROZEN_POLICY.json` | política e rotas previstas, congeladas antes do TESTE |
| `results/bfcl-nonlive/devprior-qwen35.json`, `dev-qwen35-*` | DEV de 80 |
