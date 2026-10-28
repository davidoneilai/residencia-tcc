"""Avaliação reprodutível: fixed / heuristic / learned / oracle."""

from __future__ import annotations

import csv
import json
import random
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from features import extract_features, measure_overhead_ms
from oracle import (
    TaskRow,
    best_fixed,
    build_matrix,
    complementarity,
    fixed_policy_stats,
    load_session,
    oracle_stats,
)
from routers import (
    FixedRouter,
    HeuristicRouter,
    Router,
    pick_learned,
)
from split import leave_one_family_out, split_by_family


def simulate_router(tasks: list[TaskRow], router: Router, strategies: list[str]) -> dict[str, Any]:
    succ = 0
    total_lat = 0.0
    overhead = 0.0
    choices: list[str] = []
    by_cat: dict[str, dict[str, float]] = defaultdict(lambda: {"n": 0, "succ": 0, "lat": 0.0})
    by_fam: dict[str, dict[str, float]] = defaultdict(lambda: {"n": 0, "succ": 0, "lat": 0.0})
    for t in tasks:
        decision = router.choose(t.prompt)
        strategy = decision.strategy if decision.strategy in t.policies else strategies[0]
        outcome = t.policies[strategy]
        succ += int(outcome.success)
        total_lat += outcome.latency_ms + decision.decision_ms
        overhead += decision.decision_ms
        choices.append(strategy)
        for bucket, key in ((by_cat, t.category), (by_fam, t.family)):
            bucket[key]["n"] += 1
            bucket[key]["succ"] += int(outcome.success)
            bucket[key]["lat"] += outcome.latency_ms + decision.decision_ms
    n = len(tasks)
    breakdown = decision_breakdown(tasks, router, strategies)
    return {
        "router": router.name,
        "n": n,
        "success_rate": succ / n if n else 0.0,
        "n_success": succ,
        "total_latency_ms": total_lat,
        "mean_latency_ms": total_lat / n if n else 0.0,
        "router_overhead_ms": overhead,
        "mean_router_overhead_ms": overhead / n if n else 0.0,
        "choice_counts": dict(Counter(choices)),
        "decisions": breakdown,
        "by_category": {
            cat: {
                "n": int(v["n"]),
                "success_rate": v["succ"] / v["n"] if v["n"] else 0.0,
                "mean_latency_ms": v["lat"] / v["n"] if v["n"] else 0.0,
            }
            for cat, v in sorted(by_cat.items())
        },
        "by_family": {
            fam: {
                "n": int(v["n"]),
                "success_rate": v["succ"] / v["n"] if v["n"] else 0.0,
                "mean_latency_ms": v["lat"] / v["n"] if v["n"] else 0.0,
            }
            for fam, v in sorted(by_fam.items())
        },
    }


def oracle_eval(tasks: list[TaskRow], strategies: list[str], overhead_ms: float) -> dict[str, Any]:
    base = oracle_stats(tasks, strategies)
    base["router"] = "oracle"
    base["router_overhead_ms"] = overhead_ms * len(tasks)
    base["mean_router_overhead_ms"] = overhead_ms
    base["total_latency_ms"] = base["total_latency_ms"] + base["router_overhead_ms"]
    base["mean_latency_ms"] = base["total_latency_ms"] / max(len(tasks), 1)
    # by category
    by_cat: dict[str, dict[str, float]] = defaultdict(lambda: {"n": 0, "succ": 0, "lat": 0.0})
    by_fam: dict[str, dict[str, float]] = defaultdict(lambda: {"n": 0, "succ": 0, "lat": 0.0})
    for t in tasks:
        c = t.oracle_choice(strategies)
        for bucket, key in ((by_cat, t.category), (by_fam, t.family)):
            bucket[key]["n"] += 1
            bucket[key]["succ"] += int(t.policies[c].success)
            bucket[key]["lat"] += t.policies[c].latency_ms + overhead_ms
    def pack_bucket(src):
        return {
            k: {
                "n": int(v["n"]),
                "success_rate": v["succ"] / v["n"] if v["n"] else 0.0,
                "mean_latency_ms": v["lat"] / v["n"] if v["n"] else 0.0,
            }
            for k, v in sorted(src.items())
        }
    base["by_category"] = pack_bucket(by_cat)
    base["by_family"] = pack_bucket(by_fam)
    return base


def decision_kind(task: TaskRow, chosen: str, strategies: list[str]) -> str:
    oracle = task.oracle_choice(strategies)
    if chosen == oracle:
        return "correct"
    if task.policies[oracle].success and not task.policies[chosen].success:
        return "success_loss"
    return "latency_only"


