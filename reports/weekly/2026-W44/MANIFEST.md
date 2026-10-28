# Manifesto de reprodutibilidade — 2026-W44

Gerado em 2026-10-28T12:29:37Z UTC por `analysis/weekly/generate.py`.
Este arquivo descreve como os números da semana foram obtidos. **Não** relança inferência.

## Separação de máquinas

1. **iPhone:** geração greedy (temperature 0), `mlx-swift-lm` 3.31.4, protocolo `slm_bfcl_v4_ast` / 2.0.
2. **Mac:** `analysis/slm_bfcl/evaluate.py` chama o `ast_checker` de `bfcl-eval` 2026.3.23 (instalado neste ambiente: 2026.3.23).
3. **Mac:** `analysis/weekly/generate.py` e `analysis/slm_bfcl/analyze.py` só leem JSON/JSONL já gravados.

## Ambiente de inferência (das sessões r1)

| Campo | Valor |
|---|---|
| Aparelho | iPhone17,1 (iPhone 16 Pro) |
| Sistema | Version 26.6.2 (Build 23G90) |
| App | MobileLLMBench |
| `mlx-swift-lm` | 3.31.4 |
| Amostragem | greedy, temperature 0 |
| `seedAffectsSampling` | false (registrado nas sessões) |
| Seed de ordem r1 | `20261027` |
| Dataset | `bfcl_ast` / `bfcl_v4_ast_frozen_40` |
| `evaluationVersion` | `bfcl-v4-ast-official-checker-mac` |
| Warmup | True |
| `requireCoolThermal` | False |
| Python do gerador | 3.11.9 |
| Git HEAD | `50a59e1bac02b9c3c3e5afc4edde4d4bd497209a` |

## Amostra BFCL

| Campo | Valor |
|---|---|
| `bfcl-eval` (freeze) | 2026.3.23 |
| Seed da amostra | 20261027 |
| Por categoria | 8 |
| Categorias | simple_python, multiple, parallel, parallel_multiple, irrelevance |
| Congelada antes da execução | True |

SHA-256 das fontes oficiais: ver [selection.json](../../slm-bfcl/selection.json).

## Sessões r1 (inferência)

| Arquivo | Agente | Measured | Finished | Seed | Checkpoint | SHA-256 |
|---|---|---|---|---|---|---|
| main-r1-gemma4.json | gemma4 | 240 | True | `20261027` | `mlx-community/gemma-4-e2b-it-4bit@238767527555cb75a05732a84dff5d6ba0dd6809` | `736aff4b4886` |
| main-r1-lfm25.json | lfm25 | 160 | True | `20261027` | `LiquidAI/LFM2.5-2.6B-MLX-4bit@04efa23776ce61ec34ec95ec34c859854c89542b` | `ce1a8b18b25d` |
| main-r1-minicpm5.json | minicpm5 | 240 | True | `20261027` | `openbmb/MiniCPM5-2B-MLX@8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3` | `073f96f711ba` |
| main-r1-qwen35.json | qwen35 | 240 | True | `20261027` | `mlx-community/Qwen3.5-2B-4bit@674aaa7240b91e8012fcad5d791b7dfe5ba90207` | `1b1939d33223` |

## Repetição 2

| Modelo | Estado | Measured | Graded | Sessão |
|---|---|---|---|---|
| MiniCPM5-2B | completa | 80 | 80 | rep2-minicpm5.json |
| LFM2.5-2.6B | ausente | 0 | 0 | — |
| Gemma 4 E2B | incompleta | 47 | 0 | rep2-gemma4.json |
| Qwen3.5-2B | ausente | 0 | 0 | — |

## Arquivos de evidência

| Caminho | SHA-256 (prefixo) | Bytes |
|---|---|---|
| `results/slm-bfcl/main-r1-graded.jsonl` | `5f3cd4ad0510…` | 846357 |
| `analysis/weekly/weeks/2026-W44.json` | `41d1d140eb79…` | 919 |
| `analysis/weekly/generate.py` | `3272b2c02046…` | 33088 |
| `reports/slm-bfcl/selection.json` | `2dc2b65ac903…` | 3178 |
| `reports/slm-bfcl/REPORT.md` | `5b81820bee41…` | 12451 |
| `MobileLLMBench/BFCLv4AST.json` | `918a3f5516a4…` | 69009 |
| `analysis/slm_bfcl/evaluate.py` | `704d79381c59…` | 8071 |
| `analysis/slm_bfcl/analyze.py` | `e90e223ce265…` | 8768 |
| `analysis/slm_bfcl/freeze_sample.py` | `4f3ecbbbb11b…` | 2859 |
| `analysis/slm_bfcl/run_sessions.sh` | `e39207eded44…` | 906 |
| `analysis/slm_bfcl/device.sh` | `375a911a5f13…` | 1167 |
| `results/slm-bfcl/main-r1-gemma4.json` | `736aff4b4886…` | 1197641 |
| `results/slm-bfcl/main-r1-lfm25.json` | `ce1a8b18b25d…` | 810406 |
| `results/slm-bfcl/main-r1-minicpm5.json` | `073f96f711ba…` | 1245419 |
| `results/slm-bfcl/main-r1-qwen35.json` | `1b1939d33223…` | 1185004 |
| `results/slm-bfcl/rep2-gemma4.json` | `b1c8745e16f1…` | 216062 |
| `results/slm-bfcl/rep2-minicpm5.json` | `c2220e9bb653…` | 338611 |
| `results/slm-bfcl/rep2-minicpm5-graded.jsonl` | `f5e5dfd3e9cc…` | 76469 |

