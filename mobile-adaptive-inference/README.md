Inferência local com vLLM e benchmarks oficiais. Cada estratégia muda uma coisa só; o resto do protocolo fica fixo.

## Protocolo

| | |
| --- | --- |
| Modelos | `Qwen/Qwen3-1.7B` (`qwen3_1.7b`), `google/gemma-4-E2B-it` (`gemma4_e2b`) |
| Hardware | NVIDIA B200, slice MIG `3g.90gb`, uma GPU, sem tensor parallel |
| Software | `nvcr.io/nvidia/pytorch:26.01-py3` (CUDA 13.1, PyTorch 2.10), vLLM 0.29, `bfcl-eval` |
| Geração | temperatura 0, concorrência 1, `max_tokens` 512 (inclui o raciocínio), `max_model_len` 8192 |
| BFCL | v4 non-live, 10 primeiros IDs de `simple_python`, `multiple`, `parallel`, `parallel_multiple` (`config.yaml`) |
| Acerto | checker oficial do BFCL por ID |
| Eficiência | `agent_inference_ms` (só a inferência do agente), `prompt_tokens`, `output_tokens`, `model_calls` |
| Energia | não medida na GPU: o slice MIG devolve potência `N/A` e a leitura do GPU inteiro misturaria os outros slices |

`agent_inference_ms`, tokens e `model_calls` somam todas as chamadas ao vLLM do episódio. Estratégias que chamam o modelo mais de uma vez (plan+act, budgets, early-exit) pagam isso na métrica.

## Estratégias

| `--strategy` | Servidor | O que muda |
| --- | --- | --- |
| `direct` | sem prefix cache | referência |
| `prefix` | prefix cache ligado | só o servidor |
| `speculative` | ngram (Qwen) / MTP (Gemma) | só o servidor |
| `eagle3` | EAGLE-3, `AngelSlim/Qwen3-1.7B_eagle3`, 2 tokens | só o servidor, só Qwen |
| `plan_act` | igual ao direct | plano de até 128 tokens, depois a ação |
| `nothink` | igual ao direct | `<think></think>` vazio no prompt |
| `budget64`, `budget128`, `budget256` | igual ao direct | pensa até N tokens, fecha `</think>` e responde (budget forcing do s1) |
| `early_exit` | igual ao direct | a cada “Wait” no raciocínio, testa uma resposta; sai se a média geométrica das probabilidades dos tokens passar de 0,95 (DEER) |

Budgets e early-exit valem para o caminho `/v1/completions`, que é o que o BFCL usa com o Qwen. O limiar e o marcador do early-exit ficam em `config.yaml`.

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark bfcl
python run.py --model qwen3_1.7b --strategy budget128 --benchmark bfcl
python run.py --model qwen3_1.7b --strategy early_exit --benchmark bfcl
python analyze.py results/
python checks.py   # budgets, early-exit e integração de energia, sem GPU
```

O servidor sobe sozinho (`scripts/serve_*.sh`). O benchmark fala com o proxy em `127.0.0.1:8001`. O vLLM fica em `8000`.

No cluster:

```bash
sauron submit -c sauron/job.yaml sauron/run-bfcl.sauron
```

`HF_HOME=/cache/huggingface` é o cache que o nó já monta. Não monte outra pasta por cima. Token e chave do simulador de usuário ficam em `residencia-tcc/.env`.

## Foundation Models Bench (Mac com Apple Intelligence)

Roda o modelo da Apple no próprio Mac, na suíte `agentic` (`personal-organizer`: busca contato e cria lembrete, com ordem de chamadas e estado final verificados). Não roda no cluster.

```bash
git clone https://github.com/rudrankriyam/Foundation-Models-Framework-Benchmark external/Foundation-Models-Framework-Benchmark
cd external/Foundation-Models-Framework-Benchmark
export DEVELOPER_DIR=/Applications/Xcode_27.app/Contents/Developer
swift package edit FoundationModelsKit
```

A `FoundationModelsKit` 2.1.0 usa `Transcript.Segment.custom`, que o SDK do Xcode 27 não tem. Na cópia editada, apague o `case .custom` de `Packages/FoundationModelsKit/Sources/FoundationModelsKit/Extensions/Transcript+TokenCounting.swift` (a 3.1.0 da biblioteca faz o mesmo). Depois:

```bash
swift build -c release
sudo powermetrics --samplers cpu_power,gpu_power,ane_power -i 1000 > ../../results/fmb_power.txt &
.build/release/foundation-models-bench --suite agentic --all-samples --warmups 2 --repetitions 3 --no-randomize \
  --json ../../results/fmb_agentic.json --markdown ../../results/fmb_agentic.md
sudo pkill powermetrics
cd ../..
python fmb_energy.py results/fmb_agentic.json results/fmb_apple_agentic.jsonl results/fmb_power.txt
```

`fmb_energy.py` grava cada tentativa no mesmo formato do BFCL, com `energy_j` (CPU + GPU + ANE do Mac inteiro, integrados na janela da tentativa; feche os outros apps) e `energy_j_per_token`. O `analyze.py` passa a mostrar a linha `apple_onDevice` e o gráfico `quality_energy.png`. Sem o log do `powermetrics`, as linhas saem sem energia. O JSON do benchmark marca o tempo em segundos inteiros, então tentativa curta tem energia aproximada.
