# Inferência adaptativa on-device — plano da primeira versão

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rodar, nesta GPU, os 560 episódios iniciais (BFCL + τ², 2 modelos, 4 estratégias) e sair com um JSONL real mais a tabela do `analyze.py`.

**Architecture:** O vLLM sobe como servidor OpenAI-compatible. Um único `VLLMBackend.generate()` é o único caminho até o modelo. S0/S1/S2 mudam só flags do servidor. S3 faz duas chamadas (plano curto, depois ação). Os benchmarks oficiais apontam para um proxy local que encaminha ao backend e cronometra só a inferência do agente. O simulador de usuário do τ² não passa por esse proxy.

**Tech Stack:** Sauron, `nvcr.io/nvidia/pytorch:26.01-py3` (CUDA 13.1, PyTorch 2.10.0a0, cuDNN 9.17), vLLM, BFCL oficial, τ²-bench-verified oficial, matplotlib.

## Global Constraints

- Simplicidade absoluta. Sem testes unitários, smoke tests, CI, mocks, factories, registries, banco, dashboard, WandB, plugins, framework de agentes, KV cache próprio ou speculative decoding próprio.
- Sem Dockerfile. O container é o do Sauron.
- Código próprio em poucas centenas de linhas, nos arquivos listados abaixo. Não criar diretório além de `mobile-adaptive-inference/`, `scripts/`, `external/`, `results/`.
- Só dois modelos: `google/gemma-4-E2B-it` e `Qwen/Qwen3-1.7B`. Sem 7B/8B.
- Só `VLLMBackend`. Não implementar `MLXBackend`, Swift ou Xcode.
- Estratégias chamam `backend.generate(...)` e nunca `vllm` direto.
- Não combinar estratégias. Só S0 direct, S1 prefix, S2 speculative, S3 plan_act.
- `temperature = 0`, `concurrency = 1`. Mesmos `max_tokens`, context length, prompts, tools e task IDs entre condições. Plano: `max_plan_tokens = 128`. Gemma MTP: `num_speculative_tokens = 2`. Sem grid search.
- Qualidade e eficiência ficam separadas. Sem score agregado.
- Métrica de tempo é só inferência do agente local. Latência do user simulator remoto do τ² fica de fora.
- Resultados em JSONL, uma linha por episódio, em `results/`.
- AppWorld só depois de BFCL e τ² estarem medidos e a primeira análise existir.
- Não implementar router, classificador, RL ou dificuldade predita.
- Segredos (token Hugging Face, chave do user simulator) só em `residencia-tcc/.env`, carregado com `source .env`. Nunca no `job.yaml`.
- GPU desta máquina: NVIDIA B200, slice MIG `3g.90gb` (classe Sauron 89G, ~91 GiB). Uma GPU, sem tensor parallel. Não pedir a classe 179G.
- Não alterar `MobileLLMBench/` nem `AndroidLLMBench/`.

---

## Ambiente já medido

Login não tem GPU. O job #75 (`sauron/probe.sauron`) rodou em `nvcr.io/nvidia/pytorch:26.01-py3` e gravou `sauron/probe-output.txt`:

| | |
|---|---|
| GPU | NVIDIA B200 MIG 3g.90gb, compute capability 10.0 |
| Driver | 590.48.01 |
| CUDA do driver e do PyTorch | 13.1 |
| PyTorch | 2.10.0a0+a36e1d39eb.nv26.01 |
| cuDNN | 9.17.1 |
| VRAM livre no slice | ~90 GiB |

A imagem pedida (`pytorch/pytorch:2.9.0-cuda13.0-cudnn9-devel`) é CUDA 13.0 + cuDNN 9 + PyTorch 2.9. A do cluster é o minor seguinte e já está em cache no nó. Fica essa.

O job reutilizável está em `sauron/job.yaml`: 1 GPU, `vram: 89`, 2 CPUs, 32 GB de RAM, workspace `residencia-tcc`. Experimentos longos sobem `max_time` nesse arquivo antes do submit (BFCL cabe em poucas horas; a rodada completa de 560 episódios precisa de um teto medido no primeiro modelo e depois multiplicado, com folga).

```bash
cd ~/workspace/residencia-tcc
sauron submit -c sauron/job.yaml sauron/probe.sauron
sauron logs <ref>
```

Cache de modelos no disco rápido do workspace, não na home:

