"""Confere a aplicação do LoRA de SFT (PEFT) no MLX, no Mac, sobre um prompt real do BFCL-MT DEV.

    <venv mlx-lm>/bin/python -I analysis/runtime/lora_check.py <base bf16> <base 4 bits> <adaptador> <requests.json> <saída.json>

1. Conversão: LoRA em runtime (`linear_to_lora_layers`, o mesmo esquema do `QLoRALinear` do iPhone) contra o LoRA
   fundido pela definição do PEFT, W + (α/r)·B·A, ambos na base bf16. Logits iguais = transposição, escala e nomes certos.
2. Quantização: base 4 bits + LoRA em runtime (o que roda no iPhone) contra bf16 fundido (o modelo treinado),
   com o controle base 4 bits contra base bf16 sem LoRA (quanto a quantização afasta o modelo sozinha).
3. Tamanho do efeito do LoRA: bf16 com e sem LoRA.
Para cada par: diferença máxima dos logits do último token do prompt e concordância greedy em 64 tokens.
"""
import json
import re
import sys
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from mlx.utils import tree_flatten
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache
from mlx_lm.tuner.utils import linear_to_lora_layers

STEPS = 64


def peft(adapter):
    cfg = json.loads((adapter / "adapter_config.json").read_text())
    raw = mx.load(str(adapter / "adapter_model.safetensors"))
    pairs = {}
    for key, value in raw.items():
        match = re.search(r"layers\.(\d+)\.(.+)\.lora_([AB])\.weight$", key)
        if match:
            pairs.setdefault((int(match.group(1)), match.group(2)), {})[match.group(3)] = value
    return cfg, pairs


def modules(model):
    """(camada, caminho relativo à camada) → módulo linear, independente do prefixo de cada arquitetura."""
    found = {}
    for name, module in model.named_modules():
        match = re.search(r"layers\.(\d+)\.(.+)$", name)
        if match and isinstance(module, (nn.Linear, nn.QuantizedLinear)):
            found[(int(match.group(1)), match.group(2))] = (name, module)
    return found


def fuse(model, cfg, pairs):
    scale = cfg["lora_alpha"] / cfg["r"]
    table = modules(model)
    missing = [k for k in pairs if k not in table]
    assert not missing, f"módulos do PEFT sem par no MLX: {missing[:5]}"
    updates = []
    for key, ab in pairs.items():
        name, module = table[key]
        delta = scale * (ab["B"].astype(mx.float32) @ ab["A"].astype(mx.float32))  # [out, r] @ [r, in]
        updates.append((f"{name}.weight", (module.weight.astype(mx.float32) + delta).astype(module.weight.dtype)))
    model.load_weights(updates, strict=False)
    mx.eval(model.parameters())
    return len(updates)


def runtime(model, cfg, pairs):
    table = modules(model)
    keys = sorted({path for _, path in pairs})
    linear_to_lora_layers(model, len(model.layers), {"rank": cfg["r"], "scale": cfg["lora_alpha"] / cfg["r"],
                                                     "dropout": 0.0, "keys": keys})
    dtype = next((v.dtype for k, v in tree_flatten(model.parameters()) if k.endswith(".scales")), mx.bfloat16)
    weights = []
    for key, ab in pairs.items():
        name = table[key][0]
        weights += [(f"{name}.lora_a", ab["A"].T.astype(dtype)), (f"{name}.lora_b", ab["B"].T.astype(dtype))]
    model.load_weights(weights, strict=False)
    mx.eval(model.parameters())
    return len(weights)


def trace(model, ids):
    """Logits do último token do prompt e 64 tokens greedy (com cache: o prompt é lido uma vez)."""
    cache = make_prompt_cache(model)
    logits = model(mx.array([ids]), cache=cache)[0, -1].astype(mx.float32)
    logits0, out = logits, []
    for _ in range(STEPS):
        nxt = int(mx.argmax(logits).item())
        out.append(nxt)
        logits = model(mx.array([[nxt]]), cache=cache)[0, -1].astype(mx.float32)
    return logits0, out


def compare(a, b):
    (la, ta), (lb, tb) = a, b
    same = next((i for i, (x, y) in enumerate(zip(ta, tb)) if x != y), len(ta))
    return {"max_abs_logit_diff": round(float(mx.max(mx.abs(la - lb)).item()), 4),
            "top1_equal": ta[0] == tb[0], "greedy_prefix_equal": same, "of": len(ta)}


def main():
    bf16, q4, adapter, requests, out = sys.argv[1:6]
    cfg, pairs = peft(Path(adapter))
    body = json.loads(Path(requests).read_text())[0]["req"]
    results = {"adapter": adapter, "pairs": len(pairs), "scale": cfg["lora_alpha"] / cfg["r"]}

    model, tok = load(bf16)
    ids = tok.apply_chat_template(body["messages"], tools=body.get("tools"), add_generation_prompt=True)
    results["prompt_tokens"] = len(ids)
    base = trace(model, ids)
    results["fused_tensors"] = fuse(model, cfg, pairs)
    fused = trace(model, ids)
    model, _ = load(bf16)
    results["runtime_tensors"] = runtime(model, cfg, pairs)
    rt_bf16 = trace(model, ids)
    model, _ = load(q4)
    base_q4 = trace(model, ids)
    runtime(model, cfg, pairs)
    rt_q4 = trace(model, ids)

    results["conversion: runtime_bf16 vs fused_bf16"] = compare(rt_bf16, fused)
    results["quantization: runtime_q4 vs fused_bf16"] = compare(rt_q4, fused)
    results["lora effect: fused_bf16 vs base_bf16"] = compare(fused, base)
    results["control: base_q4 vs base_bf16 (sem LoRA)"] = compare(base_q4, base)
    results["texts"] = {k: tok.decode(v[1]) for k, v in
                        {"base_bf16": base, "fused_bf16": fused, "runtime_q4": rt_q4}.items()}
    Path(out).write_text(json.dumps(results, ensure_ascii=False, indent=1))
    print(json.dumps({k: v for k, v in results.items() if k != "texts"}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
