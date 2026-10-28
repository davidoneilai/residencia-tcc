#!/usr/bin/env python3
"""ActionAware vs NoThink vs NoThink+runtime. Recorte apple_step_pilot_12."""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "reports" / "adaptive-inference" / "action-aware"
POLICIES = ["nothink", "nothink_runtime", "action_aware"]


def succeeded(r):
    if r.get("taskSuccess") is not None:
        return bool(r["taskSuccess"])
    return bool(r.get("success"))


def load(path):
    s = json.loads(Path(path).read_text())
    return s, s.get("results") or []


def rounds(r):
    n = 0
    for ev in r.get("controllerTrace") or []:
        if ":gen:" in ev or ":fast:" in ev or ":recover:" in ev or ":step:" in ev:
            n += 1
    return n


def recoveries(r):
    return sum(1 for ev in (r.get("controllerTrace") or []) if ":recover:" in ev)


def extra_calls(r):
    return (r.get("invalidToolCalls") or 0) + (r.get("duplicateToolCalls") or 0)


def pack(rows, pol):
    rs = [r for r in rows if r.get("strategy") == pol]
    n = len(rs)
    if not n:
        return {"n": 0}
    fail = [r for r in rs if not succeeded(r)]
    seq = [r for r in rs if r.get("taskKind") == "sequential"]
    by_kind = {}
    for k in ("single_tool", "multi_tool", "sequential"):
        sub = [r for r in rs if r.get("taskKind") == k]
        by_kind[k] = {
            "n": len(sub),
            "success": (sum(succeeded(r) for r in sub) / len(sub)) if sub else None,
        }
    lats = [(r.get("totalLatencyMs") or r.get("totalMs") or 0) for r in rs]
    toks = [r.get("outputTokens") or 0 for r in rs]
    rec = [recoveries(r) for r in rs]
    return {
        "n": n,
        "success": sum(succeeded(r) for r in rs) / n,
        "n_success": sum(succeeded(r) for r in rs),
        "mean_lat_ms": sum(lats) / n,
        "mean_tokens": sum(toks) / n,
        "mean_rounds": sum(rounds(r) for r in rs) / n,
        "extra_calls": sum(extra_calls(r) for r in rs),
        "recoveries": sum(rec),
        "tasks_with_recovery": sum(1 for x in rec if x > 0),
        "length": sum(1 for r in rs if r.get("stopReason") == "length"),
        "no_tool": sum(1 for r in fail if r.get("failureKind") == "no_tool"),
        "execution": sum(1 for r in fail if r.get("failureKind") == "execution"),
        "grade": sum(1 for r in fail if r.get("failureKind") == "grade"),
        "seq_n": len(seq),
        "seq_success": (sum(succeeded(r) for r in seq) / len(seq)) if seq else None,
        "overhead_ms": sum(r.get("routerDecisionMs") or 0 for r in rs) / n,
        "by_kind": by_kind,
        "triggers": recovery_triggers(rs),
    }


def recovery_triggers(rs):
    counts = defaultdict(int)
    for r in rs:
        for ev in r.get("controllerTrace") or []:
            if ":recover:" not in ev:
                continue
            parts = ev.split(":")
            if len(parts) >= 3:
                counts[parts[2]] += 1
    return dict(counts)


