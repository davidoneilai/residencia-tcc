"""Agregação dos JSON do MobileLLMBench. Não inventa latência nem trata pausa térmica como erro do modelo."""

from __future__ import annotations

import math
from collections import defaultdict


def rows_of(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        return payload["results"]
    raise ValueError("JSON precisa ser uma lista de resultados ou uma sessão com results")


def in_analysis(row):
    if row.get("countsTowardAnalysis") is False:
        return False
    phase = row.get("phase")
    return phase in (None, "measured")


def ran(row):
    if row.get("failureKind") in {"thermal", "cancelled"}:
        return False
    if row.get("thermalGate") in {"timeout", "cancelled"}:
        return False
    if row.get("failureKind") in {"grade", "no_tool", "inference", "execution"}:
        return True
    if succeeded(row):
        return True
    return row.get("totalMs") is not None or row.get("totalLatencyMs") is not None or row.get("toolTrace") is not None


def succeeded(row):
    if row.get("taskSuccess") is not None:
        return bool(row["taskSuccess"])
    return bool(row.get("success"))


def inference_latency(row):
    if row.get("totalLatencyMs") is not None:
        return float(row["totalLatencyMs"])
    total = row.get("totalMs")
    load = row.get("modelLoadMs")
    if total is not None and load is not None and total >= load:
        return float(total) - float(load)
    if load is None and total is not None:
        return float(total)
    return None


def tokens_of(row):
    if row.get("generatedTokens") is not None:
        return float(row["generatedTokens"])
    if row.get("outputTokens") is not None:
        return float(row["outputTokens"])
    return None


def time_to_tool(row):
    if row.get("inferenceMs") is not None:
        return float(row["inferenceMs"])
    if row.get("timeToFirstToolCallMs") is not None:
        return float(row["timeToFirstToolCallMs"])
    return None


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2 == 0:
        return (ordered[mid - 1] + ordered[mid]) / 2
    return ordered[mid]


def percentile(values, p):
    if not values:
        return None
    ordered = sorted(values)
    rank = math.ceil(p * len(ordered)) - 1
    return ordered[min(max(rank, 0), len(ordered) - 1)]


def mean(values):
    if not values:
        return None
    return sum(values) / len(values)


def task_id(row):
    return row.get("taskId") or row.get("experiment") or ""


def failure_bucket(row):
    if not ran(row):
        return "not_run"
    kind = row.get("failureKind")
    if kind in {"grade", "no_tool"}:
        return "agent"
    if not succeeded(row):
        return "runtime"
    return "ok"


def aggregate(rows):
    kept = [row for row in rows if in_analysis(row)]
    executed = [row for row in kept if ran(row)]
    groups = defaultdict(list)
    for row in executed:
        groups[(row.get("model") or "", row.get("strategy") or "", row.get("taskKind") or "sem categoria")].append(row)
    summary = []
    for key in sorted(groups):
        summary.append(summary_row(key, groups[key], exploratory(rows)))
    # Rollup por estratégia, somando categorias, para o Pareto.
    by_strategy = defaultdict(list)
    for row in executed:
        by_strategy[(row.get("model") or "", row.get("strategy") or "")].append(row)
    rollup = []
    for key in sorted(by_strategy):
        rollup.append(summary_row((key[0], key[1], "all"), by_strategy[key], exploratory(rows)))
    failures = []
    counts = defaultdict(int)
    for row in kept:
        bucket = failure_bucket(row)
        kind = row.get("failureKind") or ("ok" if succeeded(row) else "desconhecido")
        counts[(row.get("model") or "", row.get("strategy") or "", row.get("taskKind") or "", bucket, kind)] += 1
    for key in sorted(counts):
        failures.append({
            "model": key[0], "strategy": key[1], "category": key[2],
            "bucket": key[3], "kind": key[4], "n": counts[key],
        })
    return {
        "summary": summary + rollup,
        "failures": failures,
        "executed": len(executed),
        "skipped": len(kept) - len(executed),
        "exploratory": exploratory(rows),
        "strategies": rollup,
    }


def summary_row(key, sample, exploratory_flag):
    latencies = [value for value in (inference_latency(row) for row in sample) if value is not None]
    tokens = [value for value in (tokens_of(row) for row in sample) if value is not None]
    tools = [value for value in (time_to_tool(row) for row in sample) if value is not None]
    cold = [value for row in sample if row.get("startKind") == "cold" and (value := inference_latency(row)) is not None]
    warm = [value for row in sample if row.get("startKind") == "warm" and (value := inference_latency(row)) is not None]
    unspecified = sum(1 for row in sample if inference_latency(row) is not None and row.get("startKind") not in {"cold", "warm"})
    classes = sum(1 for group in (cold, warm, [1] if unspecified else []) if group)
    if classes > 1:
        chosen = []
    elif warm:
        chosen = warm
    elif cold:
        chosen = cold
    else:
        chosen = latencies
    hits = sum(1 for row in sample if succeeded(row))
    return {
        "model": key[0],
        "strategy": key[1],
        "category": key[2],
        "n": len(sample),
        "n_success": hits,
        "success_rate": hits / len(sample) if sample else None,
        "median_latency_ms": median(chosen),
        "p90_latency_ms": percentile(chosen, 0.9),
        "mean_tokens": mean(tokens),
        "median_time_to_tool_ms": median(tools),
        "n_missing_latency": len(sample) - len(latencies),
        "cold_n": sum(1 for row in sample if row.get("startKind") == "cold"),
        "warm_n": sum(1 for row in sample if row.get("startKind") == "warm"),
        "start_unspecified_n": sum(1 for row in sample if row.get("startKind") not in {"cold", "warm"}),
        "cold_median_ms": median(cold),
        "warm_median_ms": median(warm),
        "task_ids": sorted({task_id(row) for row in sample}),
        "exploratory": exploratory_flag,
    }


def same_population(strategy_rows):
    sets = [tuple(row["task_ids"]) for row in strategy_rows if row["task_ids"]]
    return bool(sets) and len(set(sets)) == 1


def pareto_front(strategy_rows):
    if not same_population(strategy_rows):
        return []
    points = []
    for row in strategy_rows:
        latency = row["median_latency_ms"]
        if latency is None or row["success_rate"] is None:
            continue
        points.append((row["strategy"], latency, row["success_rate"]))
    front = []
    for strategy, latency, success in points:
        dominated = any(
            other_latency <= latency and other_success >= success and (other_latency < latency or other_success > success)
            for other, other_latency, other_success in points
            if other != strategy
        )
        if not dominated:
            front.append(strategy)
    return front


def exploratory(rows):
    if any((row.get("repetitions") or 1) > 1 for row in rows):
        return False
    return not any((row.get("runIndex") or 1) > 1 for row in rows)


def self_check():
    thermal = {"experiment": "ligar", "strategy": "direct", "model": "m", "success": False, "failureKind": "thermal", "thermalGate": "timeout", "totalMs": None, "phase": "measured", "countsTowardAnalysis": True, "taskKind": "single_tool", "repetitions": 1, "runIndex": 1}
    good = {"experiment": "ligar", "taskId": "ligar", "strategy": "direct", "model": "m", "success": True, "taskSuccess": True, "totalMs": 10000, "modelLoadMs": 1500, "outputTokens": 10, "phase": "measured", "taskKind": "single_tool", "repetitions": 1, "runIndex": 1}
    grade = {"experiment": "safari", "taskId": "safari", "strategy": "direct", "model": "m", "success": False, "taskSuccess": False, "failureKind": "grade", "totalLatencyMs": 300, "generatedTokens": 4, "phase": "measured", "taskKind": "single_tool", "repetitions": 1, "runIndex": 1}
    report = aggregate([thermal, good, grade])
    assert report["skipped"] == 1
    assert report["executed"] == 2
    direct = [row for row in report["strategies"] if row["strategy"] == "direct"][0]
    assert direct["n"] == 2
    assert direct["success_rate"] == 0.5
    assert direct["median_latency_ms"] == 4400
    assert report["exploratory"] is True
    assert inference_latency(good) == 8500
    fast = {"experiment": "ligar", "taskId": "ligar", "strategy": "nothink", "model": "m", "success": True, "totalLatencyMs": 100, "phase": "measured", "taskKind": "single_tool", "repetitions": 1, "runIndex": 1}
    slow = {"experiment": "ligar", "taskId": "ligar", "strategy": "direct", "model": "m", "success": False, "failureKind": "grade", "totalLatencyMs": 400, "phase": "measured", "taskKind": "single_tool", "repetitions": 1, "runIndex": 1}
    same = aggregate([fast, slow])["strategies"]
    assert same_population(same)
    assert pareto_front(same) == ["nothink"]
    other = dict(fast, experiment="mapas", taskId="mapas", strategy="budget_64")
    mixed = aggregate([fast, other])["strategies"]
    assert same_population(mixed) is False
    assert pareto_front(mixed) == []
    assert median([10, 30]) == 20
    assert percentile([10, 20, 30, 40], 0.9) == 40
