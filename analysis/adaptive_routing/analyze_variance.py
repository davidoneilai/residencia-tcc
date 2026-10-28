#!/usr/bin/env python3
"""Agrega sessão on-device com 3 reps × {direct, plan_act, adaptive}.

Uso:
  python analyze_variance.py --input ../../reports/adaptive-routing/on-device/variance-session.json
"""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def succeeded(row: dict) -> bool:
    if row.get("taskSuccess") is not None:
        return bool(row["taskSuccess"])
    return bool(row.get("success"))


def latency(row: dict) -> float | None:
    if row.get("totalLatencyMs") is not None:
        return float(row["totalLatencyMs"])
    total, load = row.get("totalMs"), row.get("modelLoadMs")
    if total is None:
        return None
    if load is not None and total >= load:
        return float(total) - float(load)
    return float(total)


def mean(xs: list[float]) -> float | None:
    return sum(xs) / len(xs) if xs else None


def std(xs: list[float]) -> float | None:
    if len(xs) < 2:
        return None
    m = mean(xs)
    assert m is not None
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    payload = json.loads(args.input.read_text())
    rows = payload["results"] if isinstance(payload, dict) else payload

    # Agrupa por (strategy efetiva, taskId); adaptive grava strategy=direct|plan_act e strategyId=adaptive
    by: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in rows:
        if row.get("countsTowardAnalysis") is False:
            continue
        sid = row.get("strategyId") or row.get("strategy") or ""
        # Para adaptive, a política de roteamento é strategyId=adaptive
        policy = "adaptive" if sid == "adaptive" else (row.get("strategy") or "")
        tid = row.get("taskId") or row.get("experiment") or ""
        by[(policy, tid)].append(row)

    policies = sorted({p for p, _ in by})
    summary = []
    for policy in policies:
        task_rows = {tid: rs for (p, tid), rs in by.items() if p == policy}
        n_tasks = len(task_rows)
        # Por tarefa: taxa de sucesso média nas reps e mediana da latência
        succ_rates = []
        mean_lats = []
        for tid, rs in task_rows.items():
            oks = [succeeded(r) for r in rs]
            lats = [latency(r) for r in rs if latency(r) is not None]
            succ_rates.append(sum(oks) / len(oks))
            if lats:
                mean_lats.append(sum(lats) / len(lats))
        all_lats = [latency(r) for (_, tid), rs in by.items() if _ == policy for r in rs if latency(r) is not None]
        all_ok = [succeeded(r) for (_, tid), rs in by.items() if _ == policy for r in rs]
        summary.append({
            "policy": policy,
            "n_tasks": n_tasks,
            "n_runs": len(all_ok),
            "success_rate": sum(all_ok) / len(all_ok) if all_ok else 0,
            "mean_task_success": mean(succ_rates),
            "mean_latency_ms": mean(all_lats),
            "std_latency_ms": std(all_lats or []),
            "total_latency_ms": sum(all_lats) if all_lats else 0,
            "router_overhead_ms": sum(r.get("routerDecisionMs") or 0 for (_, tid), rs in by.items() if _ == policy for r in rs),
        })

    text = ["# Variância 3 reps", "", "| Política | n | Sucesso | Latência média (ms) | σ (ms) | Total (ms) |", "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for s in summary:
        text.append(
            f"| {s['policy']} | {s['n_runs']} | {s['success_rate']:.3f} | "
            f"{(s['mean_latency_ms'] or 0):.0f} | {(s['std_latency_ms'] or 0):.0f} | {s['total_latency_ms']:.0f} |"
        )
    text.append("")
    out = args.out or args.input.with_suffix(".variance.md")
    out.write_text("\n".join(text) + "\n")
    (out.with_suffix(".json")).write_text(json.dumps(summary, indent=2))
    print("\n".join(text))
    print(f"gravado {out}")


if __name__ == "__main__":
    main()
