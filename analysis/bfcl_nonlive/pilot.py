"""Piloto BFCL v4 Non-Live: Direct × Reasoning no mesmo SLM, oracle, complementaridade e a
família pré-registrada de regras Adaptive (`reports/bfcl-nonlive/PREREGISTRATION.md`).

Direct = estratégia `nothink` do app; Reasoning = `direct` (thinking completo). Acerto vem do
`ast_checker` oficial via `analysis/slm_bfcl/evaluate.py`. A Adaptive é simulada por tarefa
(greedy: a rota repete a saída da fixa escolhida) e só serve para decidir se vale o TESTE.

    .bfcl-venv/bin/python analysis/bfcl_nonlive/pilot.py results/bfcl-nonlive/pilot-qwen35.json
"""
import argparse
import csv
import json
import math
import random
import statistics as st
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "analysis" / "slm_bfcl"))
from evaluate import grade, self_check  # noqa: E402

SELECTION = ROOT / "reports" / "bfcl-nonlive" / "selection.json"
TASKS = [ROOT / "MobileLLMBench" / f for f in ("BFCLv4NonLive.json", "BFCLv4AST.json", "BFCLv4NonLiveTest2.json")]  # dev_prior vem do AST
NAMES = {"nothink": "Direct", "direct": "Reasoning", "adaptive_nonlive": "Adaptive",
         "budget_128": "Budget-128", "budget_256": "Budget-256", "budget_512": "Budget-512"}
D, R = "Direct", "Reasoning"
MULTI_CUES = [" and ", "respectively", " also ", ";", " as well as ", " both "]  # = ASTRouter.multiCues
TOKENIZERS = {"qwen35": ("mlx-community/Qwen3.5-2B-4bit", "674aaa7240b91e8012fcad5d791b7dfe5ba90207")}


# ---------- dados ----------

def features(task):
    prompt = next(m["content"] for m in reversed(task["messages"]) if m["role"] == "user")
    lower = " " + prompt.lower() + " "
    return {
        "n_functions": len(task["function"]),
        "n_params": sum(len(f.get("parameters", {}).get("properties", {})) for f in task["function"]),
        "prompt_chars": len(prompt),
        "multi_cue": any(c in lower for c in MULTI_CUES),
    }


def thinking_counter(agent):
    if agent not in TOKENIZERS:
        return lambda text, thinking: None
    from huggingface_hub import hf_hub_download
    from tokenizers import Tokenizer
    repo, revision = TOKENIZERS[agent]
    tok = Tokenizer.from_file(hf_hub_download(repo, "tokenizer.json", revision=revision))

    def count(text, thinking):
        """Tokens até `</think>`. Com thinking ligado e sem `</think>`, o modelo pensou até o teto: conta tudo."""
        text = text or ""
        if "</think>" in text:
            return len(tok.encode(text.split("</think>", 1)[0], add_special_tokens=False).ids)
        return len(tok.encode(text, add_special_tokens=False).ids) if thinking else 0
    return count


def load(sessions):
    rows = []
    for path in sessions:
        session = json.loads(path.read_text())
        agent = session["jobs"][0]["agent"] if session["jobs"] else ""
        count = thinking_counter(agent)
        for result in session["results"]:
            if result.get("dataset") != "bfcl_ast" or result.get("phase") != "measured":
                continue
            row = grade(result)
            row["session"] = path.name
            row["agent_id"] = agent
            row["strategy"] = NAMES.get(row["strategy_id"], row["strategy_id"])
            row["latency_ms"] = row["total_ms"] - (row["model_load_ms"] or 0)
            row["reasoning_tokens"] = count(result.get("response"), row["executed"] != "nothink")
            out = row["output_tokens"]
            row["answer_tokens"] = None if out is None or row["reasoning_tokens"] is None else out - row["reasoning_tokens"]
            row["app_version"], row["mlx_swift_lm"] = session.get("appVersion"), session.get("mlxSwiftLM")
            row["order_seed"] = session["config"].get("orderSeed")
            row["evaluation_version"] = session["config"].get("evaluationVersion")
            rows.append(row)
    return rows


# ---------- estatística ----------

def wilson(k, n, z=1.96):
    if n == 0:
        return (math.nan, math.nan)
    p = k / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return (centre - half, centre + half)