def decision_breakdown(tasks: list[TaskRow], router: Router, strategies: list[str]) -> dict[str, Any]:
    counts: Counter[str] = Counter()
    losses: list[dict[str, str]] = []
    for t in tasks:
        d = router.choose(t.prompt)
        chosen = d.strategy if d.strategy in t.policies else strategies[0]
        kind = decision_kind(t, chosen, strategies)
        counts[kind] += 1
        if kind != "correct":
            losses.append({
                "task_id": t.task_id,
                "category": t.category,
                "chosen": chosen,
                "oracle": t.oracle_choice(strategies),
                "kind": kind,
                "reason": d.reason,
            })
    return {
        "correct": counts["correct"],
        "success_loss": counts["success_loss"],
        "latency_only": counts["latency_only"],
        "errors": losses,
    }


def clustered_ci(values: list[float], n_boot: int = 4000, seed: int = 736194) -> dict[str, float]:
    """IC 95% bootstrap agrupado por tarefa (um valor por tarefa)."""
    n = len(values)
    if n == 0:
        return {"mean": 0.0, "lo": 0.0, "hi": 0.0}
    mean = sum(values) / n
    if n == 1:
        return {"mean": mean, "lo": mean, "hi": mean}
    rng = random.Random(seed)
    samples = []
    for _ in range(n_boot):
        draw = [values[rng.randrange(n)] for _ in range(n)]
        samples.append(sum(draw) / n)
    samples.sort()
    lo = samples[int(0.025 * n_boot)]
    hi = samples[min(n_boot - 1, int(0.975 * n_boot))]
    return {"mean": mean, "lo": lo, "hi": hi}


def paired_vs_fixed(tasks: list[TaskRow], router: Router, fixed: str, strategies: list[str]) -> dict[str, Any]:
    sr_delta = []
    lat_delta = []
    for t in tasks:
        d = router.choose(t.prompt)
        chosen = d.strategy if d.strategy in t.policies else strategies[0]
        sr_delta.append(int(t.policies[chosen].success) - int(t.policies[fixed].success))
        lat_delta.append(t.policies[chosen].latency_ms + d.decision_ms - t.policies[fixed].latency_ms)
    return {
        "fixed": fixed,
        "success_delta": clustered_ci([float(x) for x in sr_delta]),
        "latency_delta_ms": clustered_ci(lat_delta),
        "n_better_success": sum(1 for x in sr_delta if x > 0),
        "n_worse_success": sum(1 for x in sr_delta if x < 0),
        "n_faster": sum(1 for x in lat_delta if x < 0),
        "n_slower": sum(1 for x in lat_delta if x > 0),
    }


def run_model_experiment(
    tasks: list[TaskRow],
    strategies: list[str],
    seed: str,
    out_dir: Path,
    model_tag: str,
) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    split = split_by_family(tasks, seed=seed)
    # Best fixed escolhido só no train (sem olhar teste).
    fixed_name = best_fixed(split.train, strategies)
    # Overhead de feature extract · medido no prompt médio do train.
    sample = split.train[0].prompt if split.train else "Ligue para +15550100."
    overhead = measure_overhead_ms(sample)

    heuristic = HeuristicRouter(candidates=strategies, default=fixed_name, profile=model_tag)
    learned = pick_learned(split.train, split.val, strategies)
    fixed_router = FixedRouter(fixed_name, strategies)

    # Salva modelo aprendido
    (out_dir / f"{model_tag}_learned.json").write_text(json.dumps(learned.dump(), indent=2))

    rows = []
    for split_name, subset in [("train", split.train), ("val", split.val), ("test", split.test)]:
        for router in (fixed_router, heuristic, learned):
            metrics = simulate_router(subset, router, strategies)
            metrics["split"] = split_name
            metrics["model"] = model_tag
            rows.append(metrics)
        o = oracle_eval(subset, strategies, overhead)
        o["split"] = split_name
        o["model"] = model_tag
        rows.append(o)

    # Matriz tarefa × política (todas as tarefas do modelo)
    matrix_path = out_dir / f"{model_tag}_task_policy_matrix.csv"
    write_matrix_csv(tasks, strategies, matrix_path)

    # Complementaridade no conjunto completo (análise A)
    comp = {}
    if len(strategies) >= 2:
        comp = complementarity(tasks, strategies[0], strategies[1])

    lofo = run_lofo(tasks, strategies, fixed_name)
    summary = {
        "model": model_tag,
        "strategies": strategies,
        "n_tasks": len(tasks),
        "split_sizes": {"train": len(split.train), "val": len(split.val), "test": len(split.test)},
        "families": {
            "train": sorted({t.family for t in split.train}),
            "val": sorted({t.family for t in split.val}),
            "test": sorted({t.family for t in split.test}),
        },
        "best_fixed_on_train": fixed_name,
        "feature_overhead_ms": overhead,
        "learned_router": learned.name,
        "complementarity_full": comp,
        "full_oracle": oracle_stats(tasks, strategies),
        "full_fixed": {s: fixed_policy_stats(tasks, s) for s in strategies},
        "eval_rows": rows,
        "test_comparison": [r for r in rows if r["split"] == "test"],
        "lofo": lofo,
    }
    (out_dir / f"{model_tag}_summary.json").write_text(json.dumps(summary, indent=2))
    write_comparison_csv(rows, out_dir / f"{model_tag}_comparison.csv")
    return summary