```bash
export HF_HOME=/workspace/.cache/huggingface
export PYTHONNOUSERSITE=1
```

Gemma 4 é gated. Sem `HF_TOKEN` no `.env` o download falha. Não seguir em frente com outro modelo no lugar.

---

## File structure

Tudo novo fica em `residencia-tcc/mobile-adaptive-inference/`. O job já entra em `/workspace` (= `residencia-tcc`).

```text
mobile-adaptive-inference/
├── README.md
├── requirements.txt
├── config.yaml
├── backend.py          # Backend.generate + VLLMBackend + proxy HTTP mínimo
├── strategies.py       # direct e plan_act
├── metrics.py          # contadores do episódio e append JSONL
├── run.py              # CLI
├── analyze.py          # tabela + dois ou três gráficos
├── scripts/
│   ├── serve_gemma.sh
│   └── serve_qwen.sh
├── external/
│   └── tau2-bench-verified/   # clone, não reescrever
└── results/
```

`backend.py` é o único arquivo que importa o cliente OpenAI / sabe a URL do vLLM. `strategies.py` só chama `backend.generate`.

Contrato que as tarefas seguintes usam:

```python
def generate(self, messages, tools=None, max_tokens=512) -> dict:
    """Retorna {"text": str, "tool_calls": [{"name": str, "arguments": dict}],
    "prompt_tokens": int, "output_tokens": int, "inference_ms": float}."""
```

`tool_calls` é lista vazia quando o modelo só devolve texto. `arguments` é dict, não string JSON.

---

### Task 1: Repositório mínimo e uma geração real

**Files:**
- Create: `mobile-adaptive-inference/requirements.txt`
- Create: `mobile-adaptive-inference/config.yaml`
- Create: `mobile-adaptive-inference/backend.py`
- Create: `mobile-adaptive-inference/scripts/serve_qwen.sh`
- Create: `mobile-adaptive-inference/scripts/serve_gemma.sh`
- Create: `mobile-adaptive-inference/README.md`

**Interfaces:**
- Consumes: imagem e job já medidos.
- Produces: `VLLMBackend.generate(messages, tools=None, max_tokens=512) -> dict` com as chaves acima. Servidor em `127.0.0.1:8000`, modelo servido com o nome de `config.yaml` (`qwen3_1.7b` ou `gemma4_e2b`).

- [ ] **Step 1: Dependências**

`requirements.txt`:

```text
vllm
openai
pyyaml
matplotlib
bfcl-eval
```

`pynvml` não entra agora. O slice MIG reportou potência `N/A` na sonda; energia só volta se uma leitura real funcionar na Task 8.

- [ ] **Step 2: Config mínima**

`config.yaml` começa assim. Task IDs entram nas tasks 3 e 7, não agora.

```yaml
generation:
  temperature: 0
  max_tokens: 512
  max_plan_tokens: 128
  concurrency: 1
  max_model_len: 8192

models:
  qwen3_1.7b:
    hf: Qwen/Qwen3-1.7B
    speculative:
      method: ngram
      num_speculative_tokens: 5
      prompt_lookup_max: 4
      prompt_lookup_min: 2
  gemma4_e2b:
    hf: google/gemma-4-E2B-it
    assistant: google/gemma-4-E2B-it-assistant
    speculative:
      method: mtp
      num_speculative_tokens: 2

server:
  host: 127.0.0.1
  port: 8000
  gpu_memory_utilization: 0.90
```

`num_speculative_tokens: 5` no Qwen é o primeiro valor do mecanismo ngram do vLLM, não um grid. Se o `vllm serve --help` da versão instalada usar outros nomes de chave, ajustar este bloco uma vez para o que o help mostra e não variar de novo.

- [ ] **Step 3: Backend**

`backend.py` inteiro nesta task (o proxy entra na Task 3, quando o BFCL precisar de HTTP):