def mcnemar(b, c):
    """p exato bilateral para b discordantes de um lado e c do outro."""
    n = b + c
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(b, c) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def boot_mean(diffs, reps=10000, seed=20261105):
    rng = random.Random(seed)
    means = sorted(st.mean(rng.choices(diffs, k=len(diffs))) for _ in range(reps))
    return st.mean(diffs), means[int(0.025 * reps)], means[int(0.975 * reps) - 1]


def summary(rows):
    lat = [r["latency_ms"] / 1000 for r in rows]
    first = [r["first_call_ms"] / 1000 for r in rows if r["first_call_ms"] is not None]
    k, n = sum(r["valid"] for r in rows), len(rows)
    lo, hi = wilson(k, n)
    mean = lambda key: st.mean(r[key] for r in rows) if all(r[key] is not None for r in rows) else None
    return {
        "n": n, "correct": k, "accuracy": k / n, "ci95": [lo, hi],
        "latency_mean_s": st.mean(lat), "latency_median_s": st.median(lat),
        "first_call_median_s": st.median(first) if first else None, "first_call_n": len(first),
        "input_tokens_mean": mean("input_tokens"), "output_tokens_mean": mean("output_tokens"),
        "reasoning_tokens_mean": mean("reasoning_tokens"), "answer_tokens_mean": mean("answer_tokens"),
        "length_stops": sum(r["stop"] == "length" for r in rows),
        "failures": {f: sum(r["failure"] == f for r in rows) for f in sorted({r["failure"] for r in rows if r["failure"]})},
    }


# ---------- roteadores (família pré-registrada) ----------

def rule_family(feats):
    rules = {"always_D": lambda f: D, "always_R": lambda f: R,
             "ast_router": lambda f: R if f["n_functions"] >= 2 or f["multi_cue"] else D}
    for name, test in [("functions>=2", lambda f: f["n_functions"] >= 2), ("multi_cue", lambda f: f["multi_cue"])]:
        rules[f"{name}→R"] = lambda f, t=test: R if t(f) else D
        rules[f"{name}→D"] = lambda f, t=test: D if t(f) else R
    for key in ["prompt_chars", "n_params"]:
        values = sorted(f[key] for f in feats)
        cuts = sorted({values[int(q * (len(values) - 1))] for q in (0.25, 0.5, 0.75)})
        for t in cuts:
            rules[f"{key}>={t}→R"] = lambda f, k=key, t=t: R if f[k] >= t else D
            rules[f"{key}>={t}→D"] = lambda f, k=key, t=t: D if f[k] >= t else R
    return rules


def apply(rule, pairs):
    picks = [rule(p["features"]) for p in pairs]
    return {
        "correct": sum(p[s]["valid"] for p, s in zip(pairs, picks)),
        "latency_mean_s": st.mean(p[s]["latency_ms"] / 1000 for p, s in zip(pairs, picks)),
        "to_R": picks.count(R), "picks": picks,
    }


def best(rules, pairs, routing_only=False):
    scored = {name: apply(rule, pairs) for name, rule in rules.items()}
    pool = [n for n in scored if not routing_only or 0 < scored[n]["to_R"] < len(pairs)] or list(scored)
    return min(pool, key=lambda n: (-scored[n]["correct"], scored[n]["latency_mean_s"])), scored


def leave_one_out(pairs):
    """Escolhe a regra (e os limiares) sem a tarefa i e aplica nela."""
    correct, latency, chosen = 0, [], []
    for i, held in enumerate(pairs):
        train = pairs[:i] + pairs[i + 1:]
        name, _ = best(rule_family([p["features"] for p in train]), train, routing_only=True)
        pick = rule_family([p["features"] for p in train])[name](held["features"])
        correct += held[pick]["valid"]
        latency.append(held[pick]["latency_ms"] / 1000)
        chosen.append(name)
    return {"correct": correct, "latency_mean_s": st.mean(latency),
            "rules_chosen": {n: chosen.count(n) for n in sorted(set(chosen))}}


def router_overhead_us(tasks, reps=200):
    started = time.perf_counter()
    for _ in range(reps):
        for task in tasks:
            f = features(task)
            _ = R if f["n_functions"] >= 2 or f["multi_cue"] else D
    return (time.perf_counter() - started) / (reps * len(tasks)) * 1e6


# ---------- tabelas ----------