Digests SHA-256 completos:

```json
{
 "results/slm-bfcl/main-r1-graded.jsonl": "5f3cd4ad05104d1b1398758a54402c7a962020ef41ac07c6d393c4c4204ff41e",
 "analysis/weekly/weeks/2026-W44.json": "41d1d140eb795fcae537a304660c25cc40a22651277216f602e5f650332ff775",
 "analysis/weekly/generate.py": "3272b2c0204693b8da50ec891220dd6cd21cb51b09326872976bc2f515fdbf1a",
 "reports/slm-bfcl/selection.json": "2dc2b65ac903e18d18b02c1202b8a85887ca8055d702f9a6021a5a25bb6519b4",
 "reports/slm-bfcl/REPORT.md": "5b81820bee41828ca8471272c2890392e5bb546ed534bd472766538770dde614",
 "MobileLLMBench/BFCLv4AST.json": "918a3f5516a4e5e3fefbf48df4a570f99037b702d13214f3daf68e00af2667ca",
 "analysis/slm_bfcl/evaluate.py": "704d79381c5977d71e376b2b235320ef7914974fcf5821fcbf4c4346e268593a",
 "analysis/slm_bfcl/analyze.py": "e90e223ce2650265d61e8de5e54ec4b1ab5c939366415c51db186b1bdcd4ea7c",
 "analysis/slm_bfcl/freeze_sample.py": "4f3ecbbbb11b4533b0097a2ec61296e4b27698f6558797c3f9c177f1721c21c0",
 "analysis/slm_bfcl/run_sessions.sh": "e39207eded440183c49e49c886df46fe2adc4a16d8fa76a289b52d46e49eec37",
 "analysis/slm_bfcl/device.sh": "375a911a5f1383c0be27f855fc365e4427bc5bff1a854a37ec47f29e9c9cc233",
 "results/slm-bfcl/main-r1-gemma4.json": "736aff4b4886fb82cf4f6a9eaba8b8fedced9288449deb4ff0d92e31ce31dea7",
 "results/slm-bfcl/main-r1-lfm25.json": "ce1a8b18b25d3cd85c5df71f1d1ea2f8da2853d44d686fd80099a67fbf5a7ee6",
 "results/slm-bfcl/main-r1-minicpm5.json": "073f96f711bac7d9fd62d88080997ccdf8b81e10cbda30bbe1a9e1a55592c2f4",
 "results/slm-bfcl/main-r1-qwen35.json": "1b1939d33223a63fb440916c58dbc7215d3d1839ef394987cdf53be56273a24b",
 "results/slm-bfcl/rep2-gemma4.json": "b1c8745e16f1d046f31629d45b8fb47db5c52c9212aa7cf4d425d6aaa774799f",
 "results/slm-bfcl/rep2-minicpm5.json": "c2220e9bb653ae0c8d7e5512c3568190db2c2cf8188cc0867db266fde5ed5f51",
 "results/slm-bfcl/rep2-minicpm5-graded.jsonl": "f5e5dfd3e9cc1e186145c0e466279b610e20ab0d2e398c6fb25d6d923faee5de"
}
```

## Comandos (não incluem inferência no iPhone)

```bash
# Reavaliar sessões já puxadas do aparelho (Mac, checker oficial)
.bfcl-venv/bin/python analysis/slm_bfcl/evaluate.py \
  results/slm-bfcl/main-r1-minicpm5.json \
  results/slm-bfcl/main-r1-lfm25.json \
  results/slm-bfcl/main-r1-gemma4.json \
  results/slm-bfcl/main-r1-qwen35.json \
  --out results/slm-bfcl/main-r1-graded.jsonl

# Tabelas cruas (mesmo cálculo deste relatório)
python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl

# Relatório semanal
python3 analysis/weekly/generate.py 2026-W44
```

Inferência no iPhone (não executada por este gerador): `analysis/slm_bfcl/run_sessions.sh` + `analysis/slm_bfcl/device.sh`.
Amostra: `.bfcl-venv/bin/python analysis/slm_bfcl/freeze_sample.py`.

## O que este manifesto não cobre

- ToolSandbox / interações sequenciais com ferramentas.
- Repetição 2 de LFM2.5, Gemma 4 e Qwen3.5 como resultado (ver tabela "Repetição 2": ausentes ou interrompidas).
- Smoke tests (`results/slm-bfcl/smoke*.json`), excluídos da tabela principal.
