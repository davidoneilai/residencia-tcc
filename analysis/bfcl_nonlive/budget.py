"""Estudo B (orçamento de raciocínio) no BFCL v4 Non-Live: Reasoning × Budget-b, em blocos com resfriamento.

Protocolo e critérios: `reports/bfcl-nonlive/PREREGISTRATION.md`, seção "Estudo B".
- `--mode dev`: escolhe b* (menor b com acerto ≥ Reasoning − 1 e tokens ≤ 90 % dos da Reasoning) e grava
  `FROZEN_BUDGET.json` se algum b passar. Também confere que a Reasoning repete o DEV anterior (determinismo).
- `--mode test2`: H1 (não inferioridade −5 pp), H2 (tokens), H3 (latência), com IC95 bootstrap pareado.

    .bfcl-venv/bin/python analysis/bfcl_nonlive/budget.py --mode dev results/bfcl-nonlive/budget-dev-b*-qwen35.json
    .bfcl-venv/bin/python analysis/bfcl_nonlive/budget.py --mode test2 results/bfcl-nonlive/budget-test2-b*-qwen35.json
"""
import argparse
import csv
import json
import statistics as st
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pilot import ROOT, boot_mean, load, self_check, summary  # noqa: E402

REPORT = ROOT / "reports" / "bfcl-nonlive"
OUT = ROOT / "results" / "bfcl-nonlive"
FROZEN = REPORT / "FROZEN_BUDGET.json"
R = "Reasoning"
CATEGORIES = ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]


def paired(tasks, by, x, y, key):
    mean, lo, hi = boot_mean([key(by[(t, x)]) - key(by[(t, y)]) for t in tasks])
    return {"mean": mean, "ci95_lo": lo, "ci95_hi": hi}


def compare(tasks, by, s):
    acc = lambda r: float(r["valid"])
    rescued = [t for t in tasks if by[(t, s)]["valid"] and not by[(t, R)]["valid"]]
    lost = [t for t in tasks if by[(t, R)]["valid"] and not by[(t, s)]["valid"]]
    return {
        "accuracy": paired(tasks, by, s, R, acc),
        "output_tokens": paired(tasks, by, s, R, lambda r: r["output_tokens"]),
        "latency_s": paired(tasks, by, s, R, lambda r: r["latency_ms"] / 1000),
        "rescued": rescued, "lost": lost,
        "cap_binds": sum((by[(t, s)]["reasoning_tokens"] or 0) >= int(s.split("-")[1]) for t in tasks),
    }


def tables(out, strategies):
    fmt = lambda v, d=1: "–" if v is None else f"{v:.{d}f}"
    lines = [f"# Estudo B · {out['mode']} · {out['n_tasks']} tarefas", "",
             "Gerado por `analysis/bfcl_nonlive/budget.py`. Blocos curtos com resfriamento; latência em s.", "",
             "| Categoria | Estratégia | Acerto | Lat. média | 1ª chamada (med.) | Saída | Raciocínio | length |",
             "|---|---|---|---|---|---|---|---|"]
    for g in ["all", *CATEGORIES]:
        for s in strategies:
            t = out["by_strategy"][s].get(g)
            if t:
                lines.append(f"| {g} | {s} | {t['correct']}/{t['n']} ({100 * t['accuracy']:.0f}%) | {fmt(t['latency_mean_s'])} | "
                             f"{fmt(t['first_call_median_s'])} | {fmt(t['output_tokens_mean'], 0)} | "
                             f"{fmt(t['reasoning_tokens_mean'], 0)} | {t['length_stops']} |")
    pp = lambda d: f"{100 * d['mean']:+.1f} pp ({100 * d['ci95_lo']:+.1f} a {100 * d['ci95_hi']:+.1f})"
    num = lambda d, u="": f"{d['mean']:+.1f}{u} ({d['ci95_lo']:+.1f} a {d['ci95_hi']:+.1f})"
    lines += ["", "| Contra a Reasoning (pareado, IC95) | Acerto | Tokens de saída | Latência | Resgatadas | Perdidas | Teto atingido |",
              "|---|---|---|---|---|---|---|"]
    for s, c in out["vs_reasoning"].items():
        lines.append(f"| {s} | {pp(c['accuracy'])} | {num(c['output_tokens'])} | {num(c['latency_s'], ' s')} | "
                     f"{len(c['rescued'])} | {len(c['lost'])} | {c['cap_binds']} |")
    lines.append("")
    for key in ("determinism", "gate", "hypotheses"):
        if key in out:
            lines += [f"**{key}:** `{json.dumps(out[key], ensure_ascii=False)}`", ""]
    return "\n".join(lines)


