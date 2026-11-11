"""TESTE BFCL v4 Non-Live: Direct, Reasoning e Adaptive executadas no iPhone nas 160 tarefas `test`.

Hipóteses pré-registradas (`reports/bfcl-nonlive/PREREGISTRATION.md`, etapa 3):
- H1: acerto(Adaptive) − acerto(Reasoning) > −5 pp pelo limite inferior do IC95 bootstrap pareado.
- H2: latência média(Adaptive) − latência média(Reasoning) < 0 pelo limite superior do IC95 bootstrap pareado.
Também confere cada rota da Adaptive com `FROZEN_POLICY.json`, congelado antes do TESTE.

    .bfcl-venv/bin/python analysis/bfcl_nonlive/test.py results/bfcl-nonlive/test-qwen35.json
"""
import argparse
import csv
import json
import statistics as st
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pilot import (ROOT, SELECTION, TASKS, boot_mean, features, load, mcnemar,  # noqa: E402
                   self_check, summary)

FROZEN = ROOT / "reports" / "bfcl-nonlive" / "FROZEN_POLICY.json"
D, R, A = "Direct", "Reasoning", "Adaptive"
APP = {"nothink": D, "direct": R}


def paired(pairs, x, y, key):
    diffs = [key(p[x]) - key(p[y]) for p in pairs]
    mean, lo, hi = boot_mean(diffs)
    return {"mean": mean, "ci95_lo": lo, "ci95_hi": hi}