```python
import json
import time

from openai import OpenAI


class Backend:
    def generate(self, messages, tools=None, max_tokens=512):
        raise NotImplementedError


def _tool_calls(message):
    calls = []
    for call in message.tool_calls or []:
        raw = call.function.arguments or "{}"
        try:
            args = json.loads(raw)
        except json.JSONDecodeError:
            args = {"_raw": raw}
        if not isinstance(args, dict):
            args = {"_value": args}
        calls.append({"name": call.function.name, "arguments": args})
    return calls


class VLLMBackend(Backend):
    def __init__(self, base_url, model, temperature=0):
        self.model = model
        self.temperature = temperature
        self.client = OpenAI(base_url=base_url, api_key="EMPTY")

    def generate(self, messages, tools=None, max_tokens=512):
        kwargs = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": max_tokens,
        }
        if tools:
            kwargs["tools"] = tools
        t0 = time.perf_counter()
        response = self.client.chat.completions.create(**kwargs)
        elapsed_ms = (time.perf_counter() - t0) * 1000
        choice = response.choices[0].message
        usage = response.usage
        return {
            "text": choice.content or "",
            "tool_calls": _tool_calls(choice),
            "prompt_tokens": usage.prompt_tokens if usage else 0,
            "output_tokens": usage.completion_tokens if usage else 0,
            "inference_ms": elapsed_ms,
        }
```

- [ ] **Step 4: Scripts de serve, estratégia direct (prefix caching desligado)**

Os dois scripts recebem um argumento: `direct`, `prefix` ou `speculative`. `plan_act` usa o mesmo servidor que `direct` (prefix off, sem speculative). Não combinar flags.

`scripts/serve_qwen.sh`:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STRATEGY="${1:-direct}"
EXTRA=()
case "$STRATEGY" in
  direct|plan_act) EXTRA+=(--no-enable-prefix-caching) ;;
  prefix) EXTRA+=(--enable-prefix-caching) ;;
  speculative)
    EXTRA+=(--no-enable-prefix-caching)
    EXTRA+=(--speculative-config '{"method":"ngram","num_speculative_tokens":5,"prompt_lookup_max":4,"prompt_lookup_min":2}')
    ;;
  *) echo "estrategia desconhecida: $STRATEGY" >&2; exit 1 ;;
esac
exec vllm serve Qwen/Qwen3-1.7B \
  --host 127.0.0.1 --port 8000 \
  --served-model-name qwen3_1.7b \
  --tensor-parallel-size 1 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90 \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  "${EXTRA[@]}"
```

`scripts/serve_gemma.sh`: igual, trocando o modelo, o nome servido (`gemma4_e2b`) e o bloco speculative:

```bash
  speculative)
    EXTRA+=(--no-enable-prefix-caching)
    EXTRA+=(--speculative-config '{"method":"mtp","model":"google/gemma-4-E2B-it-assistant","num_speculative_tokens":2}')
    ;;
```

O parser de tool da Gemma não é `hermes`. Na Task 2, trocar `--tool-call-parser` pelo nome que `vllm serve --help` listar para Gemma 4 e que uma chamada de tool devolver parseada. Até lá o script da Gemma sobe sem `--enable-auto-tool-choice` na Task 1, porque a primeira chamada é texto puro.

Se `--no-enable-prefix-caching` não existir na versão instalada, usar o flag negativo que `vllm serve --help | grep prefix` mostrar. Anotar o flag real nos dois scripts e não mudar de novo.

- [ ] **Step 5: Subir o venv no job e gerar uma frase com o Qwen**

`sauron/run-task1.sauron`:

```bash
set -euo pipefail
source .env 2>/dev/null || true
export PYTHONNOUSERSITE=1
export HF_HOME=/workspace/.cache/huggingface
cd mobile-adaptive-inference
python -m venv --without-pip --system-site-packages .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python - <<'PY'
import torch
print("torch", torch.__version__, "cuda", torch.version.cuda)
PY
# Conferir que o pip não trocou o torch da imagem por um wheel CUDA 12.
python -c 'import torch; assert torch.version.cuda.startswith("13."), torch.version.cuda'
bash scripts/serve_qwen.sh direct > /tmp/vllm-qwen.log 2>&1 &
for i in $(seq 1 120); do
  curl -sf http://127.0.0.1:8000/v1/models && break
  sleep 5