def per_task(rows):
    by = defaultdict(dict)
    for r in rows:
        tid = r.get("taskId") or r.get("experiment")
        by[tid][r.get("strategy")] = r
    out = []
    for tid, pols in sorted(by.items()):
        base = pols.get("nothink_runtime") or pols.get("nothink") or {}
        aware = pols.get("action_aware") or {}
        rec = recoveries(aware)
        rec_ok = bool(rec and succeeded(aware) and not succeeded(base))
        out.append({
            "id": tid,
            "kind": (aware or base).get("taskKind"),
            "nothink": succeeded(pols.get("nothink") or {}),
            "nothink_runtime": succeeded(base) if "nothink_runtime" in pols else None,
            "action_aware": succeeded(aware) if aware else None,
            "recoveries": rec,
            "recovery_success": rec_ok,
            "extra_calls_aware": extra_calls(aware) if aware else 0,
            "lat_nothink": (pols.get("nothink") or {}).get("totalLatencyMs"),
            "lat_runtime": base.get("totalLatencyMs"),
            "lat_aware": aware.get("totalLatencyMs"),
            "recovery_cost_ms": (
                (aware.get("totalLatencyMs") or 0) - (base.get("totalLatencyMs") or 0)
                if rec else None
            ),
            "failure_aware": None if succeeded(aware) else (aware.get("failureKind") if aware else None),
            "invalid_aware": aware.get("invalidToolCalls") if aware else None,
            "dup_aware": aware.get("duplicateToolCalls") if aware else None,
        })
    return out


def write_report(summary, out: Path):
    rows = summary["policies"]
    nt = rows.get("nothink") or {}
    rt = rows.get("nothink_runtime") or {}
    aw = rows.get("action_aware") or {}
    rt_s = rt.get("success") or 0
    aw_s = aw.get("success") or 0
    if aw_s > rt_s + 1e-9:
        verdict = "sim"
    elif abs(aw_s - rt_s) < 1e-9:
        verdict = "empate"
    else:
        verdict = "não"
    rec_ok = sum(1 for t in summary["tasks"] if t.get("recovery_success"))
    costs = [t["recovery_cost_ms"] for t in summary["tasks"] if t.get("recovery_cost_ms") is not None]
    lines = [
        "# ActionAware — piloto de recuperação por estado de ferramenta",
        "",
        "Exploratório. Mesmo recorte `apple_step_pilot_12` (fora do held-out 90 e do residency-60).",
        "Condições: NoThink, NoThink+runtime, ActionAware. Sem gold, sem Chat, freeze v3 intocado.",
        "",
        "## Resultados",
        "",
        "| Política | Sucesso | Latência (s) | Tokens | Rodadas | Extra calls | Recuperações |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for pol in POLICIES:
        r = rows.get(pol) or {}
        if not r.get("n"):
            lines.append(f"| {pol} | — | — | — | — | — | — |")
            continue
        lines.append(
            f"| {pol} | {r['success']:.3f} ({r['n_success']}/{r['n']}) | {r['mean_lat_ms']/1000:.1f} | "
            f"{r['mean_tokens']:.0f} | {r['mean_rounds']:.2f} | {r['extra_calls']} | {r.get('recoveries', 0)} |"
        )
    lines += [
        "",
        f"ActionAware supera NoThink+runtime? **{verdict}** "
        f"(action_aware {aw_s:.3f} vs nothink_runtime {rt_s:.3f}; nothink {nt.get('success', 0):.3f}).",
        f"Recuperações que converteram falha do runtime em acerto: **{rec_ok}**.",
        f"Custo médio das recuperações (ActionAware − runtime, só com recover): "
        f"{(sum(costs)/len(costs)/1000 if costs else 0):.1f} s "
        f"(n={len(costs)}).",
        "",
        "Chamadas inválidas e duplicadas entram na nota; acerto parcial não conta.",
        "Artefatos: `selection.json`, `summary.json`. Preset `action-aware-pilot`.",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines) + "\n")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: run_action.py <action-aware-session.json>")
    payload, rows = load(sys.argv[1])
    policies = {p: pack(rows, p) for p in POLICIES}
    summary = {
        "session_id": payload.get("sessionID"),
        "n_jobs": len(rows),
        "policies": policies,
        "tasks": per_task(rows),
        "exploratory": True,
        "heldout90_untouched": True,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
    write_report(summary, OUT)
    print("action-aware", {k: round(v.get("success", 0), 3) for k, v in policies.items()}, "→", OUT)


if __name__ == "__main__":
    main()