def tables(out, groups):
    fmt = lambda v, d=1: "–" if v is None else f"{v:.{d}f}"
    lines = [f"# {out['split']} · {out['agent']} · {out['n_tasks']} tarefas", "",
             "Gerado por `analysis/bfcl_nonlive/pilot.py`. Latência em s, tokens por tarefa (média).", "",
             "| Categoria | Estratégia | Acerto | IC95 | Lat. média | Lat. mediana | 1ª chamada (med.) | Entrada | Saída | Raciocínio | length |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for g in groups:
        for s in (D, R):
            t = out["by_strategy"][s][g]
            lines.append(f"| {g} | {s} | {t['correct']}/{t['n']} ({100 * t['accuracy']:.0f}%) | "
                         f"{100 * t['ci95'][0]:.0f}–{100 * t['ci95'][1]:.0f}% | {fmt(t['latency_mean_s'])} | "
                         f"{fmt(t['latency_median_s'])} | {fmt(t['first_call_median_s'])} (n={t['first_call_n']}) | "
                         f"{fmt(t['input_tokens_mean'], 0)} | {fmt(t['output_tokens_mean'], 0)} | "
                         f"{fmt(t['reasoning_tokens_mean'], 0)} | {t['length_stops']} |")
    lines += ["", "| Categoria | ambas | só Direct | só Reasoning | nenhuma | oracle |", "|---|---|---|---|---|---|"]
    for g in groups:
        c = out["classes"][g]
        lines.append(f"| {g} | {c['both']} | {c['only_D']} | {c['only_R']} | {c['neither']} | "
                     f"{c['both'] + c['only_D'] + c['only_R']} |")
    o, pr = out["oracle"], out["paired"]
    lat = pr["latency_R_minus_D_s"]
    lines += ["", f"McNemar exato (só D × só R): p = {pr['mcnemar_p']:.3f}. "
              f"Latência R − D pareada: {lat['mean']:+.1f} s (IC95 bootstrap {lat['ci95_lo']:+.1f} a {lat['ci95_hi']:+.1f}).",
              f"Oracle: {o['correct']}/{out['n_tasks']} (melhor fixa {o['best_fixed']}; ganho {o['gain_over_best_fixed']:+d}). "
              f"Oracle de custo: {fmt(o['cost_oracle_latency_mean_s'])} s, {o['cost_oracle_to_R']} tarefas em R.", "",
              "| Regra (antes da geração) | Acerto | Lat. média | Tarefas → R |", "|---|---|---|---|"]
    for n, r in sorted(out["routers_in_sample"].items(), key=lambda kv: (-kv[1]["correct"], kv[1]["latency_mean_s"])):
        lines.append(f"| `{n}` | {r['correct']} | {fmt(r['latency_mean_s'])} | {r['to_R']} |")
    loo = out["best_rule_loo"]
    lines += ["", f"Leave-one-out (escolhe a regra que roteia sem a tarefa i): {loo['correct']}/{out['n_tasks']}, "
              f"{fmt(loo['latency_mean_s'])} s; regras escolhidas: {loo['rules_chosen']}.",
              f"Custo da regra no Mac (Python, extração de features + decisão): {out['router_overhead_us_python']:.1f} µs/tarefa.",
              "", "| Critério | Resultado |", "|---|---|"]
    lines += [f"| {k} | {'sim' if v else 'não'} |" for k, v in out["criteria"].items()]
    lines += [f"| **Prosseguir com Adaptive** | **{'sim' if out['go_adaptive'] else 'não'}** |", ""]
    g = out["gate_stage2"]
    lines += [f"Portão da etapa 2: regra `{g['rule']}` {g['rule_correct']} acertos, {fmt(g['rule_latency_mean_s'])} s × "
              f"{g['best_fixed']} {g['fixed_correct']}, {fmt(g['fixed_latency_mean_s'])} s; LOO {g['loo_correct']} → "
              f"**{'passa' if g['passes'] else 'não passa'}**.", ""]
    return "\n".join(lines)


# ---------- main ----------

def main():
    self_check()
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--split", default="pilot", choices=["pilot", "dev_prior", "dev", "test"])  # dev = pilot + dev_prior
    parser.add_argument("--out", type=Path, default=ROOT / "results" / "bfcl-nonlive")
    parser.add_argument("--report", type=Path, default=ROOT / "reports" / "bfcl-nonlive")
    args = parser.parse_args()

    selection = json.loads(SELECTION.read_text())
    flat = lambda part: part if isinstance(part, list) else [i for c in selection["categories"] for i in part[c]]
    ids = flat(selection["pilot"]) + flat(selection["dev_prior"]) if args.split == "dev" else flat(selection[args.split])
    tasks = {t["id"]: t for path in TASKS for t in json.loads(path.read_text())["tasks"]}
    rows = [r for r in load(args.sessions) if r["task"] in ids]
    by = {(r["task"], r["strategy"]): r for r in rows}
    missing = [(i, s) for i in ids for s in (D, R) if (i, s) not in by]
    assert not missing, f"faltam execuções: {missing[:5]}"
    assert len(rows) == 2 * len(ids), "execução duplicada na sessão"

    prefix = f"{args.split}-{rows[0]['agent_id']}"
    graded = args.out / f"{prefix}-graded.jsonl"
    graded.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
    cols = ["task", "category", "agent", "agent_id", "strategy", "strategy_id", "valid", "failure", "n_calls",
            "call_source", "latency_ms", "first_call_ms", "first_text_ms", "prefill_ms", "input_tokens",
            "output_tokens", "reasoning_tokens", "answer_tokens", "stop", "thermal_before", "thermal_after",
            "peak_mem_mb", "run", "task_set", "order_seed", "app_version", "mlx_swift_lm", "evaluation_version", "session"]
    with (args.out / f"{prefix}-rows.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)

    pairs = []
    for i in ids:
        d, r = by[(i, D)], by[(i, R)]
        kind = {(True, True): "both", (True, False): "only_D", (False, True): "only_R", (False, False): "neither"}[(d["valid"], r["valid"])]
        pairs.append({"task": i, "category": d["category"], "features": features(tasks[i]), "class": kind, D: d, R: r})
    with (args.out / f"{prefix}-paired.csv").open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["task", "category", "class", "n_functions", "n_params", "prompt_chars", "multi_cue",
                    "D_valid", "R_valid", "D_latency_ms", "R_latency_ms", "D_first_call_ms", "R_first_call_ms",
                    "D_output_tokens", "R_output_tokens", "R_reasoning_tokens", "D_failure", "R_failure",
                    "oracle_valid", "oracle_cost_pick"])
        for p in pairs:
            f, d, r = p["features"], p[D], p[R]
            w.writerow([p["task"], p["category"], p["class"], f["n_functions"], f["n_params"], f["prompt_chars"],
                        f["multi_cue"], d["valid"], r["valid"], round(d["latency_ms"]), round(r["latency_ms"]),
                        d["first_call_ms"] and round(d["first_call_ms"]), r["first_call_ms"] and round(r["first_call_ms"]),
                        d["output_tokens"], r["output_tokens"], r["reasoning_tokens"], d["failure"], r["failure"],
                        d["valid"] or r["valid"], D if d["valid"] or not r["valid"] else R])

    categories = [c for c in selection["categories"] if any(p["category"] == c for p in pairs)]
    table = {s: {"all": summary([p[s] for p in pairs]),
                 **{c: summary([p[s] for p in pairs if p["category"] == c]) for c in categories}} for s in (D, R)}
    classes = {c: {k: sum(p["class"] == k for p in pairs if c == "all" or p["category"] == c)
                   for k in ("both", "only_D", "only_R", "neither")} for c in ["all", *categories]}

    acc_d, acc_r = table[D]["all"]["correct"], table[R]["all"]["correct"]
    oracle = sum(p["class"] != "neither" for p in pairs)
    cost_pick = [D if p[D]["valid"] or not p[R]["valid"] else R for p in pairs]
    oracle_cost_lat = st.mean(p[s]["latency_ms"] / 1000 for p, s in zip(pairs, cost_pick))
    lat_r = table[R]["all"]["latency_mean_s"]
    best_fixed = max(acc_d, acc_r)
    diffs = [(p[R]["latency_ms"] - p[D]["latency_ms"]) / 1000 for p in pairs]

    name, scored = best(rule_family([p["features"] for p in pairs]), pairs)
    loo = leave_one_out(pairs)
    # Adaptive de verdade manda tarefas para as duas; regra constante é uma fixa.
    routed = {n: s for n, s in scored.items() if 0 < s["to_R"] < len(pairs)}
    name = min(routed, key=lambda n: (-routed[n]["correct"], routed[n]["latency_mean_s"])) if routed else name
    near_r = {n: s for n, s in routed.items() if s["correct"] >= acc_r - 1 and s["correct"] > acc_d}
    fastest_near_r = min(near_r, key=lambda n: near_r[n]["latency_mean_s"]) if near_r else None

    n_only_d, n_only_r = classes["all"]["only_D"], classes["all"]["only_R"]
    gain = oracle - best_fixed
    c4_acc = bool(routed) and gain > 0 and (routed[name]["correct"] - best_fixed) / gain >= 0.5
    c4_lat = fastest_near_r is not None and near_r[fastest_near_r]["latency_mean_s"] <= 0.8 * lat_r
    loo_c4_acc = gain > 0 and (loo["correct"] - best_fixed) / gain >= 0.5
    loo_c4_lat = acc_d < loo["correct"] >= acc_r - 1 and loo["latency_mean_s"] <= 0.8 * lat_r
    criteria = {
        "C1_bidirectional": n_only_d >= 2 and n_only_r >= 2,
        "C2_accuracy_headroom": gain >= 2,
        "C3_latency_headroom": acc_r > acc_d and oracle_cost_lat <= 0.8 * lat_r,
        "C4_capturable_in_sample": bool(c4_acc or c4_lat),
        "C4_capturable_loo": bool(loo_c4_acc or loo_c4_lat),
    }
    go = (criteria["C2_accuracy_headroom"] or criteria["C3_latency_headroom"]) and criteria["C4_capturable_in_sample"]
    # Portão da etapa 2 (PREREGISTRATION.md): contra a melhor fixa em acerto; empate → a mais rápida.
    fixed = min((D, R), key=lambda s: (-table[s]["all"]["correct"], table[s]["all"]["latency_mean_s"]))
    fixed_lat = table[fixed]["all"]["latency_mean_s"]
    chosen = routed.get(name) if routed else None
    gate = {
        "best_fixed": fixed, "rule": name if routed else None,
        "rule_correct": chosen and chosen["correct"], "rule_latency_mean_s": chosen and chosen["latency_mean_s"],
        "fixed_correct": best_fixed, "fixed_latency_mean_s": fixed_lat, "loo_correct": loo["correct"],
        "passes": bool(chosen) and chosen["correct"] >= best_fixed
        and (chosen["correct"] > best_fixed or chosen["latency_mean_s"] <= 0.9 * fixed_lat)
        and loo["correct"] >= best_fixed - 1,
    }

    out = {
        "split": args.split, "agent": rows[0]["agent"], "n_tasks": len(ids),
        "mapping": {"Direct": "nothink", "Reasoning": "direct (thinking completo)"},
        "by_strategy": table, "classes": classes,
        "paired": {"mcnemar_p": mcnemar(n_only_d, n_only_r),
                   "latency_R_minus_D_s": dict(zip(["mean", "ci95_lo", "ci95_hi"], boot_mean(diffs)))},
        "oracle": {"correct": oracle, "best_fixed": best_fixed, "gain_over_best_fixed": gain,
                   "cost_oracle_latency_mean_s": oracle_cost_lat, "cost_oracle_to_R": cost_pick.count(R)},
        "routers_in_sample": {n: {k: v for k, v in s.items() if k != "picks"} for n, s in scored.items()},
        "best_routing_rule_in_sample": name if routed else None, "fastest_routing_rule_within_1_of_R": fastest_near_r,
        "best_rule_loo": loo,
        "router_overhead_us_python": router_overhead_us([tasks[i] for i in ids]),
        "criteria": criteria, "go_adaptive": go, "gate_stage2": gate,
        "thermal_after": {t: sum(r["thermal_after"] == t for r in rows) for t in sorted({r["thermal_after"] for r in rows})},
    }
    args.report.mkdir(parents=True, exist_ok=True)
    (args.report / f"{prefix}-summary.json").write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
    (args.report / f"{prefix}-tables.md").write_text(tables(out, ["all", *categories]))
    print(json.dumps({k: out[k] for k in ("oracle", "criteria", "go_adaptive", "best_routing_rule_in_sample", "gate_stage2")}, indent=1))
    print(f"→ {graded}, {prefix}-rows.csv, {prefix}-paired.csv, {args.report / (prefix + '-summary.json')}", file=sys.stderr)


if __name__ == "__main__":
    main()