done
python - <<'PY'
from backend import VLLMBackend
b = VLLMBackend("http://127.0.0.1:8000/v1", "qwen3_1.7b")
print(b.generate([{"role": "user", "content": "Responda só: ok"}]))
PY
```

Subir `max_time` para `2h` neste job (download do modelo). Submit:

```bash
sauron submit -c sauron/job.yaml sauron/run-task1.sauron
```

Esperado: JSON com `"text"` não vazio, `inference_ms` > 0, `tool_calls` vazio, e o assert do CUDA 13 passando.

Se o `pip install vllm` substituir o torch e o assert falhar, parar. Não seguir com CUDA 12 nesta B200. Instalar o wheel de vLLM cujo sufixo CUDA seja 13 (`cu130` ou o que o índice mostrar para torch 2.10) por cima do torch da imagem.

- [ ] **Step 6: A mesma frase com a Gemma**

Repetir o bloco final com `serve_gemma.sh direct` e `VLLMBackend(..., "gemma4_e2b")`. Não deixar os dois servidores no ar ao mesmo tempo: matar o Qwen antes (`kill` do pid do `vllm`).

Esperado: o mesmo formato de dict, texto não vazio. Se o download pedir licença, o log do Hugging Face mostra 401/403 e o passo para até o `HF_TOKEN` existir no `.env`.

---

### Task 2: Tool calling dos dois modelos

**Files:**
- Modify: `mobile-adaptive-inference/scripts/serve_gemma.sh`
- Modify: `mobile-adaptive-inference/scripts/serve_qwen.sh` só se o parser `hermes` não preencher `tool_calls`

**Interfaces:**
- Consumes: `VLLMBackend.generate(..., tools=...)`.
- Produces: `tool_calls == [{"name": "add", "arguments": {"a": 2, "b": 3}}]` (números podem vir int ou float; o nome e as chaves não).

- [ ] **Step 1: Uma tool, os dois modelos, estratégia direct**

Com o servidor certo no ar:

```python
tools = [{
    "type": "function",
    "function": {
        "name": "add",
        "description": "Soma dois inteiros",
        "parameters": {
            "type": "object",
            "properties": {"a": {"type": "integer"}, "b": {"type": "integer"}},
            "required": ["a", "b"],
        },
    },
}]
out = backend.generate(
    [{"role": "user", "content": "Use a ferramenta add para somar 2 e 3. Não calcule você mesmo."}],
    tools=tools,
)
assert out["tool_calls"][0]["name"] == "add"
assert set(out["tool_calls"][0]["arguments"]) == {"a", "b"}
```

Rodar uma vez no Qwen e uma vez na Gemma, em jobs separados ou em sequência no mesmo job, um servidor por vez.

- [ ] **Step 2: Corrigir só o parser que falhar**

Se `tool_calls` vier vazio e o texto contiver a chamada, o parser do servidor está errado. Listar parsers com `vllm serve --help` e trocar `--tool-call-parser` no script daquele modelo. Repetir a chamada. Não escrever um parser nosso.

Esperado: os dois modelos passam o assert.

---

### Task 3: BFCL Direct, 40 tarefas, os dois modelos

**Files:**
- Modify: `mobile-adaptive-inference/config.yaml` (IDs congelados)
- Create: `mobile-adaptive-inference/metrics.py`
- Create: `mobile-adaptive-inference/strategies.py`
- Create: `mobile-adaptive-inference/run.py`
- Modify: `mobile-adaptive-inference/backend.py` (proxy de uma porta só)

**Interfaces:**
- Consumes: `VLLMBackend.generate`.
- Produces: `results/bfcl_<model>_direct.jsonl`, 40 linhas, campos do exemplo abaixo. CLI:

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark bfcl
python run.py --model gemma4_e2b --strategy direct --benchmark bfcl
```

- [ ] **Step 1: Congelar 40 IDs**

Dentro do venv, inspecionar as categorias V4 do pacote instalado (`bfcl --help` e as constantes de categoria). As quatro categorias desta versão são as que o BFCL chama de simple, multiple, parallel e multiple_parallel (o nome exato no CLI pode ser `simple_python`, `parallel_multiple` etc.; usar o nome que o help desta instalação mostrar para esses quatro conjuntos, não inventar um quinto).

Pegar os 10 primeiros IDs de cada uma, na ordem estável do arquivo oficial. Gravar em `config.yaml`:

```yaml
benchmarks:
  bfcl:
    categories:
      simple: [id, ...]          # 10
      multiple: [id, ...]        # 10
      parallel: [id, ...]        # 10
      multiple_parallel: [id, ...]  # 10
```

Os mesmos 40 IDs valem para os dois modelos e as quatro estratégias. Não amostrar de novo.

- [ ] **Step 2: metrics.py**

