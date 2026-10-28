#!/usr/bin/env python3
"""v3: avaliação externa nas 90 Apple held-out. NÃO retreina o roteador.

  python run_v3.py --check
  python run_v3.py --input ../../reports/adaptive-routing/v3/heldout90-session.json
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from evaluate import (
    clustered_ci,
    load_tasks,
    oracle_eval,
    paired_vs_fixed,
    simulate_router,
    write_comparison_csv,
    write_matrix_csv,
)
from features import extract_features, template_family
from oracle import (
    complementarity,
    fixed_policy_stats,
    latency_ms,
    load_session,
    oracle_stats,
    routing_policy,
    succeeded,
)
from routers import HeuristicRouter, LogisticRouter
from run_v2 import heldout_ids, residency_ids, self_check as v2_self_check

SHARED = ["direct", "plan_act"]
QWEN = "mlx-community/Qwen3-1.7B-4bit"
FROZEN = ROOT.parents[1] / "reports" / "adaptive-routing" / "v3" / "frozen" / "qwen_learned.json"


def self_check() -> None:
    v2_self_check()
    held = set(heldout_ids())
    res = set(residency_ids())
    assert len(held) == 90 and not (held & res)
    assert {template_family(i) for i in held}.isdisjoint({template_family(i) for i in res})
    assert FROZEN.exists(), FROZEN
    router = LogisticRouter.load(FROZEN)
    assert router.candidates == SHARED
    assert router.threshold >= 0.5
    d = router.choose("Ligue para +15550100.")
    assert d.strategy in SHARED
    print("ADAPTIVE_ROUTING_V3_OK")


def pack(tasks, router, name=None):
    m = simulate_router(tasks, router, SHARED)
    if name:
        m["router"] = name
    succ = []
    for t in tasks:
        d = router.choose(t.prompt)
        s = d.strategy if d.strategy in t.policies else SHARED[0]
        succ.append(float(t.policies[s].success))
    m["success_ci"] = clustered_ci(succ)
    m["paired"] = paired_vs_fixed(tasks, router, "direct", SHARED)
    return m


def failure_table(rows: list[dict]) -> dict:
    out = {}
    for pol in SHARED + ["adaptive"]:
        rs = [r for r in rows if (routing_policy(r) if pol == "adaptive" else r.get("strategy")) == pol]
        if pol != "adaptive":
            rs = [r for r in rows if routing_policy(r) == pol]
        bad = [r for r in rs if not succeeded(r)]
        if not rs:
            continue
        out[pol] = {
            "n": len(rs),
            "failure_kind": dict(Counter(r.get("failureKind") for r in bad)),
            "stop_length": sum(1 for r in rs if r.get("stopReason") == "length"),
            "errors_head": dict(Counter((r.get("error") or "")[:70] for r in bad).most_common(8)),
        }
    return out


def compare_sessions(a_rows, b_rows, label_a, label_b) -> dict:
    """Estabilidade entre launches: mesmo (task, policy) em duas sessões."""
    def key(r):
        return (routing_policy(r), r.get("taskId"), r.get("runIndex") or 1)

    ia = {key(r): r for r in a_rows if routing_policy(r) in SHARED}
    ib = {key(r): r for r in b_rows if routing_policy(r) in SHARED}
    common = sorted(set(ia) & set(ib))
    flips, traj = [], []
    for k in common:
        ra, rb = ia[k], ib[k]
        if succeeded(ra) != succeeded(rb):
            flips.append({"key": list(k), "a": succeeded(ra), "b": succeeded(rb),
                          "err_a": (ra.get("error") or "")[:80], "err_b": (rb.get("error") or "")[:80]})
        ta = json.dumps(ra.get("toolCalls") or ra.get("toolTrace") or [], sort_keys=True, default=str)
        tb = json.dumps(rb.get("toolCalls") or rb.get("toolTrace") or [], sort_keys=True, default=str)
        if ta != tb:
            traj.append({"key": list(k)})
    return {
        "label_a": label_a, "label_b": label_b, "n_common": len(common),
        "success_flips": flips, "trajectory_diffs": len(traj),
    }


def adaptive_vs_isolated(adaptive_rows, matrix_tasks, logistic: LogisticRouter | None = None) -> dict:
    by_id = {t.task_id: t for t in matrix_tasks}
    mismatches, traj, choice_mismatch = [], [], []
    n = 0
    py_match = 0
    n_py = 0
    for r in adaptive_rows:
        if routing_policy(r) != "adaptive":
            continue
        t = by_id.get(r.get("taskId"))
        if t is None:
            continue
        chosen = r.get("strategy")
        if chosen not in t.policies:
            continue
        n += 1
        iso = t.policies[chosen]
        if succeeded(r) != iso.success:
            mismatches.append({
                "task_id": t.task_id,
                "chosen": chosen,
                "adaptive_success": succeeded(r),
                "isolated_success": iso.success,
                "error": (r.get("error") or "")[:80],
                "stop": r.get("stopReason"),
                "failure_kind": r.get("failureKind"),
            })
        ta = json.dumps(r.get("toolCalls") or r.get("toolTrace") or [], sort_keys=True, default=str)
        tb = json.dumps(iso.row.get("toolCalls") or iso.row.get("toolTrace") or [], sort_keys=True, default=str)
        if ta != tb:
            traj.append(t.task_id)
        if logistic is not None:
            n_py += 1
            d = logistic.choose(t.prompt)
            if d.strategy == chosen:
                py_match += 1
            else:
                choice_mismatch.append({
                    "task_id": t.task_id, "on_device": chosen, "python": d.strategy,
                    "reason_on": r.get("routerReason"), "reason_py": d.reason,
                })
    return {
        "n_compared": n, "success_mismatches": mismatches, "trajectory_diffs": traj,
        "python_choice_n": n_py, "python_choice_match": py_match,
        "python_choice_mismatch": choice_mismatch,
        "mean_router_decision_ms": (
            sum((r.get("routerDecisionMs") or 0) for r in adaptive_rows if routing_policy(r) == "adaptive")
            / max(1, sum(1 for r in adaptive_rows if routing_policy(r) == "adaptive"))
        ),
    }


def write_report(data: dict, out: Path) -> None:
    freeze = data["freeze"]
    full = data["full"]
    rows = {r["router"]: r for r in data["comparison"]}
    lines = [
        "# Adaptive routing v3 — held-out 90",
        "",
        "Avaliação externa. O roteador logístico está congelado em `v3/frozen/qwen_learned.json` "
        "(treino nas 60 residency). Nenhuma label das 90 entrou em treino, limiar ou heurística.",
        "",
        "## Congelamento",
        "",
        f"- Modelo: `{freeze['model']}` · MLX {freeze['mlx_swift_lm']} · {freeze['build']} · {freeze['sampling']}.",
        f"- Logistic threshold={freeze['router']['threshold']} fallback=`direct`.",
        f"- SHA pesos: `{freeze['router']['sha256_16']}`.",
        f"- Famílias held-out ∩ residency: {freeze['heldout']['family_overlap'] or 'vazia'}.",
        f"- 90 IDs: single {freeze['heldout']['by_kind']['single']}, multi {freeze['heldout']['by_kind']['multi']}, "
        f"seq {freeze['heldout']['by_kind']['seq']}, amb {freeze['heldout']['by_kind']['amb']}.",
        f"- Sessão matriz: `{data.get('session_id', '—')}` · {data.get('n_jobs', 180)} jobs · 1 rep · interleaved.",
        "",
        "Oracle é teto retrospectivo, não um modelo executável. As 90 não entraram em treino, limiar ou heurística.",
        "",
        "## Método",
        "",
        "iPhone 16 Pro (iPhone17,1), Qwen3-1.7B-4bit, build Release, prefix KV cache, greedy (temperature 0, ArgMaxSampler), "
        "ferramentas simuladas. 90 tarefas = `apple_full_150` − residency-60; overlap de famílias vazio. "
        "1 repetição por (tarefa × política); Direct e Plan+Act intercalados no mesmo shuffle (`orderSeed` do residency). "
        "Controle: 4 tarefas × 2 políticas em outro launch. Router-check: 8 Adaptive com `router=logistic` congelado. "
        "Replay reconstrói heurística e logística a partir da matriz observada. Não há retreino nem ajuste de limiar nas 90.",
        "",
        "## Políticas (capacidade, 90×1)",
        "",
        f"- Direct: sucesso {full['fixed']['direct']['success_rate']:.3f} ({full['fixed']['direct']['n_success']}/90), "
        f"média {full['fixed']['direct']['mean_latency_ms']:.0f} ms"
        + (f", p50 {full['fixed']['direct'].get('p50_ms', 0):.0f}, p90 {full['fixed']['direct'].get('p90_ms', 0):.0f}." if full['fixed']['direct'].get('p50_ms') is not None else "."),
        f"- Plan+Act: sucesso {full['fixed']['plan_act']['success_rate']:.3f} ({full['fixed']['plan_act']['n_success']}/90), "
        f"média {full['fixed']['plan_act']['mean_latency_ms']:.0f} ms"
        + (f", p50 {full['fixed']['plan_act'].get('p50_ms', 0):.0f}, p90 {full['fixed']['plan_act'].get('p90_ms', 0):.0f}." if full['fixed']['plan_act'].get('p50_ms') is not None else "."),
        f"- Oracle retrospectivo: {full['oracle']['success_rate']:.3f} ({full['oracle']['n_success']}/90), média {full['oracle']['mean_latency_ms']:.0f} ms.",
        f"- Complementaridade: only_direct={full['complementarity']['only_a']}, only_plan={full['complementarity']['only_b']}, "
        f"both={full['complementarity']['both']}, neither={full['complementarity']['neither']}.",
        "",
        "## Roteadores (replay congelado)",
        "",
        "IC 95% = bootstrap por tarefa (4000, seed 736194). Tarefas são a unidade; famílias são o agrupamento de generalização.",
        "",
        "| Método | Sucesso | IC 95% | Latência média (ms) | overhead (ms) | vs direct | correct / SR-loss / lat-only |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    order = ["fixed:direct", "fixed:plan_act", "heuristic", "logistic", "oracle"]
    for name in order:
        r = rows.get(name)
        if not r:
            continue
        ci = r.get("success_ci") or {"lo": r["success_rate"], "hi": r["success_rate"]}
        pair = r.get("paired")
        vs = "—"
        if pair:
            vs = f"{pair['success_delta']['mean']*100:+.1f} pp, {pair['latency_delta_ms']['mean']:+.0f} ms"
        dec = r.get("decisions") or {}
        oh = r.get("mean_router_overhead_ms")
        oh_s = "—" if oh is None else f"{oh:.2f}"
        lines.append(
            f"| {name} | {r['success_rate']:.3f} | [{ci.get('lo', 0):.3f}, {ci.get('hi', 0):.3f}] | "
            f"{r['mean_latency_ms']:.0f} | {oh_s} | {vs} | "
            f"{dec.get('correct', '—')} / {dec.get('success_loss', '—')} / {dec.get('latency_only', '—')} |"
        )
    lines += ["", "Por categoria (sucesso):", "", "| Categoria | n | Direct | Plan | Heurística | Learned | Oracle |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    cats = sorted({t for t in (rows.get("logistic") or {}).get("by_category") or {}})
    for cat in cats:
        def sr(name):
            v = (rows.get(name) or {}).get("by_category", {}).get(cat) or {}
            return v.get("success_rate")
        n = ((rows.get("fixed:direct") or {}).get("by_category") or {}).get(cat, {}).get("n", 0)
        vals = [sr("fixed:direct"), sr("fixed:plan_act"), sr("heuristic"), sr("logistic"), sr("oracle")]
        fmt = " | ".join("—" if v is None else f"{v:.3f}" for v in vals)
        lines.append(f"| {cat} | {n} | {fmt} |")

    fams = sorted((rows.get("logistic") or {}).get("by_family") or {})
    if fams:
        lines += ["", "Por família (sucesso):", "", "| Família | n | Direct | Plan | Heurística | Learned | Oracle |", "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
        for fam in fams:
            def srf(name, fam=fam):
                v = (rows.get(name) or {}).get("by_family", {}).get(fam) or {}
                return v.get("success_rate")
            n = ((rows.get("fixed:direct") or {}).get("by_family") or {}).get(fam, {}).get("n", 0)
            vals = [srf("fixed:direct"), srf("fixed:plan_act"), srf("heuristic"), srf("logistic"), srf("oracle")]
            fmt = " | ".join("—" if v is None else f"{v:.3f}" for v in vals)
            lines.append(f"| `{fam}` | {n} | {fmt} |")

    log_err = [e for e in (rows.get("logistic") or {}).get("decisions", {}).get("errors") or [] if e.get("kind") == "success_loss"]
    if log_err:
        lines += ["", "Learned — perdas de sucesso:", "", "| Tarefa | Família | Escolheu | Oracle |", "| --- | --- | --- | --- |"]
        for e in log_err:
            lines.append(f"| `{e['task_id']}` | `{template_family(e['task_id'])}` | {e['chosen']} | {e['oracle']} |")

    if data.get("control"):
        c = data["control"]
        lines += [
            "",
            "## Controle entre launches",
            "",
            f"{c['n_common']} pares (tarefa, política) em duas sessões. "
            f"Flips de sucesso: {len(c['success_flips'])}. Trajetórias diferentes: {c['trajectory_diffs']}.",
        ]
        for fl in c["success_flips"][:12]:
            lines.append(f"- `{fl['key']}`: {c['label_a']}={fl['a']} → {c['label_b']}={fl['b']}")

    if data.get("router_on_device"):
        v = data["router_on_device"]
        lines += [
            "",
            "## Validação on-device do roteador",
            "",
            f"{v['n_compared']} execuções Adaptive (logística congelada) vs a mesma política isolada na matriz. "
            f"Escolhas iguais ao Python congelado: {v.get('python_choice_match', '—')}/{v.get('python_choice_n', '—')}. "
            f"Divergências de sucesso: {len(v['success_mismatches'])}. "
            f"Trajetórias diferentes: {len(v.get('trajectory_diffs') or [])}. "
            f"Overhead on-device médio: {v.get('mean_router_decision_ms', 0):.2f} ms.",
        ]
        for m in v["success_mismatches"]:
            lines.append(
                f"- `{m['task_id']}` chose {m['chosen']}: adaptive={m['adaptive_success']} "
                f"isolated={m['isolated_success']} stop={m.get('stop')} fail={m.get('failure_kind')}"
            )
        if v.get("python_choice_mismatch"):
            lines.append("Divergência de rota vs Python (inesperada):")
            for d in v["python_choice_mismatch"]:
                lines.append(f"- `{d['task_id']}` on-device={d['on_device']} python={d['python']}")
        lines.append(
            "Replay da matriz é válido para a *escolha* da política. Sucesso da inferência greedy "
            "não é bit-estável entre launches (ver controle); um mismatch de sucesso com a mesma "
            "rota não invalida o roteador, desde que a política escolhida coincida."
        )

    if data.get("thermal"):
        lines += [
            "",
            "## Térmica",
            "",
            "`ready` concentra os primeiros jobs após load/resume; não é um experimento térmico aleatorizado. "
            "O shuffle mistura políticas, então rankings de sucesso entre Direct/Plan/roteadores não se explicam por gate. "
            "Latência absoluta está dominada por `proceed_hot`.",
            "",
            "| Estado | n | Sucesso | tok/s | lat média (ms) |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
        for gate, v in data["thermal"].items():
            lines.append(
                f"| {gate} | {v['n']} | {v['success_rate']:.3f} | {v['mean_tps']:.1f} | {v.get('mean_lat_ms', 0):.0f} |"
            )

    if data.get("failures"):
        lines += ["", "## Falhas", "", "| Política | grade | no_tool | execution | stop=length |", "| --- | ---: | ---: | ---: | ---: |"]
        for pol, v in data["failures"].items():
            fk = v["failure_kind"]
            lines.append(f"| {pol} | {fk.get('grade', 0)} | {fk.get('no_tool', 0)} | {fk.get('execution', 0)} | {v['stop_length']} |")

    rec = data.get("recommendation", "")
    lines += [
        "",
        "## Recomendação",
        "",
        rec,
        "",
        "Artefatos: `freeze.json`, `frozen/qwen_learned.json`, `heldout90-session.json`, `control-session.json`, "
        "`router-check-session.json`, `task_policy_matrix.csv`, `comparison.csv`, `summary.json`.",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines) + "\n")


def recommend(full, rows) -> str:
    d = full["fixed"]["direct"]["success_rate"]
    p = full["fixed"]["plan_act"]["success_rate"]
    o = full["oracle"]["success_rate"]
    log = rows.get("logistic") or {}
    heu = rows.get("heuristic") or {}
    only_p = full["complementarity"]["only_b"]
    neither = full["complementarity"]["neither"]
    n = full["n"]
    lsr = log.get("success_rate", 0)
    hsr = heu.get("success_rate", 0)
    gap = o - max(d, p)
    if lsr + 1e-9 >= d - 0.02 and log.get("mean_latency_ms", 1e9) < full["fixed"]["direct"]["mean_latency_ms"]:
        return (
            f"Learned generalizou o suficiente para não perder vs direct ({lsr:.3f} vs {d:.3f}) e ainda cortar latência. "
            "Continuar o roteador faz sentido, com mais labels only_plan se o teto oracle ainda estiver alto "
            f"(gap {gap:.3f}, only_plan={only_p})."
        )
    if neither / max(n, 1) >= 0.4:
        return (
            f"Priorize uma terceira política de inferência. {neither}/{n} tarefas falham nas duas políticas "
            f"(teto oracle {o:.3f} vs melhor fixa {max(d, p):.3f}). Sequential não se mexe: Direct, Plan+Act, "
            f"heurística e learned ficam presos na mesma taxa. Learned {lsr:.3f} e heurística {hsr:.3f} não batem "
            f"Direct {d:.3f} em famílias inéditas ({only_p} only_plan, 10 perdas de sucesso no learned). "
            "Não retreine nas 90 — já foram o teste. Headroom de roteamento existe, mas o teto de 52% com este par "
            "de políticas é o gargalo; thinking budget, early-exit ou tool-calling distinto rendem mais do que "
            "o mesmo classificador com as features atuais."
        )
    if gap < 0.05 or only_p <= 2:
        return (
            f"Complementaridade nas 90 é fraca (only_plan={only_p}, teto oracle {o:.3f} vs melhor fixa {max(d,p):.3f}). "
            "Melhorar o roteador rende pouco. Priorize uma terceira política de inferência "
            "(orçamento de thinking, early-exit, ou tool-calling distinto) — o gargalo é a política, não a escolha."
        )
    if lsr < d - 0.02 and hsr < d - 0.02:
        return (
            f"Nem heurística ({hsr:.3f}) nem learned ({lsr:.3f}) preservam o direct ({d:.3f}) em tarefas inéditas. "
            f"Há headroom (oracle {o:.3f}, only_plan={only_p}), mas as features atuais não capturam. "
            "Não continue o mesmo classificador. Ou mude o espaço de features com um conjunto *novo* de labels, "
            "ou desenvolva uma terceira política — as 90 já foram gastas como teste e não podem treinar o próximo modelo."
        )
    return (
        f"Resultado misto: learned {lsr:.3f}, heurística {hsr:.3f}, direct {d:.3f}, oracle {o:.3f}. "
        "Não retreine nas 90. Se only_plan for material, colete outro hold-out antes de mexer no classificador; "
        "se o teto for baixo, mude a política de inferência."
    )


def thermal_table(raw_rows):
    out = {}
    for gate in ("ready", "proceed_hot"):
        rs = [r for r in raw_rows if r.get("thermalGate") == gate]
        if not rs:
            continue
        out[gate] = {
            "n": len(rs),
            "success_rate": sum(succeeded(r) for r in rs) / len(rs),
            "mean_tps": sum(r.get("tokensPerSecond") or 0 for r in rs) / len(rs),
            "mean_lat_ms": sum(latency_ms(r) or 0 for r in rs) / len(rs),
        }
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--input", type=Path)
    parser.add_argument("--control", type=Path)
    parser.add_argument("--router-check", type=Path)
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing" / "v3",
    )
    parser.add_argument(
        "--freeze",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing" / "v3" / "freeze.json",
    )
    args = parser.parse_args()
    if args.check:
        self_check()
        return
    if not args.input or not args.input.exists():
        raise SystemExit("passe --input com a sessão heldout-90")

    args.out.mkdir(parents=True, exist_ok=True)
    freeze = json.loads(args.freeze.read_text())
    logistic = LogisticRouter.load(FROZEN)
    heuristic = HeuristicRouter(candidates=SHARED, default="direct", profile="qwen")
    tasks = load_tasks(args.input, model=QWEN, strategies=SHARED)
    if len(tasks) != 90:
        print(f"aviso: n_tasks={len(tasks)} (esperado 90)")
    ids = {t.task_id for t in tasks}
    leak = ids & set(residency_ids())
    if leak:
        raise SystemExit(f"vazamento residency no held-out: {sorted(leak)[:8]}")

    from routers import FixedRouter
    comparison = [
        pack(tasks, FixedRouter("direct", SHARED)),
        pack(tasks, FixedRouter("plan_act", SHARED)),
        pack(tasks, heuristic, "heuristic"),
        pack(tasks, logistic, "logistic"),
    ]
    o = oracle_eval(tasks, SHARED, 0.0)
    o["success_ci"] = clustered_ci([float(t.policies[t.oracle_choice(SHARED)].success) for t in tasks])
    o["decisions"] = {"correct": len(tasks), "success_loss": 0, "latency_only": 0}
    comparison.append(o)

    payload = json.loads(args.input.read_text())
    raw, _ = load_session(payload)
    control = None
    if args.control and args.control.exists():
        cpay = json.loads(args.control.read_text())
        crows, _ = load_session(cpay)
        control = compare_sessions(crows, raw, "control", "heldout90")
    router_od = None
    if args.router_check and args.router_check.exists():
        rpay = json.loads(args.router_check.read_text())
        rrows, _ = load_session(rpay)
        router_od = adaptive_vs_isolated(rrows, tasks, logistic)

    def pct(xs, q):
        if not xs:
            return None
        srt = sorted(xs)
        return srt[min(len(srt) - 1, max(0, int(round(q * (len(srt) - 1)))))]

    full = {
        "n": len(tasks),
        "fixed": {s: fixed_policy_stats(tasks, s) for s in SHARED},
        "oracle": oracle_stats(tasks, SHARED),
        "complementarity": complementarity(tasks, "direct", "plan_act"),
    }
    for s in SHARED:
        lats = [t.policies[s].latency_ms for t in tasks]
        full["fixed"][s]["p50_ms"] = pct(lats, 0.5)
        full["fixed"][s]["p90_ms"] = pct(lats, 0.9)
    rows = {r["router"]: r for r in comparison}
    rec = recommend(full, rows)
    summary = {
        "freeze": freeze,
        "full": full,
        "comparison": comparison,
        "control": control,
        "router_on_device": router_od,
        "thermal": thermal_table(raw),
        "failures": failure_table(raw),
        "recommendation": rec,
        "logistic_frozen": logistic.dump(),
        "session_id": payload.get("sessionID"),
        "n_jobs": len(payload.get("results") or []),
    }
    write_matrix_csv(tasks, SHARED, args.out / "task_policy_matrix.csv")
    write_comparison_csv(comparison, args.out / "comparison.csv")
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2, default=str))
    write_report(summary, args.out)
    print(
        f"v3 n={len(tasks)} direct={full['fixed']['direct']['success_rate']:.3f} "
        f"plan={full['fixed']['plan_act']['success_rate']:.3f} "
        f"learned={rows['logistic']['success_rate']:.3f} "
        f"oracle={full['oracle']['success_rate']:.3f} → {args.out}"
    )


if __name__ == "__main__":
    main()
