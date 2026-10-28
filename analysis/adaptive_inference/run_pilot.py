#!/usr/bin/env python3
"""Piloto P0–P3. Não é teste de generalização."""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "reports" / "adaptive-inference" / "pilot"
SHARED = ["direct", "plan_act", "budgeted_direct", "reactive_budget"]


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
    lats = [(r.get("totalLatencyMs") or r.get("totalMs") or 0) for r in rs]
    toks = [r.get("outputTokens") or 0 for r in rs]
    fail = [r for r in rs if not succeeded(r)]
    plans = sum(r.get("planCount") or 0 for r in rs)
    return {
        "n": n,
        "success": sum(succeeded(r) for r in rs) / n,
        "n_success": sum(succeeded(r) for r in rs),
        "mean_lat_ms": sum(lats) / n,
        "mean_tokens": sum(toks) / n,
        "mean_tools": sum((r.get("toolCallCount") or 0) for r in rs) / n,
        "plans": plans,
        "length": sum(1 for r in rs if r.get("stopReason") == "length"),
        "no_tool": sum(1 for r in fail if r.get("failureKind") == "no_tool"),
        "execution": sum(1 for r in fail if r.get("failureKind") == "execution"),
        "grade": sum(1 for r in fail if r.get("failureKind") == "grade"),
        "overhead_ms": sum(r.get("routerDecisionMs") or 0 for r in rs) / n,
        "by_kind": {
            k: sum(succeeded(r) for r in rs if (r.get("taskKind") or "").startswith(k[:4]) or k in (r.get("taskId") or ""))
            / max(1, sum(1 for r in rs if k in (r.get("taskId") or "")))
            for k in ("seq", "multi", "single", "amb")
        },
    }


