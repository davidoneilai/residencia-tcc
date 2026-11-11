"""CLI oficial do bfcl-eval apontado para o InferenceServer do iPhone.

Registra `iphone-<slm>-<estratégia>` como modelo FC (OpenAI Chat Completions) e repassa o resto ao `bfcl`.
Resultados, notas e o arquivo de IDs ficam em results/bfcl-mt/.
Uso:
  .bfcl-venv/bin/python analysis/bfcl_mt/bfcl.py generate --model iphone-qwen35-nothink --run-ids
  .bfcl-venv/bin/python analysis/bfcl_mt/bfcl.py generate --model iphone-qwen35-adaptive-prefix --slice dev
  .bfcl-venv/bin/python analysis/bfcl_mt/bfcl.py evaluate --model iphone-qwen35-nothink --test-category multi_turn --partial-eval
Estudo DAC (dac.py): `BFCL_MT_ROOT=results/bfcl-mt/dac/<rodada>` separa cada repetição; condições `iphone-<slm>-dac-<cond>`
com `cond` em CONDITIONS. Todas gravam `trace.jsonl` (bloco `device` por passo) na raiz.
"""
import json
import os
import sys
from pathlib import Path

SLICE = Path(__file__).resolve().parents[2] / "results" / "bfcl-mt" / "slice.json"
ROOT = Path(os.environ.get("BFCL_MT_ROOT") or SLICE.parent).resolve()
ROOT.mkdir(parents=True, exist_ok=True)
os.environ["BFCL_PROJECT_ROOT"] = str(ROOT)
os.environ.setdefault("OPENAI_BASE_URL", "http://iPhone-de-David.local:8080/v1")
os.environ.setdefault("OPENAI_API_KEY", "iphone")

from bfcl_eval.__main__ import cli  # noqa: E402  (BFCL_PROJECT_ROOT é lido no import)
from bfcl_eval.constants.model_config import MODEL_CONFIG_MAPPING, ModelConfig  # noqa: E402
from bfcl_eval.model_handler.api_inference.openai_completion import OpenAICompletionsHandler  # noqa: E402

from controller import AdaptiveHandler  # noqa: E402
from dac import DACHandler, TraceMixin, TracedHandler  # noqa: E402
from paca import PACAHandler  # noqa: E402

# Estudo DAC: condição → (handler, sufixo do model_name, extra_body). `kv` = prefix cache + âncora por turno.
GUARDS = {"think_budget": 512, "repeat_guard": True}
CONDITIONS = {
    "reason-off": (TracedHandler, "direct", None),
    "reason-prefix": (TracedHandler, "direct:prefix", None),
    "reason-kv": (TracedHandler, "direct:kv", None),
    "a-kv": (type("TracedA", (TraceMixin, AdaptiveHandler), {}), "adaptive:kv", None),
    "dac-kv": (DACHandler, "dac:kv", None),
    "dacs-kv": (DACHandler, "dac:kv", GUARDS),
    "reason-guard-kv": (TracedHandler, "direct:kv", GUARDS),
    # PACA (paca.py) e controles: orçamento fixo sem guarda; DAC com orçamento fixo menor (é só um orçamento menor?).
    "reason-b512-kv": (TracedHandler, "direct:kv", {"think_budget": 512}),
    "dacs256-kv": (DACHandler, "dac:kv", {**GUARDS, "think_budget": 256}),
    "dacs128-kv": (DACHandler, "dac:kv", {**GUARDS, "think_budget": 128}),
    "paca-kv": (PACAHandler, "dac:kv", {"repeat_guard": True}),
    # Runtime (analysis/runtime/): mesma Reasoning 512 + kv; só muda o runtime no iPhone.
    "rt-base-kv": (TracedHandler, "direct:kv", {"think_budget": 512}),
    "rt-persist-kv": (TracedHandler, "direct:kv", {"think_budget": 512, "persist_prefix": True}),
    "rt-draft-kv": (TracedHandler, "direct:kv", {"think_budget": 512, "grammar_draft": True}),
    "rt-both-kv": (TracedHandler, "direct:kv", {"think_budget": 512, "persist_prefix": True, "grammar_draft": True}),
    # Pilha completa: DACS (guardas de decode + recuperação) sobre o prefixo persistente.
    "dacs-persist-kv": (DACHandler, "dac:kv", {**GUARDS, "persist_prefix": True}),
    # Pilha + especulação MTP própria em pipeline com escalonador por custo (PROTOCOL-mtp.md; build MLX_LM_MAIN).
    "dacs-persist-mtp-kv": (DACHandler, "dac:kv", {**GUARDS, "persist_prefix": True, "mtp_pipe": "subset",
                                                   "mtp_top": 16384, "mtp_gate": 0.9}),
    # MiniCPM5 (base e SFT) sem raciocínio: referência e pilha (DAC nothink + repeat_guard + prefixo persistente).
    "nt-base-kv": (TracedHandler, "nothink:kv", None),
    "nt-dacs-persist-kv": (DACHandler, "dac:kv", {"repeat_guard": True, "persist_prefix": True}),
}

