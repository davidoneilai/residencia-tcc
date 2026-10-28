#!/usr/bin/env python3
"""AdaptiveStep vs Direct / NoThink / Budget64. Recorte apple_step_pilot_12."""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "reports" / "adaptive-inference" / "step-pilot"
POLICIES = ["direct", "nothink", "budget_64", "adaptive_step"]


def succeeded(r):
    if r.get("taskSuccess") is not None:
        return bool(r["taskSuccess"])
    return bool(r.get("success"))


def load(path):
    s = json.loads(Path(path).read_text())
    return s, s.get("results") or []


def pack(rows, pol):
    rs = [r for r in rows if r.get("strategy") == pol]
    n = len(rs)
    if not n:
        return {"n": 0}
    fail = [r for r in rs if not succeeded(r)]
    seq = [r for r in rs if (r.get("taskKind") == "sequential") or "seq" in (r.get("taskId") or r.get("experiment") or "")]
    by_kind = {}
    for k in ("single_tool", "multi_tool", "sequential"):
        sub = [r for r in rs if r.get("taskKind") == k]
        by_kind[k] = {
            "n": len(sub),
            "success": (sum(succeeded(r) for r in sub) / len(sub)) if sub else None,
        }
    lats = [(r.get("totalLatencyMs") or r.get("totalMs") or 0) for r in rs]
    toks = [r.get("outputTokens") or 0 for r in rs]
    return {
        "n": n,
        "success": sum(succeeded(r) for r in rs) / n,
        "n_success": sum(succeeded(r) for r in rs),
        "mean_lat_ms": sum(lats) / n,
        "mean_tokens": sum(toks) / n,
        "length": sum(1 for r in rs if r.get("stopReason") == "length"),
        "no_tool": sum(1 for r in fail if r.get("failureKind") == "no_tool"),
        "execution": sum(1 for r in fail if r.get("failureKind") == "execution"),
        "grade": sum(1 for r in fail if r.get("failureKind") == "grade"),
        "seq_n": len(seq),
        "seq_success": (sum(succeeded(r) for r in seq) / len(seq)) if seq else None,
        "overhead_ms": sum(r.get("routerDecisionMs") or 0 for r in rs) / n,
        "by_kind": by_kind,
        "modes": step_modes(rs),
    }


def step_modes(rs):
    counts = defaultdict(int)
    for r in rs:
        for ev in r.get("controllerTrace") or []:
            if ":step:" in ev:
                parts = ev.split(":")
                if len(parts) >= 3:
                    counts[parts[2]] += 1
    return dict(counts)


def write_report(summary, out: Path):
    rows = summary["policies"]
    best_fixed = max(
        (rows.get(p) or {}).get("success") or -1 for p in ("direct", "nothink", "budget_64")
    )
    adapt = (rows.get("adaptive_step") or {}).get("success") or 0
    best_name = "nenhuma"
    for p in ("direct", "nothink", "budget_64"):
        if abs(((rows.get(p) or {}).get("success") or -1) - best_fixed) < 1e-12:
            best_name = p
            break
    benefit = "sim" if adapt > best_fixed + 1e-9 else (
        "empate" if abs(adapt - best_fixed) < 1e-9 else "não"
    )
    lines = [
        "# AdaptiveStep — piloto Think Fast and Slow (sem treino)",
        "",
        "Exploratório. 12 tarefas inéditas (`apple_step_pilot_12`), fora do held-out 90 e do residency-60.",
        "Qwen3-1.7B-4bit, iPhone, Release, greedy, prefix KV, simulado, 1 rep.",
        "",
        "## Limitações do backend (verificadas no código)",
        "",
        "- `enable_thinking` é por chamada em `generate`; AdaptiveStep pode ligar/desligar thinking entre rodadas.",
        "- O prefixo KV é chaveado por `thinking` (`qwen|<bool>|<catalog>`). Alternar reconstrói o prefixo estático uma vez por modo; o sufixo continua em cache.",
        "- `budget_64` e o modo slow do AdaptiveStep usam `think()` (s1): um passe de raciocínio e outro de resposta. Isso aparece em `repeatedPrefillMs`.",
        "- Erro de ferramenta que lança aborta o loop antes da próxima decisão (mesma limitação do P3).",
        "",
        "## Resultados",
        "",
        "| Política | Sucesso | Latência (s) | Tokens | length | no_tool | seq | overhead (ms) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for pol in POLICIES:
        r = rows.get(pol) or {}
        if not r.get("n"):
            lines.append(f"| {pol} | — | — | — | — | — | — | — |")
            continue
        seq = r.get("seq_success")
        seq_s = f"{seq:.3f}" if seq is not None else "—"
        lines.append(
            f"| {pol} | {r['success']:.3f} ({r['n_success']}/{r['n']}) | {r['mean_lat_ms']/1000:.1f} | "
            f"{r['mean_tokens']:.0f} | {r['length']} | {r['no_tool']} | {seq_s} | {r['overhead_ms']:.2f} |"
        )
    lines += [
        "",
        f"Melhor fixa por sucesso: **{best_name}** ({best_fixed:.3f}).",
        f"AdaptiveStep trouxe benefício real sobre a melhor fixa? **{benefit}** "
        f"(adaptive_step {adapt:.3f}).",
        "",
        "Artefatos: `selection.json`, `summary.json`. Preset `adaptive-step-pilot`. Freeze v3 intocado.",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines) + "\n")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: run_step.py <step-pilot-session.json>")
    payload, rows = load(sys.argv[1])
    policies = {p: pack(rows, p) for p in POLICIES}
    summary = {
        "session_id": payload.get("sessionID"),
        "n_jobs": len(rows),
        "policies": policies,
        "exploratory": True,
        "heldout90_untouched": True,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
    write_report(summary, OUT)
    print("step-pilot", {k: round(v.get("success", 0), 3) for k, v in policies.items()}, "→", OUT)


if __name__ == "__main__":
    main()