def main():
    self_check()
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "results" / "bfcl-nonlive")
    parser.add_argument("--report", type=Path, default=ROOT / "reports" / "bfcl-nonlive")
    args = parser.parse_args()

    selection = json.loads(SELECTION.read_text())
    frozen = json.loads(FROZEN.read_text())
    ids = [i for c in selection["categories"] for i in selection["test"][c]]
    tasks = {t["id"]: t for path in TASKS for t in json.loads(path.read_text())["tasks"]}
    rows = [r for r in load(args.sessions) if r["task"] in ids]
    by = {(r["task"], r["strategy"]): r for r in rows}
    missing = [(i, s) for i in ids for s in (D, R, A) if (i, s) not in by]
    assert not missing, f"faltam execuções: {len(missing)}, p.ex. {missing[:5]}"
    assert len(rows) == 3 * len(ids), "execução duplicada na sessão"

    routes = {i: by[(i, A)]["executed"] for i in ids}
    mismatched = [i for i in ids if routes[i] != frozen["expected_routes_test"][i]]

    prefix = f"test-{rows[0]['agent_id']}"
    (args.out / f"{prefix}-graded.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    cols = ["task", "category", "agent", "agent_id", "strategy", "strategy_id", "executed", "router", "router_ms", "timestamp", "decode_tps",
            "valid", "failure", "n_calls", "call_source", "latency_ms", "first_call_ms", "first_text_ms", "prefill_ms",
            "input_tokens", "output_tokens", "reasoning_tokens", "answer_tokens", "stop", "thermal_before",
            "thermal_after", "peak_mem_mb", "run", "task_set", "order_seed", "app_version", "mlx_swift_lm",
            "evaluation_version", "session"]
    with (args.out / f"{prefix}-rows.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    pairs = [{"task": i, "category": by[(i, D)]["category"], "features": features(tasks[i]), "route": routes[i],
              D: by[(i, D)], R: by[(i, R)], A: by[(i, A)]} for i in ids]
    with (args.out / f"{prefix}-pertask.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["task", "category", "prompt_chars", "route", "D_valid", "R_valid", "A_valid", "A_matches_route",
                    "D_latency_ms", "R_latency_ms", "A_latency_ms", "D_first_call_ms", "R_first_call_ms", "A_first_call_ms",
                    "D_output_tokens", "R_output_tokens", "A_output_tokens", "A_router_ms"])
        for p in pairs:
            d, r, a = p[D], p[R], p[A]
            same = a["valid"] == p[APP[p["route"]]]["valid"]
            w.writerow([p["task"], p["category"], p["features"]["prompt_chars"], p["route"], d["valid"], r["valid"],
                        a["valid"], same, *(round(x["latency_ms"]) for x in (d, r, a)),
                        *(x["first_call_ms"] and round(x["first_call_ms"]) for x in (d, r, a)),
                        d["output_tokens"], r["output_tokens"], a["output_tokens"], a["router_ms"]])

    categories = [c for c in selection["categories"] if any(p["category"] == c for p in pairs)]
    table = {s: {"all": summary([p[s] for p in pairs]),
                 **{c: summary([p[s] for p in pairs if p["category"] == c]) for c in categories}} for s in (D, R, A)}
    acc = lambda x: float(x["valid"])
    lat = lambda x: x["latency_ms"] / 1000
    h1 = paired(pairs, A, R, acc)
    h2 = paired(pairs, A, R, lat)
    only_d = sum(p[D]["valid"] and not p[R]["valid"] for p in pairs)
    only_r = sum(p[R]["valid"] and not p[D]["valid"] for p in pairs)
    simulated = [p[APP[p["route"]]] for p in pairs]
    router_ms = [p[A]["router_ms"] for p in pairs if p[A]["router_ms"] is not None]
    out = {
        "split": "test", "agent": rows[0]["agent"], "n_tasks": len(ids),
        "mapping": {D: "nothink", R: "direct (thinking completo)", A: "adaptive_nonlive (len(prompt) >= 64 → Reasoning)"},
        "by_strategy": table,
        "routes": {"to_R": sum(v == "direct" for v in routes.values()), "to_D": sum(v == "nothink" for v in routes.values()),
                   "mismatched_vs_frozen": mismatched},
        "H1_noninferiority_acc_A_minus_R": {**h1, "margin": -0.05, "passes": h1["ci95_lo"] > -0.05},
        "H2_latency_A_minus_R_s": {**h2, "passes": h2["ci95_hi"] < 0},
        "A_minus_D": {"accuracy": paired(pairs, A, D, acc), "latency_s": paired(pairs, A, D, lat)},
        "R_minus_D": {"accuracy": paired(pairs, R, D, acc), "latency_s": paired(pairs, R, D, lat),
                      "mcnemar_p": mcnemar(only_d, only_r)},
        # Greedy: tokens não dependem da térmica; latência sim (houve throttling, ver REPORT).
        "output_tokens_A_minus_R": paired(pairs, A, R, lambda x: x["output_tokens"]),
        "decode_tps_mean": {s: st.mean(p[s]["decode_tps"] for p in pairs if p[s]["decode_tps"]) for s in (D, R, A)},
        "first_call_A_minus_R_s": paired([p for p in pairs if p[A]["first_call_ms"] and p[R]["first_call_ms"]], A, R,
                                         lambda x: x["first_call_ms"] / 1000),
        "complementarity_D_R": {"both": sum(p[D]["valid"] and p[R]["valid"] for p in pairs), "only_D": only_d,
                                "only_R": only_r, "neither": sum(not p[D]["valid"] and not p[R]["valid"] for p in pairs),
                                "oracle": sum(p[D]["valid"] or p[R]["valid"] for p in pairs)},
        "adaptive_vs_simulated": {"verdicts_equal": sum(p[A]["valid"] == s["valid"] for p, s in zip(pairs, simulated)),
                                  "output_tokens_equal": sum(p[A]["output_tokens"] == s["output_tokens"] for p, s in zip(pairs, simulated)),
                                  "simulated_correct": sum(s["valid"] for s in simulated),
                                  "simulated_latency_mean_s": st.mean(lat(s) for s in simulated)},
        "router_overhead_ms": {"median": st.median(router_ms), "max": max(router_ms), "n": len(router_ms)} if router_ms else None,
        "thermal_after": {t: sum(r["thermal_after"] == t for r in rows) for t in sorted({r["thermal_after"] for r in rows})},
        "app_errors": [(r["task"], r["strategy"], r["app_error"]) for r in rows if r["app_error"]],
    }
    (args.report / f"{prefix}-summary.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    (args.report / f"{prefix}-tables.md").write_text(tables(out, ["all", *categories]))
    print(json.dumps({k: out[k] for k in ("routes", "H1_noninferiority_acc_A_minus_R", "H2_latency_A_minus_R_s",
                                           "adaptive_vs_simulated", "router_overhead_ms", "app_errors")}, indent=1))


def tables(out, groups):
    fmt = lambda v, d=1: "–" if v is None else f"{v:.{d}f}"
    lines = [f"# TESTE · {out['agent']} · {out['n_tasks']} tarefas", "",
             "Gerado por `analysis/bfcl_nonlive/test.py`. Latência em s; tokens por tarefa (média).", "",
             "| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for g in groups:
        for s in (D, R, A):
            t = out["by_strategy"][s][g]
            lines.append(f"| {g} | {s} | {t['correct']}/{t['n']} ({100 * t['accuracy']:.0f}%) | "
                         f"{100 * t['ci95'][0]:.0f}–{100 * t['ci95'][1]:.0f}% | {fmt(t['latency_mean_s'])} | "
                         f"{fmt(t['latency_median_s'])} | {fmt(t['first_call_median_s'])} (n={t['first_call_n']}) | "
                         f"{fmt(t['input_tokens_mean'], 0)} | {fmt(t['output_tokens_mean'], 0)} | "
                         f"{fmt(t['reasoning_tokens_mean'], 0)} | {t['length_stops']} |")
    h1, h2 = out["H1_noninferiority_acc_A_minus_R"], out["H2_latency_A_minus_R_s"]
    ad, rd = out["A_minus_D"], out["R_minus_D"]
    c, sim = out["complementarity_D_R"], out["adaptive_vs_simulated"]
    pp = lambda d: f"{100 * d['mean']:+.1f} pp (IC95 {100 * d['ci95_lo']:+.1f} a {100 * d['ci95_hi']:+.1f})"
    sec = lambda d: f"{d['mean']:+.1f} s (IC95 {d['ci95_lo']:+.1f} a {d['ci95_hi']:+.1f})"
    lines += ["", "| Comparação pareada | Acerto | Latência |", "|---|---|---|",
              f"| Adaptive − Reasoning | {pp(h1)} | {sec(h2)} |",
              f"| Adaptive − Direct | {pp(ad['accuracy'])} | {sec(ad['latency_s'])} |",
              f"| Reasoning − Direct | {pp(rd['accuracy'])} | {sec(rd['latency_s'])} |", "",
              f"- **H1** (não inferioridade, margem −5 pp): **{'passa' if h1['passes'] else 'não passa'}**.",
              f"- **H2** (Adaptive mais rápida que Reasoning): **{'passa' if h2['passes'] else 'não passa'}**.",
              f"- 1ª chamada, Adaptive − Reasoning: {sec(out['first_call_A_minus_R_s'])}.",
              f"- Tokens de saída, Adaptive − Reasoning (independe da térmica): "
              f"{out['output_tokens_A_minus_R']['mean']:+.0f} (IC95 {out['output_tokens_A_minus_R']['ci95_lo']:+.0f} a "
              f"{out['output_tokens_A_minus_R']['ci95_hi']:+.0f}).",
              f"- Decode médio (tok/s), para checar que o throttling pesou igual: "
              + ", ".join(f"{s} {v:.1f}" for s, v in out["decode_tps_mean"].items()) + ".",
              f"- Rotas: {out['routes']['to_R']} → Reasoning, {out['routes']['to_D']} → Direct; "
              f"divergências com `FROZEN_POLICY.json`: {len(out['routes']['mismatched_vs_frozen'])}.",
              f"- Complementaridade D × R: {c['both']} ambas, {c['only_D']} só Direct, {c['only_R']} só Reasoning, "
              f"{c['neither']} nenhuma; oracle {c['oracle']}/{out['n_tasks']}; McNemar p = {rd['mcnemar_p']:.3f}.",
              f"- Adaptive executada × simulada (rota aplicada às fixas): {sim['verdicts_equal']}/{out['n_tasks']} vereditos "
              f"e {sim['output_tokens_equal']}/{out['n_tasks']} contagens de tokens iguais; simulada "
              f"{sim['simulated_correct']} acertos, {fmt(sim['simulated_latency_mean_s'])} s.",
              f"- Custo da decisão no iPhone: mediana {fmt(out['router_overhead_ms']['median'], 4)} ms, "
              f"máximo {fmt(out['router_overhead_ms']['max'], 4)} ms (n = {out['router_overhead_ms']['n']}).", ""]
    return "\n".join(lines)


if __name__ == "__main__":
    main()
