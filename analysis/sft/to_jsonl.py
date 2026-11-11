"""results/sft-smoke/raw/*.json (smoke.py) -> smoke.jsonl (uma linha por caso) + summary.json (uma linha por run/fase/thinking)."""
import json
from pathlib import Path

H = Path(__file__).resolve().parents[2] / "results" / "sft-smoke"
TEMPLATE = {"training": "training", "base": "base", "bf16_training": "training"}
rows, summary = [], []
for path in sorted((H / "raw").glob("*.json")):
    d = json.loads(path.read_text())
    adapter = path.stem.split("_")[0]
    template = TEMPLATE["_".join(path.stem.split("_")[1:])]
    base_q = "bf16" if "bf16" in path.stem else "4bit-g64"
    if adapter == "xlam2":
        template = "training(=base)"
    meta = {k: d.get(k) for k in ("adapter_tensors", "lora_layers", "scale", "probe_equal", "compute_dtype")}
    for phase in ("base_runs", "sft_runs"):
        for r in d[phase]:
            rows.append({"run": d["name"], "adapter": adapter, "template": template, "base_quant": base_q,
                         "phase": "no_lora" if phase == "base_runs" else "lora", **meta,
                         **{k: r[k] for k in ("case", "thinking", "valid", "parsed_format", "calls", "prompt_tokens",
                                              "gen_s", "peak_gb", "raw")}})
        for th in sorted({r["thinking"] for r in d[phase]}, key=str):
            rs = [r for r in d[phase] if r["thinking"] == th]
            summary.append({"run": d["name"], "template": template, "base_quant": base_q,
                            "phase": "no_lora" if phase == "base_runs" else "lora", "thinking": th,
                            "valid": f'{sum(r["valid"] for r in rs)}/{len(rs)}',
                            "formats": sorted({str(r["parsed_format"]) for r in rs}),
                            "failed": [r["case"] for r in rs if not r["valid"]], **meta})
(H / "smoke.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
(H / "summary.json").write_text(json.dumps(summary, indent=1, ensure_ascii=False))
for s in summary:
    print(s["run"], s["phase"], "think=", s["thinking"], s["valid"], s["formats"], s["failed"], "tensors=", s["adapter_tensors"])
