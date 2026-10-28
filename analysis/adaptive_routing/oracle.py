"""Oracle retrospectivo e matriz tarefa × política."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Any

from features import template_family


@dataclass
class PolicyOutcome:
    strategy: str
    success: bool
    latency_ms: float
    row: dict[str, Any]
    n_reps: int = 1
    latency_std_ms: float | None = None


@dataclass
class TaskRow:
    task_id: str
    model: str
    category: str
    prompt: str
    family: str
    policies: dict[str, PolicyOutcome]

    def oracle_choice(self, policies: list[str] | None = None) -> str:
        names = policies or list(self.policies)
        present = [s for s in names if s in self.policies]
        if not present:
            raise KeyError(f"sem políticas para {self.task_id}")
        ok = [s for s in present if self.policies[s].success]
        pool = ok or present
        return min(pool, key=lambda s: self.policies[s].latency_ms)


def succeeded(row: dict) -> bool:
    if row.get("taskSuccess") is not None:
        return bool(row["taskSuccess"])
    return bool(row.get("success"))


def latency_ms(row: dict) -> float | None:
    if row.get("totalLatencyMs") is not None:
        return float(row["totalLatencyMs"])
    total = row.get("totalMs")
    load = row.get("modelLoadMs")
    if total is None:
        return None
    if load is not None and total >= load:
        return float(total) - float(load)
    return float(total)


def load_session(payload: dict) -> tuple[list[dict], dict[str, str]]:
    rows = payload.get("results") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("JSON sem results")
    prompts: dict[str, str] = {}
    for job in (payload.get("jobs") or []) if isinstance(payload, dict) else []:
        tid = job.get("taskID") or job.get("taskId")
        if tid and job.get("prompt"):
            prompts[tid] = job["prompt"]
    return rows, prompts


def routing_policy(row: dict) -> str:
    """Política agendada. Adaptive grava a política efetiva em `strategy` e `strategyId=adaptive`."""
    sid = row.get("strategyId") or row.get("strategy") or ""
    if sid == "adaptive":
        return "adaptive"
    return row.get("strategy") or sid


def _aggregate_rows(strategy: str, rs: list[dict]) -> PolicyOutcome:
    oks = [succeeded(r) for r in rs]
    success = sum(oks) * 2 >= len(oks)
    lats = [latency_ms(r) for r in rs if latency_ms(r) is not None]
    mean_lat = sum(lats) / len(lats) if lats else 0.0
    std = None
    if len(lats) >= 2:
        var = sum((x - mean_lat) ** 2 for x in lats) / (len(lats) - 1)
        std = var ** 0.5
    return PolicyOutcome(
        strategy=strategy, success=success, latency_ms=mean_lat,
        row=rs[-1], n_reps=len(rs), latency_std_ms=std,
    )


def build_matrix(
    rows: list[dict],
    prompts: dict[str, str],
    strategies: list[str] | None = None,
    model: str | None = None,
    include_adaptive: bool = False,
) -> list[TaskRow]:
    buckets: dict[tuple[str, str, str], list[dict]] = defaultdict(list)
    meta: dict[tuple[str, str], dict[str, str]] = {}
    for row in rows:
        if row.get("countsTowardAnalysis") is False:
            continue
        if row.get("phase") not in (None, "measured"):
            continue
        m = row.get("model") or ""
        if model and m != model:
            continue
        s = routing_policy(row)
        if s == "adaptive" and not include_adaptive:
            continue
        if strategies and s not in strategies:
            continue
        tid = row.get("taskId") or row.get("experiment") or ""
        if latency_ms(row) is None:
            continue
        buckets[(m, tid, s)].append(row)
        meta[(m, tid)] = {
            "category": row.get("taskKind") or "unknown",
            "prompt": prompts.get(tid) or row.get("prompt") or "",
        }

    grouped: dict[tuple[str, str], dict[str, PolicyOutcome]] = defaultdict(dict)
    for (m, tid, s), rs in buckets.items():
        grouped[(m, tid)][s] = _aggregate_rows(s, rs)

    out: list[TaskRow] = []
    for (m, tid), pols in sorted(grouped.items()):
        if strategies and not set(strategies).issubset(pols):
            continue
        info = meta[(m, tid)]
        cat = info["category"]
        out.append(
            TaskRow(
                task_id=tid,
                model=m,
                category=cat,
                prompt=info["prompt"],
                family=template_family(tid, cat),
                policies=pols,
            )
        )
    return out


def fixed_policy_stats(tasks: list[TaskRow], strategy: str) -> dict[str, float]:
    n = len(tasks)
    succ = sum(1 for t in tasks if t.policies[strategy].success)
    total_lat = sum(t.policies[strategy].latency_ms for t in tasks)
    return {
        "n": n,
        "success_rate": succ / n if n else 0.0,
        "total_latency_ms": total_lat,
        "mean_latency_ms": total_lat / n if n else 0.0,
        "n_success": succ,
    }


def best_fixed(tasks: list[TaskRow], strategies: list[str]) -> str:
    """Maior taxa de sucesso; empate → menor latência total."""
    ranked = []
    for s in strategies:
        st = fixed_policy_stats(tasks, s)
        ranked.append((-st["success_rate"], st["total_latency_ms"], s))
    ranked.sort()
    return ranked[0][2]


def oracle_stats(tasks: list[TaskRow], strategies: list[str]) -> dict[str, Any]:
    choices = [t.oracle_choice(strategies) for t in tasks]
    succ = sum(1 for t, c in zip(tasks, choices) if t.policies[c].success)
    total_lat = sum(t.policies[c].latency_ms for t, c in zip(tasks, choices))
    n = len(tasks)
    from collections import Counter

    return {
        "n": n,
        "success_rate": succ / n if n else 0.0,
        "total_latency_ms": total_lat,
        "mean_latency_ms": total_lat / n if n else 0.0,
        "n_success": succ,
        "choice_counts": dict(Counter(choices)),
    }


def complementarity(tasks: list[TaskRow], a: str, b: str) -> dict[str, int]:
    only_a = only_b = both = neither = 0
    for t in tasks:
        sa, sb = t.policies[a].success, t.policies[b].success
        if sa and sb:
            both += 1
        elif sa:
            only_a += 1
        elif sb:
            only_b += 1
        else:
            neither += 1
    return {"only_a": only_a, "only_b": only_b, "both": both, "neither": neither}