for slm in ["qwen35", "minicpm5", "lfm25", "gemma4"]:
    for strategy in ["direct", "nothink", "budget_64", "plan_act"]:
        if slm == "lfm25" and strategy == "nothink":
            continue
        for suffix in ["", ":prefix"]:
            MODEL_CONFIG_MAPPING[f"iphone-{slm}-{strategy}{suffix.replace(':', '-')}"] = ModelConfig(
                model_name=f"{slm}:{strategy}{suffix}", display_name=f"{slm} {strategy}{suffix} (iPhone 16 Pro)",
                url="", org="local", license="", model_handler=OpenAICompletionsHandler,
                input_price=None, output_price=None, is_fc_model=True, underscore_to_dot=True)
    # Política A (controller.py): a estratégia muda a cada passo; sempre com o KV incremental.
    MODEL_CONFIG_MAPPING[f"iphone-{slm}-adaptive-prefix"] = ModelConfig(
        model_name=f"{slm}:adaptive:prefix", display_name=f"{slm} adaptive A (iPhone 16 Pro)",
        url="", org="local", license="", model_handler=AdaptiveHandler,
        input_price=None, output_price=None, is_fc_model=True, underscore_to_dot=True)
AdaptiveHandler.log_path = ROOT / "controller-log.jsonl"
for slm in ["qwen35", "minicpm5", "lfm25", "gemma4", "lfm3", "qwen35_sft", "minicpm5_sft"]:
    for cond, (base, suffix, extra) in CONDITIONS.items():
        handler = type(f"{cond}-{slm}", (base,), {
            "condition": cond, "extra_body": extra, "trace_path": ROOT / "trace.jsonl",
            "log_path": ROOT / ("controller-log.jsonl" if cond == "a-kv" else "dac-log.jsonl")})
        MODEL_CONFIG_MAPPING[f"iphone-{slm}-dac-{cond}"] = ModelConfig(
            model_name=f"{slm}:{suffix}", display_name=f"{slm} {cond} (iPhone 16 Pro)",
            url="", org="local", license="", model_handler=handler,
            input_price=None, output_price=None, is_fc_model=True, underscore_to_dot=True)
        # O `evaluate` do bfcl lê o nome da pasta de resultado e troca `_` por `/` (qwen35_sft → qwen35/sft).
        if "_" in slm:
            MODEL_CONFIG_MAPPING[f"iphone-{slm.replace('_', '/')}-dac-{cond}"] = MODEL_CONFIG_MAPPING[f"iphone-{slm}-dac-{cond}"]


def use_slice(argv):
    """`--slice dev|test` grava os IDs da fatia congelada (slice.json) e vira `--run-ids`."""
    if "--slice" not in argv:
        return argv
    i = argv.index("--slice")
    ids = json.loads(SLICE.read_text())[argv[i + 1]]
    (ROOT / "test_case_ids_to_generate.json").write_text(json.dumps({"multi_turn_base": ids}, indent=1) + "\n")
    return argv[:i] + argv[i + 2:] + ["--run-ids"]


if __name__ == "__main__":
    sys.argv = use_slice(sys.argv)
    sys.exit(cli())
