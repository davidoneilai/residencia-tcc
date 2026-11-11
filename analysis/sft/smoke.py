"""Mac smoke test: MLX 4-bit base + PEFT LoRA adapter applied at runtime (QLoRA-style),
mirroring what mlx-swift-lm's LoRAContainer.fromPEFT + QLoRALinear do on the iPhone.

Run with: venv/bin/python -I scripts/smoke.py --base DIR --adapter DIR --name NAME [--prefix FROM=TO]
"""
import argparse
import json
import re
import time
from pathlib import Path

import mlx.core as mx
from mlx.utils import tree_flatten
from mlx_lm import load
from mlx_lm.generate import generate
from mlx_lm.sample_utils import make_sampler
from mlx_lm.tuner.utils import linear_to_lora_layers

WEATHER = {"type": "function", "function": {
    "name": "get_weather", "description": "Get the current weather for a city.",
    "parameters": {"type": "object", "properties": {
        "city": {"type": "string", "description": "City name, e.g. Paris"}}, "required": ["city"]}}}
EMAIL = {"type": "function", "function": {
    "name": "send_email", "description": "Send an email.",
    "parameters": {"type": "object", "properties": {
        "to": {"type": "string", "description": "Recipient address"},
        "subject": {"type": "string", "description": "Subject line"},
        "body": {"type": "string", "description": "Message body"}}, "required": ["to", "subject", "body"]}}}

ALARM = {"type": "function", "function": {
    "name": "create_alarm", "description": "Create an alarm on the phone.",
    "parameters": {"type": "object", "properties": {
        "time": {"type": "string", "description": "Time in HH:MM, 24h"},
        "label": {"type": "string", "description": "Optional label"}}, "required": ["time"]}}}
EVENT = {"type": "function", "function": {
    "name": "create_event", "description": "Create a calendar event.",
    "parameters": {"type": "object", "properties": {
        "title": {"type": "string", "description": "Event title"},
        "date": {"type": "string", "description": "Date YYYY-MM-DD"},
        "duration_minutes": {"type": "integer", "description": "Duration in minutes"}},
        "required": ["title", "date"]}}}


def has(name, **expect):
    def ok(calls):
        for c in calls:
            if c["name"] != name:
                continue
            args = c["arguments"]
            if all(str(args.get(k, "")).lower().find(str(v).lower()) >= 0 for k, v in expect.items()):
                return True
        return False
    return ok


CASES = [
    ("weather", [WEATHER], "What's the weather like in Paris right now?", has("get_weather", city="paris")),
    ("weather_tokyo", [WEATHER, EMAIL], "Is it raining in Tokyo?", has("get_weather", city="tokyo")),
    ("pick_tool", [WEATHER, EMAIL], "Send an email to bob@example.com with subject 'Hi' and body 'See you at 6'.",
     has("send_email", to="bob@example.com")),
    ("alarm", [WEATHER, ALARM, EVENT], "Wake me up at 6:45 tomorrow, label it Gym.", has("create_alarm", time="6:45")),
    ("event", [ALARM, EVENT], "Put a 30 minute meeting called Standup on 2026-11-10 in my calendar.",
     has("create_event", title="standup", date="2026-11-10")),
    ("parallel", [WEATHER], "What's the weather in Rome and in Madrid?",
     lambda calls: has("get_weather", city="rome")(calls) and has("get_weather", city="madrid")(calls)),
]


def recover(text, known):
    """Python port of MLXPhoneBackend.recoverToolCalls (MiniCPM XML, <tool_call> JSON, bare JSON obj/array)."""
    text = re.sub(r"<think>[\s\S]*?</think>", "", text)
    if "<think>" in text:
        text = text[: text.index("<think>")]
    text = text.strip()
    calls = []
    for block in text.split('<function name="')[1:]:
        name = block[: block.find('"')]
        if name not in known:
            continue
        body = block.split("</function>", 1)[0]
        args = {m.group(1): m.group(2) for m in re.finditer(r'<param name="([^"]+)">([\s\S]*?)</param>', body)}
        calls.append({"name": name, "arguments": args})
    if calls:
        return calls, "minicpm_xml"
    for m in re.finditer(r"<function=([^>\s]+)>([\s\S]*?)</function>", text):  # Qwen3.5 native (.xmlFunction)
        if m.group(1) in known:
            args = {k: v.strip() for k, v in re.findall(r"<parameter=([^>\s]+)>([\s\S]*?)</parameter>", m.group(2))}
            calls.append({"name": m.group(1), "arguments": args})
    if calls:
        return calls, "qwen_xml_function"
    for m in re.finditer(r"<tool_call>([\s\S]*?)(?:</tool_call>|$)", text):
        try:
            obj = json.loads(m.group(1).strip())
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("name") in known:
            calls.append({"name": obj["name"], "arguments": obj.get("arguments") or {}})
    if calls:
        return calls, "tool_call_json"
    try:
        obj = json.loads(text)
    except Exception:
        return [], None
    items = obj if isinstance(obj, list) else [obj]
    for it in items:
        if isinstance(it, dict) and it.get("name") in known:
            calls.append({"name": it["name"], "arguments": it.get("arguments") or it.get("parameters") or {}})
    return calls, ("bare_json" if calls else None)


def peft_to_mlx(path, prefix_map, dtype):
    raw = mx.load(str(path / "adapter_model.safetensors"))
    cfg = json.loads((path / "adapter_config.json").read_text())
    out, keys = {}, set()
    for k, v in raw.items():
        k = k.removeprefix("base_model.model.")
        for a, b in prefix_map:
            if k.startswith(a):
                k = b + k[len(a):]
        if k.endswith(".lora_A.weight"):
            mod, leaf = k[: -len(".lora_A.weight")], "lora_a"
        elif k.endswith(".lora_B.weight"):
            mod, leaf = k[: -len(".lora_B.weight")], "lora_b"
        else:
            continue
        m = re.search(r"\.layers\.\d+\.(.+)$", mod)
        keys.add(m.group(1))
        out[f"{mod}.{leaf}"] = v.T.astype(dtype)
    return out, sorted(keys), cfg