def main():
    self_check()
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["dev", "test2"], required=True)
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--dry", action="store_true", help="teste do script: sem checar n, saída em /tmp, sem congelar")
    args = parser.parse_args()
    global OUT, REPORT
    if args.dry:
        OUT = REPORT = Path("/tmp/budget-dry")
        OUT.mkdir(exist_ok=True)

    rows = load(sorted(args.sessions))
    strategies = [R] + sorted({r["strategy"] for r in rows} - {R}, key=lambda s: int(s.split("-")[1]))
    by = {(r["task"], r["strategy"]): r for r in rows}
    tasks = sorted({r["task"] for r in rows})
    missing = [(t, s) for t in tasks for s in strategies if (t, s) not in by]
    assert not missing, f"faltam execuções: {len(missing)}, p.ex. {missing[:4]}"
    assert len(rows) == len(tasks) * len(strategies), "execução duplicada"
    if not args.dry:
        assert len(tasks) == (80 if args.mode == "dev" else 160), f"{len(tasks)} tarefas"

    prefix = f"budget-{args.mode}-qwen35"
    (OUT / f"{prefix}-graded.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    with (OUT / f"{prefix}-pertask.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["task", "category"] + [f"{s}_{k}" for s in strategies
                                          for k in ("valid", "output_tokens", "reasoning_tokens", "latency_ms", "stop")])
        for t in tasks:
            w.writerow([t, by[(t, R)]["category"]] + [v for s in strategies for v in (
                by[(t, s)]["valid"], by[(t, s)]["output_tokens"], by[(t, s)]["reasoning_tokens"],
                round(by[(t, s)]["latency_ms"]), by[(t, s)]["stop"])])

    table = {s: {"all": summary([by[(t, s)] for t in tasks]),
                 **{c: summary([by[(t, s)] for t in tasks if by[(t, s)]["category"] == c]) for c in CATEGORIES
                    if any(by[(t, s)]["category"] == c for t in tasks)}}
             for s in strategies}
    out = {"mode": args.mode, "n_tasks": len(tasks), "agent": rows[0]["agent"], "by_strategy": table,
           "vs_reasoning": {s: compare(tasks, by, s) for s in strategies if s != R},
           "thermal_after": {k: sum(r["thermal_after"] == k for r in rows) for k in sorted({r["thermal_after"] for r in rows})},
           "app_errors": [(r["task"], r["strategy"], r["app_error"]) for r in rows if r["app_error"]],
           "sessions": sorted(p.name for p in args.sessions)}

    if args.mode == "dev":
        before = {r["task"]: r for r in map(json.loads, (ROOT / "results" / "bfcl-nonlive" / "dev-qwen35-graded.jsonl").read_text().splitlines())
                  if r["strategy"] == R}
        out["determinism"] = {
            "reasoning_verdicts_equal_previous_dev": sum(by[(t, R)]["valid"] == before[t]["valid"] for t in tasks if t in before),
            "reasoning_tokens_equal_previous_dev": sum(by[(t, R)]["output_tokens"] == before[t]["output_tokens"] for t in tasks if t in before),
            "n": len(tasks)}
        acc_r, tok_r = table[R]["all"]["correct"], table[R]["all"]["output_tokens_mean"]
        ok = [s for s in strategies if s != R and table[s]["all"]["correct"] >= acc_r - 1
              and table[s]["all"]["output_tokens_mean"] <= 0.9 * tok_r]
        chosen = min(ok, key=lambda s: int(s.split("-")[1])) if ok else None
        out["gate"] = {"rule": "menor b com acerto ≥ Reasoning − 1 e tokens ≤ 90 % da Reasoning",
                       "reasoning": {"correct": acc_r, "tokens": tok_r},
                       "candidates": {s: {"correct": table[s]["all"]["correct"], "tokens": table[s]["all"]["output_tokens_mean"]}
                                      for s in strategies if s != R},
                       "passing": ok, "chosen": chosen}
        if chosen and not args.dry and not FROZEN.exists():
            FROZEN.write_text(json.dumps({
                "frozen_at": "2026-11-05", "frozen_before_test2_execution": True, "study": "B",
                "strategy": "budget_" + chosen.split("-")[1], "budget": int(chosen.split("-")[1]),
                "selected_on": "DEV 80 (pilot + dev_prior), blocos budget-dev-b1..b4",
                "dev_gate": out["gate"]}, indent=1, ensure_ascii=False) + "\n")
    else:
        frozen = json.loads(FROZEN.read_text())
        s = f"Budget-{frozen['budget']}"
        c = out["vs_reasoning"][s]
        out["hypotheses"] = {
            "strategy": s,
            "H1_noninferiority": {**c["accuracy"], "margin": -0.05, "passes": c["accuracy"]["ci95_lo"] > -0.05},
            "H2_tokens": {**c["output_tokens"], "passes": c["output_tokens"]["ci95_hi"] < 0},
            "H3_latency": {**c["latency_s"], "passes": c["latency_s"]["ci95_hi"] < 0},
        }
    (REPORT / f"{prefix}-summary.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    (REPORT / f"{prefix}-tables.md").write_text(tables(out, strategies))
    print(json.dumps({k: out[k] for k in ("determinism", "gate", "hypotheses", "app_errors") if k in out},
                     indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
