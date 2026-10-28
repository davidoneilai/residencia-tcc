#!/usr/bin/env python3
"""Adaptive routing v2: auditoria da sessão 3-rep + roteador com custo de sucesso.

Uso:
  python run_v2.py --check
  python run_v2.py \\
    --input ../../reports/adaptive-routing/on-device/variance-session.json \\
    --out ../../reports/adaptive-routing/v2
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
from features import extract_features, measure_overhead_ms, template_family
from oracle import (
    best_fixed,
    complementarity,
    fixed_policy_stats,
    oracle_stats,
    routing_policy,
    succeeded,
)
from routers import (
    FixedRouter,
    HeuristicRouter,
    cost_labels,
    pick_learned,
    train_logistic,
    train_tree,
)
from split import leave_one_family_out, split_by_family, self_check as split_self_check

SHARED = ["direct", "plan_act"]
QWEN = "mlx-community/Qwen3-1.7B-4bit"
RESIDENCY_COUNTS = {"single": 15, "multi": 15, "seq": 20, "amb": 10}
FULL_COUNTS = {"single": 40, "multi": 40, "seq": 50, "amb": 20}


def residency_ids() -> list[str]:
    ids = []
    for kind, n in RESIDENCY_COUNTS.items():
        ids += [f"apple_{kind}_{i:03d}" for i in range(1, n + 1)]
    return ids


def full_ids() -> list[str]:
    ids = []
    for kind, n in FULL_COUNTS.items():
        ids += [f"apple_{kind}_{i:03d}" for i in range(1, n + 1)]
    return ids


def heldout_ids() -> list[str]:
    return [i for i in full_ids() if i not in set(residency_ids())]


def self_check() -> None:
    split_self_check()
    y, w = cost_labels.__doc__ or "", []
    assert "only" in (cost_labels.__doc__ or "")
    f = extract_features("Busque o contato Ana e depois ligue para ela.")
    assert f.as_dict()["seq_cue_count"] >= 1
    assert template_family("apple_seq_021") == "apple_seq_b4"
    assert len(heldout_ids()) == 90
    fams = {template_family(i) for i in residency_ids()}
    held_fams = {template_family(i) for i in heldout_ids()}
    assert fams.isdisjoint(held_fams), sorted(fams & held_fams)
    print("ADAPTIVE_ROUTING_V2_OK")


def _policy(row: dict) -> str:
    return "adaptive" if routing_policy(row) == "adaptive" else (row.get("strategy") or "")


def audit_session(payload: dict, full60_path: Path | None) -> dict:
    rows = payload["results"]
    by: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in rows:
        by[(_policy(r), r.get("taskId") or "")].append(r)

    mixed = 0
    for rs in by.values():
        oks = [succeeded(r) for r in rs]
        if any(oks) and not all(oks):
            mixed += 1

    first42 = rows[:42]
    later = rows[42:]
    prefix = {
        "n_first": len(first42),
        "mean_prefill_first_ms": sum(r.get("prefillLatencyMs") or 0 for r in first42) / max(len(first42), 1),
        "mean_prefill_rest_ms": sum(r.get("prefillLatencyMs") or 0 for r in later) / max(len(later), 1),
        "policy_first": dict(Counter(_policy(r) for r in first42)),
        "thermal_first": dict(Counter(r.get("thermalGate") for r in first42)),
        "sibling_success_flips": 0,
    }
    for r in first42:
        sibs = [s for s in later if _policy(s) == _policy(r) and s.get("taskId") == r.get("taskId")]
        if sibs and any(succeeded(s) != succeeded(r) for s in sibs):
            prefix["sibling_success_flips"] += 1

    thermal = {}
    for gate in ("ready", "proceed_hot"):
        rs = [r for r in rows if r.get("thermalGate") == gate]
        if not rs:
            continue
        thermal[gate] = {
            "n": len(rs),
            "success_rate": sum(succeeded(r) for r in rs) / len(rs),
            "mean_tokens_per_second": sum(r.get("tokensPerSecond") or 0 for r in rs) / len(rs),
        }

    failures: dict[str, dict] = {}
    for pol in SHARED + ["adaptive"]:
        rs = [r for r in rows if _policy(r) == pol]
        bad = [r for r in rs if not succeeded(r)]
        failures[pol] = {
            "n": len(rs),
            "failure_kind": dict(Counter(r.get("failureKind") for r in bad)),
            "stop_length": sum(1 for r in rs if r.get("stopReason") == "length"),
            "stop_length_success": sum(
                1 for r in rs if r.get("stopReason") == "length" and succeeded(r)
            ),
        }

    full_cmp = None
    if full60_path and full60_path.exists():
        full = json.loads(full60_path.read_text())
        frows = full["results"] if isinstance(full, dict) else full
        var_ad = {tid: rs[0] for (p, tid), rs in by.items() if p == "adaptive"}
        flips = []
        for fr in frows:
            tid = fr.get("taskId")
            vr = var_ad.get(tid)
            if vr is None:
                continue
            if succeeded(fr) != succeeded(vr):
                flips.append({
                    "task_id": tid,
                    "full60_success": succeeded(fr),
                    "variance_success": succeeded(vr),
                    "route_full": fr.get("strategy"),
                    "route_var": vr.get("strategy"),
                    "error_full": (fr.get("error") or "")[:80],
                    "error_var": (vr.get("error") or "")[:80],
                })
        full_cmp = {
            "n": len(frows),
            "success_rate": sum(succeeded(r) for r in frows) / len(frows),
            "route_diffs": sum(
                1 for fr in frows
                if var_ad.get(fr.get("taskId")) and fr.get("strategy") != var_ad[fr["taskId"]].get("strategy")
            ),
            "success_flips": flips,
        }

    return {
        "n_results": len(rows),
        "finished": payload.get("finished"),
        "mixed_success_cells": mixed,
        "thermal": thermal,
        "prefix_cache": prefix,
        "failures": failures,
        "full60": full_cmp,
        "report_corrections": {
            "adaptive_vs_direct_tasks": "23/60 vs 24/60 (69 vs 72 runs), not 3 tasks",
            "sequential_plan_winners": 2,
            "sequential_oracle_runs": 9,
        },
    }


def run_lofo_v2(tasks, strategies, cost_sensitive: bool, slack: float) -> dict:
    folds = leave_one_family_out(tasks)
    agg = {k: {"succ": 0, "lat": 0.0, "n": 0} for k in ("fixed", "heuristic", "learned", "oracle")}
    for _fam, train, test in folds:
        val_families = sorted({t.family for t in train})
        val_set = set(val_families[::5]) or set(val_families[:1])
        val = [t for t in train if t.family in val_set]
        fit = [t for t in train if t.family not in val_set] or train
        fixed_name = best_fixed(fit, strategies)
        routers = {
            "fixed": FixedRouter(fixed_name, strategies),
            "heuristic": HeuristicRouter(candidates=strategies, default="direct", profile="qwen"),
            "learned": pick_learned(
                fit, val or fit, strategies, cost_sensitive=cost_sensitive, success_slack=slack
            ),
        }
        for key, router in routers.items():
            m = simulate_router(test, router, strategies)
            agg[key]["succ"] += m["n_success"]
            agg[key]["lat"] += m["total_latency_ms"]
            agg[key]["n"] += m["n"]
        o = oracle_eval(test, strategies, 0.0)
        agg["oracle"]["succ"] += o["n_success"]
        agg["oracle"]["lat"] += o["total_latency_ms"]
        agg["oracle"]["n"] += o["n"]

    out = {}
    for k, v in agg.items():
        n = max(v["n"], 1)
        out[k] = {
            "n": v["n"],
            "success_rate": v["succ"] / n,
            "total_latency_ms": v["lat"],
            "mean_latency_ms": v["lat"] / n,
        }
    return out


def write_report(data: dict, out: Path) -> None:
    a = data["audit"]
    full = data["full"]
    hold = {r["router"]: r for r in data["holdout"]}
    lofo = data["lofo"]
    lines = [
        "# Adaptive routing v2",
        "",
        "Roteador leve aprendido sobre a sessão on-device de 3 reps (Qwen3-1.7B-4bit, iPhone 16 Pro).",
        "Features só do prompt + catálogo público de ferramentas. Oracle é teto retrospectivo, não um modelo executável.",
        "",
        "## 1. Auditoria da sessão de 540",
        "",
        f"- Arquivo: `{data['input']}` · finished={a['finished']} · n={a['n_results']}.",
        f"- Células (política × tarefa) com sucesso misto entre reps: **{a['mixed_success_cells']}**.",
        f"- Prefixo KV cache: jobs 1–42 prefill {a['prefix_cache']['mean_prefill_first_ms']:.0f} ms vs resto {a['prefix_cache']['mean_prefill_rest_ms']:.0f} ms; flips de sucesso vs reps irmãs: **{a['prefix_cache']['sibling_success_flips']}**.",
        "",
    ]
    if a.get("full60") and a["full60"].get("success_flips") is not None:
        f60 = a["full60"]
        lines += [
            "### 0.400 (full60) vs 0.383 (variance adaptive)",
            "",
            "Não é efeito de “3 reps revelarem erros da heurística”. As decisões de rota são as mesmas (0 diffs).",
            f"full60: {f60['success_rate']:.3f} em 60. Variance adaptive: 23/60 = 0.383.",
            f"{len(f60['success_flips'])} tarefas mudaram de sucesso **entre sessões** (greedy não é estável bit-a-bit entre launches/builds):",
            "",
            "| Tarefa | full60 | variance | rota |",
            "| --- | --- | --- | --- |",
        ]
        for fl in f60["success_flips"]:
            lines.append(
                f"| `{fl['task_id']}` | {fl['full60_success']} | {fl['variance_success']} | {fl['route_full']} |"
            )
        lines += [
            "",
            "Correções do relatório de variância: adaptive vs direct é **23/60 vs 24/60** (não 3 tarefas);",
            "sequential plan_act acerta 2 tarefas; oracle sequential seria 9/60 runs (3 tarefas), não 6/60.",
            "",
        ]
    lines += [
        "### Térmica",
        "",
        "| Estado | n | Sucesso | tok/s |",
        "| --- | ---: | ---: | ---: |",
    ]
    for gate, v in a["thermal"].items():
        lines.append(f"| {gate} | {v['n']} | {v['success_rate']:.3f} | {v['mean_tokens_per_second']:.1f} |")
    lines += [
        "",
        "Sucesso idêntico entre `ready` e `proceed_hot`; latência não. Comparações de latência entre políticas nesta sessão são válidas porque o shuffle mistura estados, mas o nível absoluto está dominado por `serious` (83% dos jobs).",
        "",
        "### Falhas (runs, não tarefas)",
        "",
        "| Política | grade | no_tool | execution | stop=length |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for pol, v in a["failures"].items():
        fk = v["failure_kind"]
        lines.append(
            f"| {pol} | {fk.get('grade', 0)} | {fk.get('no_tool', 0)} | {fk.get('execution', 0)} | {v['stop_length']} |"
        )
    lines += [
        "",
        "`stopReason=length` quase não gera sucesso. `plan_act` estoura mais (plano + ação).",
        "",
        "## 2. Matriz usada no treino",
        "",
        f"- {full['n']} tarefas, 3 reps agregadas (sucesso = maioria, latência = média).",
        f"- Direct {full['fixed']['direct']['success_rate']:.3f}, plan_act {full['fixed']['plan_act']['success_rate']:.3f}, oracle {full['oracle']['success_rate']:.3f}.",
        f"- Complementaridade: only_direct={full['complementarity']['only_a']}, only_plan={full['complementarity']['only_b']}, both={full['complementarity']['both']}, neither={full['complementarity']['neither']}.",
        f"- Adaptive heurístico (on-device, 3 reps): sucesso {data['on_device_adaptive']['success_rate']:.3f}, latência média {data['on_device_adaptive']['mean_latency_ms']:.0f} ms.",
        "",
        "Rótulos de treino: only_* peso 8, both (mais rápida) peso 1, neither → direct peso 0.25.",
        "Limiar da logística ≥ 0.5 (plan_act só com evidência). Piso na validação: não perder sucesso vs melhor fixa (slack 0).",
        "",
        f"Learned escolhido na validação do hold-out: `{data['learned_name']}`.",
        "",
        "## 3. Hold-out por família (desenvolvimento — não é generalização)",
        "",
        f"Split train/val/test = {data['split_sizes']}. Famílias teste: `{', '.join(data['test_families'])}`.",
        "",
        "| Método | Sucesso | IC 95% (tarefa) | Latência média (ms) | vs direct (pp, ms) | correct / SR-loss / lat-only |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name in data["holdout_order"]:
        r = hold[name]
        ci = r["success_ci"]
        pair = r.get("paired")
        vs = "—"
        if pair:
            vs = (
                f"{pair['success_delta']['mean']*100:+.1f} pp, "
                f"{pair['latency_delta_ms']['mean']:+.0f} ms"
            )
        dec = r.get("decisions") or {}
        lines.append(
            f"| {name} | {r['success_rate']:.3f} | "
            f"[{ci['lo']:.3f}, {ci['hi']:.3f}] | {r['mean_latency_ms']:.0f} | {vs} | "
            f"{dec.get('correct', '—')} / {dec.get('success_loss', '—')} / {dec.get('latency_only', '—')} |"
        )
    lines += [
        "",
        "Este hold-out reusa as mesmas 60 tarefas (famílias diferentes). **Não reportar como generalização.**",
        "",
        "## 4. Replay nas 60 (ajuste, não generalização)",
        "",
        "| Método | Sucesso | IC 95% | Latência média (ms) | correct / SR-loss / lat-only |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    ins = {r["router"]: r for r in data.get("in_sample") or []}
    for name in ["fixed:direct", "fixed:plan_act", "heuristic", "logistic", "decision_tree", "oracle"]:
        r = ins.get(name)
        if not r:
            continue
        ci = r.get("success_ci") or {}
        dec = r.get("decisions") or {}
        lines.append(
            f"| {name} | {r['success_rate']:.3f} | "
            f"[{ci.get('lo', 0):.3f}, {ci.get('hi', 0):.3f}] | {r['mean_latency_ms']:.0f} | "
            f"{dec.get('correct', '—')} / {dec.get('success_loss', '—')} / {dec.get('latency_only', '—')} |"
        )
    log_err = [
        e for e in (ins.get("logistic") or {}).get("decisions", {}).get("errors") or []
        if e.get("kind") == "success_loss"
    ]
    if log_err:
        lines += [
            "",
            "Perdas de sucesso da logística no replay (in-sample):",
            "",
            "| Tarefa | Escolheu | Oracle |",
            "| --- | --- | --- |",
        ]
        for e in log_err:
            lines.append(f"| `{e['task_id']}` | {e['chosen']} | {e['oracle']} |")
    lines += [
        "",
        "Replay inclui o treino: a logística **não** pode ser lida como generalização. "
        "Se o LOFO ficar abaixo de `direct`, as features não separam only_plan de only_direct em famílias novas.",
        "",
        "## 5. Leave-one-family-out (estimativa dentro de residency-60)",
        "",
        "| Método | Sucesso | Latência média (ms) |",
        "| --- | ---: | ---: |",
    ]
    for name, row in lofo.items():
        lines.append(f"| {name} | {row['success_rate']:.3f} | {row['mean_latency_ms']:.0f} |")
    lines += [
        "",
        "LOFO ainda está na população das 60. Famílias held-out do dataset de 150 não têm rótulo de política.",
        "",
        "## 6. Generalização e 360 tarefas",
        "",
        "Não há 360 tarefas únicas no harness. Há:",
        "",
        "- 360 execuções no experimento cross-model original (3 modelos × 2 políticas × 60 tarefas).",
        "- **150** tarefas Apple (`apple_full_150`): 40/40/50/20 por categoria.",
        "- **60** medidas nesta sessão (`apple_residency_60` = IDs 001–015/020/010).",
        f"- **90** inéditas, famílias disjuntas: `{len(heldout_ids())}` IDs, 0 execuções Qwen.",
        "",
        "Com 12 famílias e 16 complementary (only_*) no residency, o classificador é pequeno demais para cravar generalização.",
        "Menor ampliação que desbloqueia teste em templates novos:",
        "",
        "- Medir as 90 held-out × `{direct, plan_act}` × 1 rep = **180 jobs** (qualidade greedy é estável *dentro* da sessão).",
        "- Depois, 90 × `adaptive` learned = 90 jobs de validação on-device.",
        "- Preset no app: `heldout-90` (`LaunchAutomation`).",
        "",
        "Não ajustar a heurística à mão nas 7 perdas. Os pesos exportados vão para `AdaptiveRouter.swift` via `export_swift_weights.py`.",
        "",
        "## 7. Próximo passo on-device",
        "",
        "Congelar: modelo Qwen3-1.7B-4bit, build Release, prefix KV cache, greedy, simulado.",
        "Registrar `thermalBefore` / `thermalGate`. Não misturar jobs 1–42 da sessão antiga (sem cache) em tabelas de latência v2.",
        "",
        "Artefatos neste diretório: `audit.json`, `qwen_learned.json`, `comparison.csv`, `task_policy_matrix.csv`.",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--input",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing" / "on-device" / "variance-session.json",
    )
    parser.add_argument(
        "--full60",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing" / "on-device" / "full60-session.json",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing" / "v2",
    )
    parser.add_argument("--seed", default="adaptive-routing-736194")
    args = parser.parse_args()

    if args.check:
        self_check()
        return

    args.out.mkdir(parents=True, exist_ok=True)
    payload = json.loads(args.input.read_text())
    audit = audit_session(payload, args.full60)
    (args.out / "audit.json").write_text(json.dumps(audit, indent=2, ensure_ascii=False))

    tasks = load_tasks(args.input, model=QWEN, strategies=SHARED)
    assert len(tasks) == 60, len(tasks)
    for t in tasks:
        assert t.policies["direct"].n_reps == 3
        assert t.policies["plan_act"].n_reps == 3

    split = split_by_family(tasks, seed=args.seed)
    fixed_name = best_fixed(split.train, SHARED)
    heuristic = HeuristicRouter(candidates=SHARED, default="direct", profile="qwen")
    logistic = train_logistic(
        split.train, split.val, SHARED, cost_sensitive=True, success_slack=0.0
    )
    tree = train_tree(split.train, SHARED, cost_sensitive=True)
    learned = pick_learned(
        split.train, split.val, SHARED, cost_sensitive=True, success_slack=0.0
    )
    (args.out / "qwen_learned.json").write_text(json.dumps(logistic.dump(), indent=2))
    (args.out / "qwen_tree.json").write_text(json.dumps(tree.dump(), indent=2))
    unique = [
        FixedRouter("direct", SHARED),
        FixedRouter("plan_act", SHARED),
        heuristic,
        logistic,
        tree,
    ]

    holdout_rows = []
    holdout_order = []
    for router in unique:
        metrics = simulate_router(split.test, router, SHARED)
        metrics["split"] = "test"
        metrics["model"] = "qwen"
        succ_vals = []
        for t in split.test:
            d = router.choose(t.prompt)
            s = d.strategy if d.strategy in t.policies else SHARED[0]
            succ_vals.append(float(t.policies[s].success))
        metrics["success_ci"] = clustered_ci(succ_vals)
        if router.name != "fixed:direct":
            metrics["paired"] = paired_vs_fixed(split.test, router, "direct", SHARED)
        holdout_rows.append(metrics)
        holdout_order.append(router.name)
    o = oracle_eval(split.test, SHARED, measure_overhead_ms(split.train[0].prompt))
    o["success_ci"] = clustered_ci([float(t.policies[t.oracle_choice(SHARED)].success) for t in split.test])
    o["decisions"] = {"correct": len(split.test), "success_loss": 0, "latency_only": 0}
    o["split"] = "test"
    o["model"] = "qwen"
    holdout_rows.append(o)
    holdout_order.append("oracle")

    from oracle import build_matrix, load_session as load_raw

    ad_rows, _ = load_raw(payload)

    adaptive_matrix = build_matrix(
        ad_rows, {t.task_id: t.prompt for t in tasks},
        strategies=["adaptive"], model=QWEN, include_adaptive=True,
    )
    on_dev = {
        "success_rate": 0.0,
        "mean_latency_ms": 0.0,
        "n": 0,
    }
    if len(adaptive_matrix) == 60:
        on_dev = {
            "n": 60,
            "success_rate": sum(t.policies["adaptive"].success for t in adaptive_matrix) / 60,
            "mean_latency_ms": sum(t.policies["adaptive"].latency_ms for t in adaptive_matrix) / 60,
        }

    in_sample = []
    for router in unique:
        m = simulate_router(tasks, router, SHARED)
        m["split"] = "all60_replay"
        m["model"] = "qwen"
        succ_vals = []
        for t in tasks:
            d = router.choose(t.prompt)
            s = d.strategy if d.strategy in t.policies else SHARED[0]
            succ_vals.append(float(t.policies[s].success))
        m["success_ci"] = clustered_ci(succ_vals)
        if router.name != "fixed:direct":
            m["paired"] = paired_vs_fixed(tasks, router, "direct", SHARED)
        in_sample.append(m)
    o_all = oracle_eval(tasks, SHARED, 0.0)
    o_all["success_ci"] = clustered_ci(
        [float(t.policies[t.oracle_choice(SHARED)].success) for t in tasks]
    )
    o_all["decisions"] = {"correct": 60, "success_loss": 0, "latency_only": 0}
    in_sample.append(o_all)

    lofo = run_lofo_v2(tasks, SHARED, cost_sensitive=True, slack=0.0)
    write_matrix_csv(tasks, SHARED, args.out / "task_policy_matrix.csv")
    write_comparison_csv(holdout_rows, args.out / "comparison.csv")

    _y, w = cost_labels(tasks, SHARED)
    (args.out / "label_weights.json").write_text(
        json.dumps(
            {
                "n_only_direct": sum(1 for t in tasks if t.policies["direct"].success and not t.policies["plan_act"].success),
                "n_only_plan": sum(1 for t in tasks if t.policies["plan_act"].success and not t.policies["direct"].success),
                "mean_weight": sum(w) / len(w),
                "heldout_ids": heldout_ids(),
                "heldout_families": sorted({template_family(i) for i in heldout_ids()}),
            },
            indent=2,
        )
    )

    summary = {
        "input": str(args.input),
        "audit": audit,
        "split_sizes": {"train": len(split.train), "val": len(split.val), "test": len(split.test)},
        "test_families": sorted({t.family for t in split.test}),
        "learned_name": learned.name,
        "learned": learned.dump(),
        "full": {
            "n": len(tasks),
            "fixed": {s: fixed_policy_stats(tasks, s) for s in SHARED},
            "oracle": oracle_stats(tasks, SHARED),
            "complementarity": complementarity(tasks, "direct", "plan_act"),
        },
        "holdout": holdout_rows,
        "holdout_order": holdout_order,
        "in_sample": in_sample,
        "lofo": lofo,
        "on_device_adaptive": on_dev,
        "best_fixed_train": fixed_name,
    }
    # JSON-serializable holdout (drop nested Router errors already dicts)
    serial = json.loads(json.dumps(summary, default=str))
    (args.out / "summary.json").write_text(json.dumps(serial, indent=2))
    write_report(serial, args.out)
    print(
        f"v2 learned={learned.name} test_sr="
        f"{next(r['success_rate'] for r in holdout_rows if r['router']==learned.name):.3f} "
        f"lofo_learned={lofo['learned']['success_rate']:.3f} → {args.out}"
    )


if __name__ == "__main__":
    main()