def run_lofo(tasks: list[TaskRow], strategies: list[str], default_fixed: str) -> dict[str, Any]:
    """Leave-one-family-out: treina learned/heurística sem a família testada."""
    folds = leave_one_family_out(tasks)
    agg = {
        "fixed": {"succ": 0, "lat": 0.0, "n": 0},
        "heuristic": {"succ": 0, "lat": 0.0, "n": 0},
        "learned": {"succ": 0, "lat": 0.0, "n": 0},
        "oracle": {"succ": 0, "lat": 0.0, "n": 0},
    }
    for _fam, train, test in folds:
        # val = 20% das famílias do train por hash estável
        val_families = sorted({t.family for t in train})
        val_set = set(val_families[::5]) or set(val_families[:1])
        val = [t for t in train if t.family in val_set]
        fit = [t for t in train if t.family not in val_set] or train
        fixed_name = best_fixed(fit, strategies)
        fixed_router = FixedRouter(fixed_name, strategies)
        # profile inferido do model string nas tasks
        profile = "qwen"
        if tasks and "gemma" in (tasks[0].model or "").lower():
            profile = "gemma"
        elif tasks and "systemlanguage" in (tasks[0].model or "").lower():
            profile = "apple"
        heuristic = HeuristicRouter(candidates=strategies, default=default_fixed, profile=profile)
        learned = pick_learned(fit, val or fit, strategies)
        for key, router in (
            ("fixed", fixed_router),
            ("heuristic", heuristic),
            ("learned", learned),
        ):
            m = simulate_router(test, router, strategies)
            agg[key]["succ"] += m["n_success"]
            agg[key]["lat"] += m["total_latency_ms"]
            agg[key]["n"] += m["n"]
        o = oracle_eval(test, strategies, 0.0)
        agg["oracle"]["succ"] += o["n_success"]
        agg["oracle"]["lat"] += o["total_latency_ms"]
        agg["oracle"]["n"] += o["n"]

    def pack(v: dict) -> dict:
        n = max(v["n"], 1)
        return {
            "n": v["n"],
            "success_rate": v["succ"] / n,
            "total_latency_ms": v["lat"],
            "mean_latency_ms": v["lat"] / n,
        }

    return {k: pack(v) for k, v in agg.items()}


def write_matrix_csv(tasks: list[TaskRow], strategies: list[str], path: Path) -> None:
    fields = ["task_id", "model", "category", "family", "oracle"]
    for s in strategies:
        fields += [f"{s}_success", f"{s}_latency_ms"]
    with path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for t in tasks:
            row = {
                "task_id": t.task_id,
                "model": t.model,
                "category": t.category,
                "family": t.family,
                "oracle": t.oracle_choice(strategies),
            }
            for s in strategies:
                row[f"{s}_success"] = int(t.policies[s].success)
                row[f"{s}_latency_ms"] = f"{t.policies[s].latency_ms:.3f}"
            w.writerow(row)


def write_comparison_csv(rows: list[dict], path: Path) -> None:
    fields = [
        "model", "split", "router", "n", "n_success", "success_rate",
        "total_latency_ms", "mean_latency_ms", "router_overhead_ms", "mean_router_overhead_ms",
    ]
    with path.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def load_tasks(path: Path, model: str | None, strategies: list[str]) -> list[TaskRow]:
    payload = json.loads(path.read_text())
    rows, prompts = load_session(payload)
    return build_matrix(rows, prompts, strategies=strategies, model=model)