```python
import json
from pathlib import Path


class Episode:
    def __init__(self):
        self.inference_ms = 0.0
        self.prompt_tokens = 0
        self.output_tokens = 0
        self.model_calls = 0
        self.tool_calls = 0

    def add(self, result):
        self.inference_ms += result["inference_ms"]
        self.prompt_tokens += result["prompt_tokens"]
        self.output_tokens += result["output_tokens"]
        self.model_calls += 1
        self.tool_calls += len(result["tool_calls"])

    def reset(self):
        self.__init__()


def append_jsonl(path, row):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
```

- [ ] **Step 3: strategies.py com direct**

```python
class DirectStrategy:
    name = "direct"

    def __init__(self, backend, max_tokens):
        self.backend = backend
        self.max_tokens = max_tokens

    def run_turn(self, messages, tools=None):
        return self.backend.generate(messages, tools=tools, max_tokens=self.max_tokens)
```

`PlanActStrategy` entra na Task 6. Não criar as outras classes: prefix e speculative são o mesmo `DirectStrategy` com outro servidor.

- [ ] **Step 4: Proxy mínimo em backend.py**

Uma função `serve_proxy(backend, host, port)` com a stdlib (`http.server`). Aceita `POST /v1/chat/completions` e `GET /v1/models`. Traduz o body OpenAI para `backend.generate`, devolve o JSON de chat completion (incluindo `tool_calls` no formato OpenAI e `usage`). Cada `generate` passa por `Episode.add` de um episode global `CURRENT`, que `run.py` zera antes de cada tarefa.

Não usar FastAPI. Não logar o simulador de usuário: este proxy é só o modelo agente.

Porta do proxy: `8001`. O vLLM continua em `8000`. O benchmark aponta para `8001`.

- [ ] **Step 5: run.py para BFCL direct**

Argumentos: `--model`, `--strategy`, `--benchmark`.

Para `benchmark=bfcl` e `strategy=direct`:

1. Sobe `scripts/serve_<modelo>.sh direct` se `127.0.0.1:8000/v1/models` não responder.
2. Sobe o proxy em `8001` com `VLLMBackend("http://127.0.0.1:8000/v1", nome_servido)`.
3. Para cada id em `config.yaml`, zera o episode, roda o gerador oficial só daquele id e o avaliador oficial só daquele id.
4. Lê `success` e o score oficial do arquivo de score do BFCL. Se o avaliador não tiver score numérico naquela categoria, gravar `score: null` e `success` booleano. Não inventar score.
5. Append em `results/bfcl_<model>_direct.jsonl`:

```json
{"task_id":"...","benchmark":"bfcl","model":"qwen3_1.7b","strategy":"direct","success":true,"score":1.0,"agent_inference_ms":0,"prompt_tokens":0,"output_tokens":0,"model_calls":1,"tool_calls":1}
```

Comando oficial, ajustado ao help da instalação (nomes de categoria e flag de um único exemplo). Forma esperada, com o servidor já no ar:

```bash
export LOCAL_SERVER_ENDPOINT=127.0.0.1
export LOCAL_SERVER_PORT=8001
export OPENAI_API_KEY=EMPTY
bfcl generate --model <nome-servido> --test-category <categoria> --skip-server-setup
bfcl evaluate --model <nome-servido> --test-category <categoria>
```

Se o CLI não filtrar um id, o jeito curto é: o pacote lê um JSONL de testes; copiar só as 40 linhas escolhidas para `mobile-adaptive-inference/bfcl_ids.jsonl` e apontar o gerador para esse arquivo pelo mecanismo que o `--help` documentar. Não editar o código do `bfcl-eval`.

`temperature=0` tem de chegar ao modelo. Se o BFCL não repassar temperatura, fixar no proxy: ignorar a temperatura do request e chamar `generate` com `temperature=0` já gravada no `VLLMBackend`.

- [ ] **Step 6: Rodar os dois modelos**

`max_time` suficiente para 40 tarefas (começar com `4h`; se o primeiro modelo terminar em uma fração disso, o segundo reutiliza o mesmo teto).

```bash
sauron submit -c sauron/job.yaml sauron/run-bfcl-direct.sauron
```

O `.sauron` ativa o venv, exporta `HF_HOME`, e chama os dois `python run.py ... --strategy direct --benchmark bfcl` em sequência (um servidor morre antes do outro subir).

Esperado: dois JSONL com 40 linhas cada, os mesmos `task_id` na mesma ordem, `strategy=direct`. Abrir 2 linhas de cada arquivo e conferir que `agent_inference_ms` e os tokens são não-zero nas tarefas que chamaram o modelo.

