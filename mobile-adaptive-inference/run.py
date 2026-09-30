import argparse
import json
import os
import subprocess
import time
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import yaml

from backend import REQUEST_LOG, VLLMBackend, serve_proxy
from metrics import append_jsonl
from strategies import DirectStrategy, PlanActStrategy

ROOT = Path(__file__).resolve().parent
BFCL_CATEGORY = {
    "simple": "simple_python",
    "multiple": "multiple",
    "parallel": "parallel",
    "multiple_parallel": "parallel_multiple",
}
BFCL_MODEL = {
    "qwen3_1.7b": "Qwen/Qwen3-1.7B-FC",
    "gemma4_e2b": "google/gemma-4-E2B-it-FC",
}
ADD_TOOLS = [{
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


def load_config():
    return yaml.safe_load((ROOT / "config.yaml").read_text())


def models_up(url, needle):
    try:
        with urllib.request.urlopen(url, timeout=2) as response:
            return needle in response.read().decode()
    except Exception:
        return False


def stop_vllm():
    subprocess.run(["pkill", "-f", "vllm serve"], check=False)
    for _ in range(60):
        if not models_up("http://127.0.0.1:8000/v1/models", "id"):
            return
        time.sleep(2)
    subprocess.run(["pkill", "-9", "-f", "vllm serve"], check=False)


def start_vllm(model, strategy):
    flag = "direct" if strategy == "plan_act" else strategy
    script = "serve_qwen.sh" if model == "qwen3_1.7b" else "serve_gemma.sh"
    stop_vllm()
    log = (ROOT / "vllm.log").open("w")
    proc = subprocess.Popen(
        ["bash", str(ROOT / "scripts" / script), flag],
        cwd=ROOT,
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    for _ in range(180):
        if models_up("http://127.0.0.1:8000/v1/models", model):
            print("vllm up", model, flag)
            return proc
        if proc.poll() is not None:
            raise SystemExit(f"vllm saiu {proc.returncode}; ver {ROOT / 'vllm.log'}")
        time.sleep(5)
    raise SystemExit(f"vllm nao respondeu; ver {ROOT / 'vllm.log'}")


def make_strategy(backend, name, cfg):
    gen = cfg["generation"]
    if name == "plan_act":
        return PlanActStrategy(backend, gen["max_tokens"], gen["max_plan_tokens"])
    if name in ("direct", "prefix", "speculative"):
        return DirectStrategy(backend, gen["max_tokens"])
    raise SystemExit(f"estrategia desconhecida: {name}")


def toolcheck(backend):
    out = backend.generate(
        [{"role": "user", "content": "Use a ferramenta add para somar 2 e 3. Não calcule você mesmo."}],
        tools=ADD_TOOLS,
    )
    print(out)
    assert out["tool_calls"], out
    assert out["tool_calls"][0]["name"] == "add", out
    assert set(out["tool_calls"][0]["arguments"]) == {"a", "b"}, out


def done_ids(path):
    if not path.exists():
        return set()
    found = set()
    for line in path.read_text().splitlines():
        if line.strip():
            found.add(json.loads(line)["task_id"])
    return found


def register_gemma():
    from bfcl_eval.constants.model_config import MODEL_CONFIG_MAPPING, ModelConfig
    from bfcl_eval.model_handler.local_inference.base_oss_handler import OSSHandler
    from bfcl_eval.model_handler.utils import convert_to_function_call

    if "google/gemma-4-E2B-it-FC" in MODEL_CONFIG_MAPPING:
        return

    class Gemma4FCHandler(OSSHandler):
        # @override olha o frame de fora da função e não vê a classe aninhada.
        def _format_prompt(self, messages, function):
            # O template do Gemma lê tool.function. O BFCL manda o dict cru da função.
            tools = []
            for fn in function or []:
                if isinstance(fn, dict) and "function" in fn:
                    tools.append(fn)
                else:
                    tools.append({"type": "function", "function": fn})
            return self.tokenizer.apply_chat_template(
                messages,
                tools=tools,
                add_generation_prompt=True,
                tokenize=False,
            )
        _format_prompt.__override__ = True

        def _calls(self, result):
            from vllm.tool_parsers.gemma4_utils import parse_tool_calls

            calls = parse_tool_calls(result if isinstance(result, str) else str(result))

            def coerce(value):
                if isinstance(value, str) and value.lstrip("-").isdigit():
                    return int(value)
                return value

            return [{call["name"]: {k: coerce(v) for k, v in call["arguments"].items()}} for call in calls]

        def decode_ast(self, result, language, has_tool_call_tag):
            return self._calls(result)
        decode_ast.__override__ = True

        def decode_execute(self, result, has_tool_call_tag):
            return convert_to_function_call(self._calls(result))
        decode_execute.__override__ = True

    MODEL_CONFIG_MAPPING["google/gemma-4-E2B-it-FC"] = ModelConfig(
        model_name="google/gemma-4-E2B-it",
        display_name="Gemma4-E2B-it (FC)",
        url="https://huggingface.co/google/gemma-4-E2B-it",
        org="Google",
        license="gemma",
        model_handler=Gemma4FCHandler,
        is_fc_model=True,
    )


def bfcl_ids(cfg, done):
    grouped = {BFCL_CATEGORY[name]: [] for name in BFCL_CATEGORY}
    order = []
    for name, ids in cfg["benchmarks"]["bfcl"]["categories"].items():
        cat = BFCL_CATEGORY[name]
        for task_id in ids:
            if task_id not in done:
                grouped[cat].append(task_id)
                order.append(task_id)
    path = ROOT / "test_case_ids_to_generate.json"
    path.write_text(json.dumps({cat: ids for cat, ids in grouped.items() if ids}))
    return order


def bfcl_scores(model_name, ids):
    failed = set()
    found = False
    score_root = ROOT / "score" / model_name.replace("/", "_")
    for path in score_root.rglob("*_score.json"):
        found = True
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if row.get("id") and row.get("valid") is False:
                failed.add(row["id"])
    if not found:
        raise SystemExit(f"BFCL nao gravou score em {score_root}")
    return {task_id: (task_id not in failed, 0.0 if task_id in failed else 1.0) for task_id in ids}


def run_bfcl(model, strategy, cfg):
    out = ROOT / "results" / f"bfcl_{model}_{strategy}.jsonl"
    pending = done_ids(out)
    order = bfcl_ids(cfg, pending)
    if not order:
        print("bfcl ja completo", out)
        return
    os.environ["BFCL_PROJECT_ROOT"] = str(ROOT)
    os.environ["LOCAL_SERVER_ENDPOINT"] = "127.0.0.1"
    os.environ["LOCAL_SERVER_PORT"] = "8001"
    register_gemma()
    from bfcl_eval._llm_response_generation import main as generate_main
    from bfcl_eval.constants.eval_config import PROJECT_ROOT
    from bfcl_eval.eval_checker.eval_runner import runner

    bfcl_model = BFCL_MODEL[model]
    REQUEST_LOG.clear()
    generate_main(SimpleNamespace(
        model=[bfcl_model],
        test_category=["simple_python"],
        temperature=0,
        include_input_log=False,
        exclude_state_log=False,
        num_gpus=1,
        num_threads=1,
        gpu_memory_utilization=0.9,
        backend="vllm",
        skip_server_setup=True,
        local_model_path=None,
        result_dir="bfcl_result",
        allow_overwrite=True,
        run_ids=True,
        enable_lora=False,
        max_lora_rank=None,
        lora_modules=None,
    ))
    if len(REQUEST_LOG) != len(order):
        raise SystemExit(f"proxy viu {len(REQUEST_LOG)} requests, esperava {len(order)}")
    runner(
        [bfcl_model.replace("/", "_")],
        list(BFCL_CATEGORY.values()),
        PROJECT_ROOT / "bfcl_result",
        PROJECT_ROOT / "score",
        allow_missing=True,
    )
    scores = bfcl_scores(bfcl_model, order)
    for task_id, metrics in zip(order, REQUEST_LOG):
        success, score = scores[task_id]
        append_jsonl(out, {
            "task_id": task_id,
            "benchmark": "bfcl",
            "model": model,
            "strategy": strategy,
            "success": success,
            "score": score,
            "agent_inference_ms": metrics["inference_ms"],
            "prompt_tokens": metrics["prompt_tokens"],
            "output_tokens": metrics["output_tokens"],
            "model_calls": metrics["model_calls"],
            "tool_calls": metrics["tool_calls"],
        })
    print("escreveu", out, "linhas", len(order))


def freeze_tau2(cfg):
    block = cfg.setdefault("benchmarks", {}).get("tau2")
    if block:
        return block
    from tau2.runner import get_tasks

    block = {}
    for domain in ("airline", "retail", "telecom"):
        tasks = get_tasks(domain, task_split_name="base")
        block[domain] = [task.id for task in tasks][:10]
    cfg["benchmarks"]["tau2"] = block
    (ROOT / "config.yaml").write_text(yaml.safe_dump(cfg, sort_keys=False, allow_unicode=True))
    print("tau2 ids", block)
    return block


def run_tau2(model, strategy, cfg):
    if not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("TAU2 precisa de OPENAI_API_KEY no .env (user simulator)")
    block = freeze_tau2(cfg)
    out = ROOT / "results" / f"tau2_{model}_{strategy}.jsonl"
    pending = done_ids(out)
    user_llm = os.environ.get("TAU2_USER_LLM", "gpt-5.1")
    agent_args = json.dumps({
        "api_base": "http://127.0.0.1:8001/v1",
        "api_key": "EMPTY",
        "temperature": 0,
    })
    for domain, ids in block.items():
        for task_id in ids:
            if task_id in pending:
                continue
            REQUEST_LOG.clear()
            subprocess.run([
                "tau2", "run",
                "--domain", domain,
                "--agent-llm", f"openai/{model}",
                "--user-llm", user_llm,
                "--agent-llm-args", agent_args,
                "--task-ids", str(task_id),
                "--num-trials", "1",
                "--max-concurrency", "1",
            ], check=True, cwd=ROOT / "external" / "tau2-bench-verified")
            if not REQUEST_LOG:
                raise SystemExit(f"tau2 {task_id} nao passou pelo proxy")
            metrics = {
                key: sum(row[key] for row in REQUEST_LOG)
                for key in ("inference_ms", "prompt_tokens", "output_tokens", "model_calls", "tool_calls")
            }
            success, score = tau2_outcome(domain, task_id)
            append_jsonl(out, {
                "task_id": task_id,
                "benchmark": "tau2",
                "model": model,
                "strategy": strategy,
                "success": success,
                "score": score,
                "agent_inference_ms": metrics["inference_ms"],
                "prompt_tokens": metrics["prompt_tokens"],
                "output_tokens": metrics["output_tokens"],
                "model_calls": metrics["model_calls"],
                "tool_calls": metrics["tool_calls"],
            })


def tau2_outcome(domain, task_id):
    data = ROOT / "external" / "tau2-bench-verified" / "data"
    newest = None
    for path in data.rglob("*.json"):
        if newest is None or path.stat().st_mtime > newest.stat().st_mtime:
            newest = path
    if newest is None:
        return False, None
    blob = newest.read_text()
    if task_id not in blob:
        return False, None
    try:
        payload = json.loads(blob)
    except json.JSONDecodeError:
        return False, None
    reward = _find_reward(payload, task_id)
    if reward is None:
        return False, None
    return bool(reward), float(reward)


def _find_reward(node, task_id):
    if isinstance(node, dict):
        if str(node.get("task_id", node.get("id", ""))) == str(task_id) and "reward" in node:
            return node["reward"]
        for value in node.values():
            found = _find_reward(value, task_id)
            if found is not None:
                return found
    elif isinstance(node, list):
        for value in node:
            found = _find_reward(value, task_id)
            if found is not None:
                return found
    return None


def run_appworld(model, strategy, cfg):
    ids = (cfg.get("benchmarks") or {}).get("appworld", {}).get("ids")
    if not ids:
        raise SystemExit("AppWorld ainda sem IDs em config.yaml; rode depois da analise do BFCL e do tau2")
    out = ROOT / "results" / f"appworld_{model}_{strategy}.jsonl"
    print("appworld", model, strategy, "ids", len(ids), "saida", out)
    raise SystemExit("AppWorld: o CLI oficial entra aqui quando o pacote estiver instalado e os IDs dev estiverem no config")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, choices=["qwen3_1.7b", "gemma4_e2b"])
    parser.add_argument("--strategy", required=True, choices=["direct", "prefix", "speculative", "plan_act"])
    parser.add_argument("--benchmark", required=True, choices=["toolcheck", "bfcl", "tau2", "appworld"])
    args = parser.parse_args()
    cfg = load_config()
    server = cfg["server"]
    proc = start_vllm(args.model, args.strategy)
    backend = VLLMBackend(f"http://{server['host']}:{server['port']}/v1", args.model, temperature=0)
    try:
        if args.benchmark == "toolcheck":
            toolcheck(backend)
            return
        strategy = make_strategy(backend, args.strategy, cfg)
        serve_proxy(backend, "127.0.0.1", 8001, strategy)
        if args.benchmark == "bfcl":
            run_bfcl(args.model, args.strategy, cfg)
        elif args.benchmark == "tau2":
            run_tau2(args.model, args.strategy, cfg)
        else:
            run_appworld(args.model, args.strategy, cfg)
    finally:
        proc.terminate()
        stop_vllm()


if __name__ == "__main__":
    main()