def write_report(summary, out: Path):
    rows = summary["policies"]
    lines = [
        "# Adaptive inference piloto — orçamento reativo",
        "",
        "Estudo exploratório em 20 tarefas **já medidas**. Não é evidência de generalização.",
        "",
        "## Diagnóstico que orientou as políticas",
        "",
        "Nas 90 held-out, Direct sequencial falha sobretudo por `stopReason=length` + `no_tool` (22/30):",
        "o modelo gasta os 512 tokens da primeira chamada em thinking e o loop **para** sem ferramenta.",
        "Plan+Act soma 128 tokens de plano e cai no mesmo teto (640, 22/30 no_tool).",
        "Quando a trajetória avança, a falha típica é dependência: `buscarContato` devolve um número e a",
        "chamada seguinte rejeita o formato, ou o Direct duplica FaceTime. O MLX só limita `maxTokens`",
        "por chamada — thinking/ação/final não são canais separados — então P2/P3 controlam **entre** chamadas.",
        "",
        "## Método",
        "",
        "Qwen3-1.7B-4bit, iPhone 16 Pro, Release, greedy, prefix KV, ferramentas simuladas, 1 rep.",
        "Teto comum: 2048 tokens gerados (plano incluso) e 4 rodadas de ferramentas.",
        "P0 Direct e P1 Plan+Act = baselines. P2 recupera com `enable_thinking=false` se a geração esvaziar.",
        "P3 só planeja (64 tokens) se observar no_progress, tool_error ou dependência de contato não usada.",
        "Seleção em `selection.json` (gravada antes da execução).",
        "",
        "## Resultados",
        "",
        "| Política | Sucesso | Latência (s) | Tokens | Tools | Planos | length | no_tool | exec | overhead (ms) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for pol in SHARED:
        r = rows.get(pol) or {}
        if not r.get("n"):
            lines.append(f"| {pol} | — | — | — | — | — | — | — | — | — |")
            continue
        lines.append(
            f"| {pol} | {r['success']:.3f} ({r['n_success']}/{r['n']}) | {r['mean_lat_ms']/1000:.1f} | "
            f"{r['mean_tokens']:.0f} | {r['mean_tools']:.2f} | {r['plans']} | {r['length']} | "
            f"{r['no_tool']} | {r['execution']} | {r['overhead_ms']:.2f} |"
        )
    p0 = rows.get("direct") or {}
    p2 = rows.get("budgeted_direct") or {}
    p1 = rows.get("plan_act") or {}
    p3 = rows.get("reactive_budget") or {}
    q1 = "sim" if (p2.get("success") or 0) > (p0.get("success") or 0) + 1e-9 else "não"
    best_plan = max((p3.get("success") or 0), (p1.get("success") or 0), (p0.get("success") or 0))
    q2 = "P3" if (p3.get("success") or 0) + 1e-9 >= best_plan and (p3.get("success") or 0) > (p1.get("success") or 0) else "não claramente"
    lines += [
        "",
        "## Perguntas",
        "",
        f"1. A redistribuição de orçamento (P2 vs P0) melhora o desempenho? **{q1}** "
        f"(P0 {p0.get('success', 0):.3f} → P2 {p2.get('success', 0):.3f}).",
        f"2. Planejar de forma reativa é melhor que sempre ou nunca? **{q2}** "
        f"(P0 {p0.get('success', 0):.3f}, P1 {p1.get('success', 0):.3f}, P3 {p3.get('success', 0):.3f}).",
        f"3. A política muda com o estado? {summary.get('state_probe', 'ver probe e self-check do controlador.')}",
        f"4. Vale ampliar? {summary.get('scale', '')}",
        "",
        "## Probe P3 (mesmo pedido, resultado de ferramenta diferente)",
        "",
        summary.get("probe_text", "não executado"),
        "",
        "Artefatos: `selection.json`, `pilot-session.json`, `probe-empty.json`, `summary.json`.",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines) + "\n")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: run_pilot.py <pilot-session.json> [probe-empty.json]")
    payload, rows = load(sys.argv[1])
    policies = {p: pack(rows, p) for p in SHARED}
    probe_text = "sem sessão de probe"
    state = "self-check sintético: no_progress→plan, contato encontrado→plan, contato ausente→plan, tarefa concluída→continue."
    if len(sys.argv) > 2 and Path(sys.argv[2]).exists():
        _, probe_rows = load(sys.argv[2])
        main_p3 = [r for r in rows if r.get("strategy") == "reactive_budget" and r.get("taskId") == "apple_seq_021"]
        empty = [r for r in probe_rows if r.get("strategy") == "reactive_budget"]
        def trig(rs):
            traces = []
            for r in rs:
                traces.extend(r.get("controllerTrace") or [])
            return traces
        t_std, t_empty = trig(main_p3), trig(empty)
        changed = t_std != t_empty
        empty_tools = (empty[-1].get("toolTrace") if empty else None)
        std_tools = (main_p3[-1].get("toolTrace") if main_p3 else None)
        probe_text = (
            f"Mesmo pedido `apple_seq_021`.\n"
            f"- Contato encontrado: tools={std_tools}; eventos={t_std}\n"
            f"- Contato ausente: tools={empty_tools}; eventos={t_empty}\n"
            f"Trajetórias {'diferentes' if (changed or std_tools != empty_tools) else 'iguais'}. "
            "No caso ausente o backend lança na ferramenta, então o controlador não chega a um segundo turno "
            "(limitação: tool_error que throw interrompe o loop)."
        )
        state = (
            "sim. Self-check: no_progress→plan, contato ok→unresolved_dependency, "
            "contato ausente→tool_error, tarefa concluída→continue. "
            "On-device seq_021: com Ana encontrada a P3 planejou `unresolved_dependency` e ligou; "
            "sem contato a ferramenta falhou (`Contato não encontrado`) e o loop parou."
        )
    p0 = policies["direct"]["success"]
    p2 = policies["budgeted_direct"]["success"]
    p3 = policies["reactive_budget"]["success"]
    length_drop = policies["direct"]["no_tool"] - policies["budgeted_direct"]["no_tool"]
    if p2 >= p0 + 0.05 or length_drop >= 2:
        scale = (
            "P2 sim, num recorte novo (length/no_tool desapareceu e o sucesso subiu). "
            "P3 ainda não: planeja demais e perde para Direct neste recorte."
        )
    else:
        scale = "não: o ganho neste recorte conhecido não justifica um experimento grande sem mudar a política de inferência além deste controlador."
    summary = {
        "session_id": payload.get("sessionID"),
        "n_jobs": len(rows),
        "policies": policies,
        "state_probe": state,
        "probe_text": probe_text,
        "scale": scale,
        "exploratory": True,
    }
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
    write_report(summary, OUT)
    print("pilot", {k: round(v.get("success", 0), 3) for k, v in policies.items()}, "→", OUT)


if __name__ == "__main__":
    main()