---

### Task 4: Prefix cache no BFCL

**Files:**
- Modify: `mobile-adaptive-inference/run.py` (strategy `prefix` escolhe `serve_*.sh prefix`)

**Interfaces:**
- Produces: `results/bfcl_<model>_prefix.jsonl`.

- [ ] **Step 1: Não mudar prompt, temperatura, max_tokens nem IDs**

`prefix` usa `DirectStrategy`. A única diferença é o servidor ter sido iniciado com `--enable-prefix-caching` e sem speculative config.

- [ ] **Step 2: Rodar os dois modelos nas mesmas 40 tarefas**

```bash
python run.py --model qwen3_1.7b --strategy prefix --benchmark bfcl
python run.py --model gemma4_e2b --strategy prefix --benchmark bfcl
```

Esperado: 40 linhas cada. No BFCL single-turn o ganho pode ser pequeno; isso é resultado, não bug. Não religar prefix nas outras estratégias.

---

### Task 5: Speculative decoding no BFCL

**Files:**
- Modify: `mobile-adaptive-inference/run.py` (strategy `speculative`)
- Modify: os scripts só se o servidor recusar o JSON da Task 1

**Interfaces:**
- Produces: `results/bfcl_<model>_speculative.jsonl`.

- [ ] **Step 1: Subir cada servidor speculative e ler o log de boot**

Gemma: o log tem de mostrar método `mtp` e o assistant `google/gemma-4-E2B-it-assistant`, com `num_speculative_tokens` 2. Se aparecer `method='draft_model'`, a versão do vLLM não tem o caminho MTP da Gemma 4. Parar e trocar o pacote `vllm` por uma versão cujo help documente `method: mtp` para Gemma 4 assistant. Não forçar o assistant como draft model genérico. Não usar EAGLE no lugar.

Qwen: o log tem de mostrar `ngram` (ou o nome de prompt lookup que essa versão usa). Sem draft model treinado. Prefix caching continua desligado neste servidor.

- [ ] **Step 2: Uma chamada de texto e uma tool call em cada modelo**

Mesmo assert da Task 2, mais uma geração curta sem tool. Se a tool call que passava em `direct` passar a falhar, o speculative config quebrou o parser: parar e olhar o log, não mudar o prompt.

- [ ] **Step 3: BFCL de novo, mesmos 40 IDs**

```bash
python run.py --model qwen3_1.7b --strategy speculative --benchmark bfcl
python run.py --model gemma4_e2b --strategy speculative --benchmark bfcl
```

Esperado: mais dois JSONL de 40 linhas.

---

### Task 6: Plan+Act no BFCL

**Files:**
- Modify: `mobile-adaptive-inference/strategies.py`
- Modify: `mobile-adaptive-inference/backend.py` (o proxy chama a strategy, não o generate cru, quando `strategy=plan_act`)
- Modify: `mobile-adaptive-inference/run.py`

**Interfaces:**
- Consumes: `backend.generate`.
- Produces: `PlanActStrategy.run_turn(messages, tools=None)` fazendo duas chamadas. `results/bfcl_<model>_plan_act.jsonl` com `model_calls` maior que na condição direct da mesma tarefa.

Servidor: o mesmo de `direct` (sem prefix, sem speculative).

- [ ] **Step 1: PlanActStrategy**

```python
class PlanActStrategy:
    name = "plan_act"

    def __init__(self, backend, max_tokens, max_plan_tokens=128):
        self.backend = backend
        self.max_tokens = max_tokens
        self.max_plan_tokens = max_plan_tokens

    def run_turn(self, messages, tools=None):
        plan = self.backend.generate(
            messages + [{
                "role": "user",
                "content": "Escreva um plano curto, no máximo 5 linhas, para responder. Não chame ferramentas ainda.",
            }],
            tools=None,
            max_tokens=self.max_plan_tokens,
        )
        return self.backend.generate(
            messages + [{"role": "assistant", "content": plan["text"]}],
            tools=tools,
            max_tokens=self.max_tokens,
        )
```

O plano não vê as tools. A segunda chamada vê as tools e o plano. Sem reflection, sem segundo plano, sem árvore.

