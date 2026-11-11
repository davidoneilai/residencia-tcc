# Relatórios semanais

Ponto de entrada para a banca. Cada semana aponta para as evidências onde elas já estão (`results/`, `reports/`, `mobile-adaptive-inference/`); nada é copiado.

Semana 1 = 2026-W37 (início do repositório, 2026-09-10). Até a Semana 8, cada semana é uma semana ISO; **a partir da Semana 9, cada semana vai de uma entrega à seguinte** e pode ter mais ou menos de 7 dias. A semana de cada artefato versionado vem da data do commit ou, na falta dele, da data do arquivo. As Semanas 2 e 3 **não têm artefato versionado**; o que se registra abaixo é o trabalho de revisão bibliográfica, não um experimento.

| Semana | ISO | Período | O que foi feito | Evidência |
|---|---|---|---|---|
| 1 | 2026-W37 | 07–13 set | Revisão inicial (LLMs agênticos, inferência on-device, alocação adaptativa de computação) e MVP Android, independente da linha iOS | MVP Android retirado do repo em 10/11; continua no git (`git log -- AndroidLLMBench`) |
| 2 | 2026-W38 | 14–20 set | Continuação da revisão. **Sem artefato versionado** | — |
| 3 | 2026-W39 | 21–27 set | Encerramento da revisão e definição do recorte experimental. **Sem artefato versionado** | — |
| 4 | 2026-W40 | 28 set–04 out | Início do MobileLLMBench no servidor: plano experimental e fatia BFCL v4 (40 IDs) em GPU (vLLM; Qwen3-1.7B e Gemma 4 E2B) | plano (no git: `git show 8f42798:docs/plans/2026-09-29-mobile-adaptive-inference.md`), [relatório GPU](../../mobile-adaptive-inference/results/relatorio-bfcl.md), [protocolo](../../mobile-adaptive-inference/README.md) |
| 5 | 2026-W41 | 05–11 out | Primeiras matrizes no iPhone: Apple Foundation Models, Qwen3 e Gemma 4, com ferramentas do aparelho e estratégias de raciocínio | entrega 08/10 (no git: `git show 5d75709:docs/entrega_2026-10-08.txt`), [matriz](../../results/iphone16pro_matriz_2026-10-08.json), [Qwen thinking](../../results/iphone16pro_qwen_thinking_2026-10-08.json) |
| 6 | 2026-W42 | 12–18 out | Protocolo 2 no app; smoke e sessão cross-model no iPhone | [smoke](../../results/smoke-2026-10-12/report.md), [cross-model](../../results/cross-model-2026-10-13.json) |
| 7 | 2026-W43 | 19–25 out | Roteamento adaptativo entre execução direta e planejamento (offline, 3 reps on-device, v2, held-out v3); MVP de chat; piloto de orçamento reativo | [roteamento](../adaptive-routing/REPORT.md), [variância 3 reps](../adaptive-routing/on-device/VARIANCE_3REP.md), [v2](../adaptive-routing/v2/REPORT.md), [v3 held-out](../adaptive-routing/v3/REPORT.md), [chat MVP](../chat-agent-mvp/REPORT.md), [chat adaptativo](../chat-adaptive-pilot/REPORT.md), [orçamento reativo](../adaptive-inference/pilot/REPORT.md) |
| 8 | 2026-W44 | 26 out–01 nov | AdaptiveStep e ActionAware (exploratórios); avaliação de quatro SLMs no BFCL v4 AST (turno único, 880 execuções); piloto iOSWorld `clock-001` | **[relatório da semana](2026-W44/README.md)**, **[status 29/10 (orientação)](../status/2026-10-29.md)**, [AdaptiveStep](../adaptive-inference/step-pilot/REPORT.md), [ActionAware](../adaptive-inference/action-aware/REPORT.md), [estudo SLM](../slm-bfcl/REPORT.md) |
| **9** | 2026-W45–W46 | **02–13 nov** (entrega) | BFCL Non-Live (Adaptive e orçamentos: negativos); BFCL **Multi-Turn** no iPhone: estudo DAC, prefixo persistente, **pilha** em 4 SLMs, LoRA de SFT (negativo, verificado) e **TEST final: −31% a −63% de tempo sem perda significativa de acerto**; app dividido em Bench e Chat | **[relatório da semana](2026-W45-W46/README.md)**, [estudo de runtime](../runtime/README.md), [DAC](../dac/dev-r1-r3.md), [Non-Live](../bfcl-nonlive/REPORT.md) |

Só a Semana 8 tem relatório gerado por script, com manifesto de reprodutibilidade. A Semana 9 é escrita à mão sobre os relatórios e protocolos de cada estudo, com os números conferidos nos arquivos. As anteriores têm os relatórios da época, cada um com a sessão bruta ao lado.

## Semanas 1–3 (revisão; sem experimento on-device versionado)

Não há sessões JSON nem tabelas dessas três semanas no Git. O trabalho documentado foi de leitura: o que um LLM pequeno consegue fazer com ferramentas, o que muda quando a inferência sai do servidor e vai para o aparelho, e como a literatura aloca computação de forma condicional (por token, por consulta ou por agente).

Trabalhos lidos nesse período, com página oficial:

| Tema | Referência | Ligação |
|---|---|---|
| LLM sub-bilhão para dispositivo | Liu et al., *MobileLLM*, ICML 2024 | [PMLR](https://proceedings.mlr.press/v235/liu24ce.html) |
| Alocação dinâmica de FLOPs no transformer | Raposo et al., *Mixture-of-Depths* | [arXiv:2404.02258](https://arxiv.org/abs/2404.02258) |
| Roteamento entre modelos forte/fraco | Ong et al., *RouteLLM*, ICLR 2025 | [OpenReview](https://openreview.net/forum?id=8sSqNntaMr), [arXiv:2406.18665](https://arxiv.org/abs/2406.18665) |
| Agentes multimodais com ferramentas | Ashraf et al., *Agent-X* | [arXiv:2505.24876](https://arxiv.org/abs/2505.24876) |

Esses textos informam o desenho posterior (MobileLLMBench, políticas Direct/NoThink/Budget/Plan+Act, roteadores). Não são resultados desta residência.

## Gerar ou atualizar uma semana

```bash
python3 analysis/weekly/generate.py 2026-W44
python3 analysis/weekly/generate.py --check
```

A definição da semana (arquivos lidos, repetições esperadas) está em `analysis/weekly/weeks/YYYY-WXX.json`. O gerador só lê arquivos já gravados; não relança inferência no iPhone.

| Arquivo da semana | Conteúdo |
|---|---|
| `README.md` | Relatório |
| `tables.md` | Tabelas completas (mesmo cálculo de `analysis/slm_bfcl/analyze.py`) |
| `figures/` | Qualidade × latência, estratégias, decomposição da latência |
| `MANIFEST.md` | Checkpoints, versões, seeds, hashes, comandos |
| `summary.json` | Números serializados para conferência |