def run_cases(model, tok, template, thinking, max_tokens):
    results = []
    sampler = make_sampler(temp=0.0)
    for case, tools, prompt, ok in CASES:
        messages = [{"role": "user", "content": prompt}]
        kw = {"tools": tools, "add_generation_prompt": True, "tokenize": False, "chat_template": template}
        if thinking is not None:
            kw["enable_thinking"] = thinking
        text_prompt = tok.apply_chat_template(messages, **kw)
        ids = tok.encode(text_prompt, add_special_tokens=False)
        mx.reset_peak_memory()
        t = time.time()
        out = generate(model, tok, prompt=ids, max_tokens=max_tokens, sampler=sampler, verbose=False)
        dt = time.time() - t
        calls, fmt = recover(out, {x["function"]["name"] for x in tools})
        results.append({"case": case, "thinking": thinking, "prompt_tokens": len(ids), "gen_s": round(dt, 2),
                        "peak_gb": round(mx.get_peak_memory() / 1e9, 2), "parsed_format": fmt, "calls": calls,
                        "valid": bool(ok(calls)), "raw": out})
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--adapter", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--prefix", action="append", default=[])
    ap.add_argument("--thinking", default="none", help="none|false|true|both")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--out", required=True)
    ap.add_argument("--fuse-quantize", action="store_true", help="after SFT runs on a bf16 base: fuse LoRA, quantize 4-bit g64, rerun")
    ap.add_argument("--template", default=None, help="chat_template.jinja path (default: adapter's)")
    a = ap.parse_args()
    adapter = Path(a.adapter)
    prefix_map = [tuple(p.split("=", 1)) for p in a.prefix]
    thinking = {"none": [None], "false": [False], "true": [True], "both": [False, True]}[a.thinking]

    t = time.time()
    model, tok = load(a.base)
    base_load_s = time.time() - t
    template = Path(a.template or adapter / "chat_template.jinja").read_text()
    params = dict(tree_flatten(model.parameters()))
    scales = [v for k, v in params.items() if k.endswith(".scales")]
    dtype = scales[0].dtype if scales else mx.bfloat16
    report = {"name": a.name, "base": a.base, "adapter": a.adapter, "base_load_s": round(base_load_s, 2),
              "compute_dtype": str(dtype), "base_peak_gb_after_load": round(mx.get_peak_memory() / 1e9, 2)}

    report["base_runs"] = [r for th in thinking for r in run_cases(model, tok, template, th, a.max_tokens)]

    t = time.time()
    weights, keys, cfg = peft_to_mlx(adapter, prefix_map, dtype)
    n_layers = len(model.layers)
    linear_to_lora_layers(model, n_layers, {"rank": cfg["r"], "scale": cfg["lora_alpha"] / cfg["r"],
                                            "dropout": 0.0, "keys": keys})
    params = dict(tree_flatten(model.parameters()))
    missing = [k for k in weights if k not in params]
    shape_bad = [k for k in weights if k in params and params[k].shape != weights[k].shape]
    if missing or shape_bad:
        raise SystemExit(f"adapter mismatch: missing={missing[:5]} ({len(missing)}) shape={shape_bad[:5]}")
    model.load_weights(list(weights.items()), strict=False)
    mx.eval(model.parameters())
    probe = next(iter(weights))
    loaded = dict(tree_flatten(model.parameters()))[probe]
    report.update({"adapter_apply_s": round(time.time() - t, 2), "adapter_tensors": len(weights),
                   "lora_keys": keys, "lora_layers": n_layers, "scale": cfg["lora_alpha"] / cfg["r"],
                   "probe_equal": bool(mx.array_equal(loaded, weights[probe]).item())})
    report["sft_runs"] = [r for th in thinking for r in run_cases(model, tok, template, th, a.max_tokens)]
    if a.fuse_quantize:
        import mlx.nn as nn
        from mlx.utils import tree_unflatten
        from mlx_lm.tuner.lora import LoRALinear
        from mlx_lm.utils import quantize_model
        fused = [(n, m.fuse()) for n, m in model.named_modules() if isinstance(m, LoRALinear)]
        model.update_modules(tree_unflatten(fused))
        model, _ = quantize_model(model, {}, 64, 4)
        mx.eval(model.parameters())
        report["fused_layers"] = len(fused)
        report["fused_q4_runs"] = [r for th in thinking for r in run_cases(model, tok, template, th, a.max_tokens)]
    Path(a.out).write_text(json.dumps(report, indent=1, ensure_ascii=False))
    phases = [p for p in ("base_runs", "sft_runs", "fused_q4_runs") if p in report]
    for phase in phases:
        for r in report[phase]:
            print(phase, r["case"], "think=", r["thinking"], "valid=", r["valid"], r["parsed_format"],
                  r["gen_s"], "s", r["peak_gb"], "GB |", repr(r["raw"][:300]))
    for phase in phases:
        for th in thinking:
            rs = [r for r in report[phase] if r["thinking"] == th]
            print("SUMMARY", phase, "think=", th, "valid", sum(r["valid"] for r in rs), "/", len(rs),
                  "parsed", sum(bool(r["calls"]) for r in rs), "/", len(rs))
    print({k: v for k, v in report.items() if not k.endswith("_runs")})


if __name__ == "__main__":
    main()