O proxy, em `plan_act`, executa `run_turn` uma vez por request do benchmark e devolve só a segunda resposta ao cliente. As duas chamadas entram no `Episode` (o `add` acontece dentro de `generate`). `model_calls` fica 2 por turno do BFCL single-turn.

- [ ] **Step 2: Checagem manual de uma soma**

Uma request de tool `add(2,3)` via proxy. Esperado: duas idas ao vLLM no log, `tool_calls[0].name == "add"`, `model_calls == 2` no episode.

- [ ] **Step 3: BFCL plan_act nos dois modelos, mesmos 40 IDs**

```bash
python run.py --model qwen3_1.7b --strategy plan_act --benchmark bfcl
python run.py --model gemma4_e2b --strategy plan_act --benchmark bfcl
```

Esperado: JSONL com 40 linhas cada. Não comparar ainda com as outras estratégias além de olhar se o arquivo não está vazio.

---

### Task 7: τ²-bench-verified, quatro estratégias, três domínios

**Files:**
- Create: `mobile-adaptive-inference/external/tau2-bench-verified/` via clone
- Modify: `mobile-adaptive-inference/config.yaml` (30 task IDs)
- Modify: `mobile-adaptive-inference/run.py`

Não editar tasks, tools, políticas nem o avaliador. A única cola é a URL do agente.

- [ ] **Step 1: Clone e instalação mínima**

```bash
git clone https://github.com/amazon-agi/tau2-bench-verified mobile-adaptive-inference/external/tau2-bench-verified
```

Instalar o pacote do jeito que o README desse commit mandar, dentro do mesmo `.venv`. O user simulator continua sendo o modelo remoto que o benchmark usa; a chave dele fica no `.env`.

- [ ] **Step 2: Apontar só o agente para o proxy**

O τ² fala com LLMs via LiteLLM. O agente usa o modelo servido localmente. Forma a confirmar no README/config do clone (uma das duas, a que o código aceitar):

```bash
export OPENAI_API_BASE=http://127.0.0.1:8001/v1
export OPENAI_API_KEY=EMPTY
# agent-llm no formato que o LiteLLM desta versão usa para base OpenAI local,
# por exemplo openai/qwen3_1.7b ou hosted_vllm/qwen3_1.7b
```

O user simulator não usa `8001`. Se a mesma variável de ambiente desviar os dois, parar e setar a base URL só no argumento do agente (`api_base` do LiteLLM no ponto único em que o agente é construído). Uma linha nesse ponto é o máximo de edição. Não copiar o benchmark para fora de `external/`.

- [ ] **Step 3: Congelar 10 IDs por domínio**

Domínios: `airline`, `retail`, `telecom`. Listar os IDs oficiais e gravar os 10 primeiros de cada um em `config.yaml` sob `benchmarks.tau2`. Os mesmos 30 para todos os modelos e estratégias.

- [ ] **Step 4: Uma tarefa airline antes da leva**

```bash
tau2 run --domain airline --agent-llm <modelo-local> --user-llm <o default do benchmark> \
  --task-ids <um id congelado> --num-trials 1 --max-concurrency 1
```

Esperado: o proxy registra chamadas; o user simulator não aparece no episode. `agent_inference_ms` é a soma das gerações do agente, não o wall clock do `tau2 run`.

- [ ] **Step 5: Loop oficial**

`run.py --benchmark tau2` percorre os 30 IDs com `concurrency` 1. Para cada ID: zera o episode, roda `tau2 run` daquele ID, lê o sucesso/score do resultado oficial, faz append em `results/tau2_<model>_<strategy>.jsonl`.

Quatro estratégias × dois modelos. Servidor sobe com o script correspondente, igual ao BFCL. `plan_act` usa o servidor `direct` e o proxy da Task 6.

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark tau2
python run.py --model gemma4_e2b --strategy plan_act --benchmark tau2
```

Os outros seis comandos (2 modelos × as estratégias que faltam) seguem o mesmo formato.

Esperado: 8 arquivos, 30 linhas cada. `benchmark` vale `"tau2"`.

`max_time`: esta leva é a longa. Medir uma tarefa, multiplicar por 30 × 4 × 2 e colocar folga no `job.yaml` antes de submeter. Se estourar, `sauron retry` não repete episódio já gravado: `run.py` pula `task_id` que já está no JSONL de saída.

---

### Task 8: Primeira análise

**Files:**
- Create: `mobile-adaptive-inference/analyze.py`

**Interfaces:**
- Consumes: os JSONL de `results/`.
- Produces: tabela no stdout e PNGs em `results/`.

- [ ] **Step 1: analyze.py**

Lê todo `*.jsonl` em `results/`. Agrupa por `(model, strategy, benchmark)`. Imprime:

```text
model strategy benchmark success_rate mean_inference_ms median_inference_ms mean_output_tokens
```

`success_rate` = média de `success` (true=1). `mean_inference_ms` e `median_inference_ms` sobre `agent_inference_ms`. `mean_output_tokens` sobre `output_tokens`. Uma linha por grupo. Sem score combinado.

Gráficos, um ponto por grupo:

- `results/quality_latency.png` — success_rate × mean_inference_ms
- `results/quality_tokens.png` — success_rate × mean_output_tokens

Se algum JSONL tiver `energy_j` numérico em todas as linhas do grupo, gravar também `results/quality_energy.png`. Se o campo não existir, não criar o arquivo e não estimar energia. A sonda viu potência `N/A` no MIG; o caminho feliz desta versão é não ter o terceiro gráfico.

Leitura de energia, só se couber em poucas linhas e a API responder número de verdade: `pynvml` no device visível, energia no início e no fim do episódio, diferença em joules, mais `torch.cuda.max_memory_allocated()` em MB no `VLLMBackend`. Se a chamada lançar ou devolver N/A, omitir os campos. Não amostrar `nvidia-smi` em loop.

```bash
python analyze.py results/
```

Esperado: a tabela cobre 2 modelos × 4 estratégias × 2 benchmarks = 16 linhas, e os dois PNGs existem.

- [ ] **Step 2: Parar**

Não integrar AppWorld nesta task. Ler a tabela contra as perguntas Q1–Q4 do spec antes de qualquer código novo. Q1 no BFCL pode ser inconclusivo; o τ² é que responde prefix caching multi-turn.

---

### Task 9: AppWorld, só depois da Task 8

**Files:**
- Modify: `mobile-adaptive-inference/config.yaml` (~15 task IDs `dev`)
- Modify: `mobile-adaptive-inference/run.py`

Não criar ambiente próprio. Não editar tasks. Não usar `test_normal` nem `test_challenge`.

- [ ] **Step 1: Instalar a implementação simplificada oficial do AppWorld e listar o split `dev`**

Seguir o README do pacote. Escolher ~15 tarefas `dev` que precisem de mais de uma ação (o metadado oficial de número de chamadas, se existir; senão as 15 primeiras cujo enunciado mostre mais de um app). Gravar os IDs em `config.yaml`. Mesmos IDs para todos.

- [ ] **Step 2: Apontar o agente para `127.0.0.1:8001`**

O mesmo proxy. Cronometrar só o que passar por `generate`. Rodar as quatro estratégias nos dois modelos:

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark appworld
```

e os outros sete comandos no mesmo formato. JSONL: `results/appworld_<model>_<strategy>.jsonl`, `benchmark: "appworld"`.

- [ ] **Step 3: Rodar analyze.py de novo**

A tabela passa a ter também as linhas `appworld`.

---

### Task 10: Parar

Não implementar router, combinação de estratégias, draft model, nem mais benchmarks. O oracle barato por tarefa é uma leitura dos JSONL já gravados (a estratégia de menor `agent_inference_ms` entre as que tiveram `success`), e fica para um script futuro de meia dúzia de linhas quando os números existirem. Não escrever esse script agora.

Critério desta versão, já coberto pelas tasks 3, 7 e 8:

```bash
python run.py --model qwen3_1.7b --strategy direct --benchmark bfcl
python run.py --model gemma4_e2b --strategy plan_act --benchmark tau2
python analyze.py results/
```

Os três produzem arquivo real (JSONL ou tabela), não stub.

---

## Self-review

- Spec de modelos, quatro estratégias isoladas, três benchmarks na ordem pedida, métricas separadas, JSONL e `analyze.py`: cada um tem task.
- `MLXBackend`, router, combinações, AppWorld antes da análise, testes unitários e Docker próprio: de fora, de propósito.
- Assinatura `generate(messages, tools=None, max_tokens=512)` é a mesma na Task 1 e na Task 6.
- Prefixo e speculative não têm classe própria; só mudam o script do servidor. Plan+Act é a única strategy com duas chamadas.
- Energia não é obrigatória neste MIG.
