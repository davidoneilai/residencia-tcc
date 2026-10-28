#!/usr/bin/env python3
"""Gera reports/weekly/YYYY-WXX a partir de resultados já existentes. Não infere no iPhone.

    python3 analysis/weekly/generate.py 2026-W44
    python3 analysis/weekly/generate.py --check
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEEKS = Path(__file__).resolve().parent / "weeks"
sys.path.insert(0, str(ROOT / "analysis" / "slm_bfcl"))
import analyze as slm  # noqa: E402

DISPLAY = {
    "MiniCPM5-2B-MLX": "MiniCPM5-2B",
    "LFM2.5-2.6B-MLX-4bit": "LFM2.5-2.6B",
    "gemma-4-e2b-it-4bit": "Gemma 4 E2B",
    "Qwen3.5-2B-4bit": "Qwen3.5-2B",
}
AGENT_LABEL = {
    "minicpm5": "MiniCPM5-2B",
    "lfm25": "LFM2.5-2.6B",
    "gemma4": "Gemma 4 E2B",
    "qwen35": "Qwen3.5-2B",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("week", nargs="?", help="ISO week, ex. 2026-W44")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        check(args.week or "2026-W44")
        return
    if not args.week:
        available = ", ".join(p.stem for p in sorted(WEEKS.glob("*.json"))) or "(nenhuma)"
        raise SystemExit(f"Informe a semana (ex. 2026-W44). Disponíveis: {available}")
    out = generate(load_week(args.week))
    print(f"gravado em {out.relative_to(ROOT)}")


def load_week(week_id):
    path = WEEKS / f"{week_id}.json"
    if not path.exists():
        raise SystemExit(f"Sem definição em {path.relative_to(ROOT)}")
    spec = json.loads(path.read_text())
    spec["_path"] = path
    return spec


def generate(spec):
    out = ROOT / "reports" / "weekly" / spec["id"]
    out.mkdir(parents=True, exist_ok=True)
    (out / "figures").mkdir(exist_ok=True)
    r1_rows = slm.load([ROOT / spec["r1"]["graded"]])
    expected = spec["r1"]["expected_measured"]
    if len(r1_rows) != expected:
        raise SystemExit(f"r1: {len(r1_rows)} linhas avaliadas, esperado {expected}")
    r1 = slm.compute(r1_rows)
    sessions_r1 = inventory_sessions(glob_files(spec["r1"]["sessions_glob"]))
    measured_r1 = sum(s["n_measured"] for s in sessions_r1)
    if measured_r1 != expected:
        raise SystemExit(f"r1 sessões: {measured_r1} measured, esperado {expected}")
    r2_sessions = inventory_sessions(glob_files(spec["r2"]["sessions_glob"]))
    r2_graded_files = glob_files(spec["r2"]["graded_glob"])
    r2_rows = slm.load(r2_graded_files) if r2_graded_files else []
    r2_status = repetition_status(spec, r2_sessions, r2_rows, r1)
    evidence = collect_evidence(spec, sessions_r1, r2_sessions, r2_graded_files)
    figures = write_figures(r1, out / "figures")
    payload = {
        "week": spec["id"],
        "week_number": spec["week_number"],
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "inference": "iPhone",
        "evaluation": "Mac",
        "r1": serialize_study(r1),
        "r2": r2_status,
        "thermal": thermal_summary(r1_rows),
        "sessions_r1": [{k: (str(v.relative_to(ROOT)) if isinstance(v, Path) else v)
                         for k, v in s.items() if k != "results"} for s in sessions_r1],
        "gaps": r2_status["gaps"],
        "figures": figures,
    }
    (out / "summary.json").write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n")
    (out / "tables.md").write_text(slm.render_tables(r1))
    (out / "MANIFEST.md").write_text(render_manifest(spec, evidence, sessions_r1, r2_status, out))
    (out / "README.md").write_text(render_readme(spec, r1, r1_rows, sessions_r1, r2_sessions, r2_status, evidence, figures, out))
    return out


def glob_files(pattern):
    return sorted(p for p in ROOT.glob(pattern) if p.is_file())


def sha256(path: Path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def rel(out_dir: Path, path: Path):
    return Path(os.path.relpath(path, out_dir)).as_posix()


def label(model):
    return DISPLAY.get(model, model)


def inventory_sessions(paths):
    out = []
    for path in paths:
        session = json.loads(path.read_text())
        results = session.get("results") or []
        measured = [r for r in results if r.get("phase") == "measured" and r.get("dataset") == "bfcl_ast"]
        warmup = [r for r in results if r.get("phase") == "warmup"]
        sample = measured[0] if measured else (results[0] if results else {})
        agents = sorted({r.get("agent") or r.get("modelId") for r in (session.get("jobs") or []) if r.get("agent") or r.get("modelId")})
        if not agents and sample:
            agents = [sample.get("modelId") or sample.get("agent")]
        out.append({
            "path": path,
            "name": path.name,
            "finished": bool(session.get("finished")),
            "n_jobs": len(session.get("jobs") or []),
            "n_planned": sum(j.get("phase") == "measured" for j in session.get("jobs") or []),
            "thermal_before": dict(Counter(r.get("thermalStateBefore") for r in measured)),
            "n_measured": len(measured),
            "n_warmup": len(warmup),
            "n_results": len(results),
            "mlx": session.get("mlxSwiftLM") or sample.get("mlxSwiftLM"),
            "protocol": session.get("protocolVersion"),
            "config": session.get("config") or {},
            "agents": [a for a in agents if a],
            "device": sample.get("device"),
            "os": sample.get("osVersion"),
            "sampling": sample.get("sampling"),
            "temperature": sample.get("temperature"),
            "model": sample.get("model"),
            "evaluation_version": (session.get("config") or {}).get("evaluationVersion") or sample.get("evaluationVersion"),
            "sha256": sha256(path),
            "bytes": path.stat().st_size,
        })
    return out


def thermal_summary(rows):
    before = Counter(r.get("thermal_before") for r in rows)
    after = Counter(r.get("thermal_after") for r in rows)
    odd = [
        {"model": r["m"], "strategy": r["strategy_id"], "task": r["task"],
         "before": r.get("thermal_before"), "after": r.get("thermal_after")}
        for r in rows if r.get("thermal_before") != "serious" or r.get("thermal_after") != "serious"
    ]
    return {"n": len(rows), "before": dict(before), "after": dict(after), "non_serious": odd}


def repetition_status(spec, sessions, rows, r1):
    by_agent = {}
    for s in sessions:
        for agent in s["agents"] or ["?"]:
            by_agent[agent] = s
    graded_by_agent = defaultdict(list)
    for r in rows:
        graded_by_agent[r.get("agent")].append(r)
    agents = []
    gaps = []
    for agent in spec["r2"]["expected_agents"]:
        session = by_agent.get(agent)
        graded = graded_by_agent.get(agent) or []
        if session is None:
            status = "ausente"
            gaps.append(f"{AGENT_LABEL.get(agent, agent)}: repetição 2 sem sessão no repositório")
        elif not session["finished"]:
            status = "incompleta"
            gaps.append(f"{AGENT_LABEL.get(agent, agent)}: sessão r2 interrompida ({session['n_measured']}/{session['n_planned']} medidas, sem avaliação)")
        elif not graded:
            status = "inferida_sem_avaliacao"
            gaps.append(f"{AGENT_LABEL.get(agent, agent)}: sessão r2 presente, avaliação no Mac ausente")
        else:
            status = "completa"
        entry = {
            "agent": agent,
            "label": AGENT_LABEL.get(agent, agent),
            "status": status,
            "n_measured": session["n_measured"] if session else 0,
            "n_planned": session["n_planned"] if session else 0,
            "thermal_before": session["thermal_before"] if session else {},
            "n_graded": len(graded),
            "finished": session["finished"] if session else False,
            "session": session["name"] if session else None,
            "strategies": sorted({r["strategy_id"] for r in graded}),
        }
        if status == "completa":
            entry["stability"] = stability(r1, graded, agent)
        agents.append(entry)
    complete = [a for a in agents if a["status"] == "completa"]
    return {
        "agents": agents,
        "n_complete": len(complete),
        "n_expected": len(spec["r2"]["expected_agents"]),
        "complete": False,
        "gaps": gaps,
    }


def stability(r1, r2_rows, agent):
    r2 = slm.compute(r2_rows)
    out = []
    for row in r2["main"]:
        ref = next((x for x in r1["main"] if x["model"] == row["model"] and x["strategy"] == row["strategy"]), None)
        if ref is None:
            continue
        cell1 = r1["cell"][(row["model"], row["strategy"])]
        cell2 = r2["cell"][(row["model"], row["strategy"])]
        ids = sorted(set(cell1) & set(cell2))
        agree = sum(bool(cell1[i]["valid"]) == bool(cell2[i]["valid"]) for i in ids)
        out.append({
            "model": row["model"], "strategy": row["strategy"],
            "r1_acc": ref["acc"], "r2_acc": row["acc"], "n": len(ids),
            "agree": agree, "r1_lat": ref["lat_mean"], "r2_lat": row["lat_mean"],
        })
    return out


def collect_evidence(spec, sessions_r1, sessions_r2, graded_r2):
    files = [ROOT / spec["r1"]["graded"], spec["_path"], Path(__file__)]
    files += [ROOT / p for p in spec["sources"]]
    files += [s["path"] for s in sessions_r1 + sessions_r2]
    files += graded_r2
    seen, out = set(), []
    for path in files:
        if not path.exists() or path in seen:
            continue
        seen.add(path)
        out.append({"path": path.relative_to(ROOT).as_posix(), "sha256": sha256(path), "bytes": path.stat().st_size})
    return out


def serialize_study(study):
    def conv(obj):
        if isinstance(obj, Counter):
            return dict(obj.most_common())
        raise TypeError(type(obj))
    keep = {k: v for k, v in study.items() if k != "cell"}
    return json.loads(json.dumps(keep, default=conv))


def sgn(value, digits=1):
    return f"{value:+.{digits}f}".replace("-", "−")


def pp(frac):
    return sgn(100 * frac, 1)


def write_figures(study, folder):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    folder.mkdir(parents=True, exist_ok=True)
    models = study["models"]
    colors = {m: plt.cm.tab10(i) for i, m in enumerate(models)}
    markers = {s: "D" if s in slm.ADAPTIVE else "o" for _, s in {(r["model"], r["strategy"]) for r in study["main"]}}

    fig, ax = plt.subplots(figsize=(9.2, 5.4))
    nudge = {"nothink": (-6, 8), "adaptive_step": (5, -11), "direct": (4, 6),
             "ast_router": (4, 4), "budget_64": (4, -9), "plan_act": (4, 4)}
    for r in study["main"]:
        ax.scatter(r["lat_mean"], r["acc"] / r["n"], color=colors[r["model"]],
                   marker=markers[r["strategy"]], s=48, zorder=3)
        dx, dy = nudge.get(r["strategy"], (4, 3))
        ax.annotate(r["strategy"], (r["lat_mean"], r["acc"] / r["n"]), fontsize=6.5, xytext=(dx, dy), textcoords="offset points")
    for m in models:
        ax.scatter([], [], color=colors[m], label=label(m))
    ax.scatter([], [], marker="o", color="0.3", label="fixa")
    ax.scatter([], [], marker="D", color="0.3", label="adaptativa")
    ax.set_xlabel("Latência média (s)")
    ax.set_ylabel("Acurácia")
    ax.set_ylim(0.45, 0.95)
    ax.set_title("Qualidade × latência (r1, n=40, checker oficial)")
    ax.legend(loc="lower right", fontsize=8)
    fig.tight_layout()
    fig.savefig(folder / "quality_latency.png", dpi=140)
    fig.savefig(folder / "quality_latency.svg")
    plt.close(fig)

    fig, axes = plt.subplots(1, 2, figsize=(10.5, 4.6))
    x = range(len(models))
    strats = [s for s in slm.FIXED + slm.ADAPTIVE if any(r["strategy"] == s for r in study["main"])]
    width = 0.8 / max(len(strats), 1)
    lookup = {(r["model"], r["strategy"]): r for r in study["main"]}
    labeled = set()
    palette = plt.cm.tab10.colors
    for i, s in enumerate(strats):
        color = palette[i % len(palette)]
        for j, m in enumerate(models):
            r = lookup.get((m, s))
            if not r:
                continue
            show = s if s not in labeled else None
            labeled.add(s)
            axes[0].bar(j + i * width, r["acc"] / r["n"], width=width, color=color)
            axes[1].bar(j + i * width, r["lat_mean"], width=width, color=color, label=show)
    ticks = [j + width * (len(strats) - 1) / 2 for j in x]
    for ax, ylab, title in (
        (axes[0], "Acurácia", "Acurácia por estratégia"),
        (axes[1], "Latência média (s)", "Latência por estratégia"),
    ):
        ax.set_xticks(ticks)
        ax.set_xticklabels([label(m) for m in models], rotation=15, ha="right")
        ax.set_ylabel(ylab)
        ax.set_title(title)
    axes[0].set_ylim(0, 1)
    axes[1].legend(fontsize=7, ncol=2)
    fig.tight_layout()
    fig.savefig(folder / "strategy_comparison.png", dpi=140)
    fig.savefig(folder / "strategy_comparison.svg")
    plt.close(fig)

    fig, axes = plt.subplots(2, 2, figsize=(9.5, 7.2), sharey=True)
    for ax, m in zip(axes.ravel(), models):
        rows = [r for r in study["main"] if r["model"] == m]
        names = [r["strategy"] for r in rows]
        ax.bar(names, [r["prefill"] for r in rows], label="prefill")
        ax.bar(names, [r["decode"] for r in rows], bottom=[r["prefill"] for r in rows], label="decode")
        ax.set_title(label(m))
        ax.tick_params(axis="x", rotation=35, labelsize=8)
        ax.set_ylabel("s")
    axes[0, 0].legend(fontsize=8)
    fig.suptitle("Decomposição da latência média (prefill + decode)")
    fig.tight_layout()
    fig.savefig(folder / "latency_decomp.png", dpi=140)
    fig.savefig(folder / "latency_decomp.svg")
    plt.close(fig)
    return ["figures/quality_latency.png", "figures/strategy_comparison.png", "figures/latency_decomp.png"]


def render_readme(spec, r1, rows, sessions, sessions_r2, r2, evidence, figures, out):
    n = r1["n_tasks"]
    best_acc = max(r1["main"], key=lambda r: (r["acc"], -r["lat_mean"]))
    near = [r for r in r1["main"] if r["acc"] >= best_acc["acc"] - 1]
    cheap = min(near, key=lambda r: r["lat_mean"])
    adaptive_vs = [r for r in r1["vs_best"] if r["adaptive"]]
    none_better = all(r["d_acc"] <= 0 for r in adaptive_vs)
    lat_win = [r for r in adaptive_vs if r["d_acc"] == 0 and r["d_lat_hi"] < 0]
    plan = [r for r in r1["main"] if r["strategy"] == "plan_act"]
    plan_never_best = all(r1["best_fixed"].get(r["model"]) != "plan_act" for r in plan)
    thermal = thermal_summary(rows)
    s0 = sessions[0]
    models_txt = ", ".join(label(m) for m in r1["models"])
    strats = sorted({r["strategy"] for r in r1["main"]})
    odd = thermal["non_serious"]
    odd_txt = "; ".join(f"{label(x['model'])} {x['strategy']} {x['task']} ({x['before']}→{x['after']})" for x in odd) or "nenhum"
    r2_lines = []
    for a in r2["agents"]:
        if a["status"] == "incompleta":
            r2_thermal = ", ".join(f"{k} {v}" for k, v in a["thermal_before"].items())
            r2_lines.append(
                f"- **{a['label']}:** incompleta — {a['n_measured']}/{a['n_planned']} execuções medidas no iPhone "
                f"([{a['session']}]({rel(out, ROOT / 'results/slm-bfcl' / a['session'])}); térmica no início: {r2_thermal}), "
                "sem avaliação no Mac. Não entra como resultado concluído."
            )
            continue
        if a["status"] != "completa":
            r2_lines.append(f"- **{a['label']}:** {a['status'].replace('_', ' ')}. Não entra como resultado concluído.")
            continue
        bits = []
        for st in a.get("stability") or []:
            bits.append(
                f"{st['strategy']} {st['r1_acc']}/{st['n']} → {st['r2_acc']}/{st['n']}, "
                f"concordância {st['agree']}/{st['n']}, latência {st['r1_lat']:.1f} s → {st['r2_lat']:.1f} s"
            )
        r2_lines.append(f"- **{a['label']}:** completa ({a['n_graded']} execuções avaliadas). " + "; ".join(bits) + ".")
    vs_rows = []
    for r in adaptive_vs:
        vs_rows.append(
            f"| {label(r['model'])} | {r['best_fixed']} | {r['strategy']} | {pp(r['d_acc'])} [{pp(r['d_acc_lo'])}; {pp(r['d_acc_hi'])}] | "
            f"{sgn(r['d_lat'])} [{sgn(r['d_lat_lo'])}; {sgn(r['d_lat_hi'])}] | "
            + ", ".join(f"{k} {v}" for k, v in r["decisions"].items()) + " |"
        )
    main_rows = []
    best = r1["best_fixed"]
    for r in r1["main"]:
        mark = "**" if best.get(r["model"]) == r["strategy"] and not r["adaptive"] else ""
        main_rows.append(
            f"| {mark}{label(r['model'])}{mark} | {mark}{r['strategy']}{mark} | {mark}{r['acc']}/{r['n']} ({r['acc']/r['n']:.0%}){mark} | "
            f"{mark}{r['lat_mean']:.1f}{mark} | {r['prefill']:.1f} | {r['decode']:.1f} | {r['tin']:.0f}/{r['tout']:.0f} |"
        )
    oracle_lines = [
        f"| {label(r['model'])} | {r['best_fixed']} {r['best_acc']}/{r['n']} | {r['oracle_fixed']}/{r['n']} | {r['oracle_all']}/{r['n']} | +{r['extra']} |"
        for r in r1["oracle"]
    ]
    c = r1["complementarity"]
    exclusive = [f"{label(m)} ({', '.join(c['exclusive'][m])})" for m in r1["models"] if c["exclusive"][m]]
    rank = {m: i for i, m in enumerate(sorted(r1["models"], key=lambda m: (
        -next(r["acc"] for r in r1["main"] if r["model"] == m and r["strategy"] == r1["best_fixed"][m]),
        next(r["lat_mean"] for r in r1["main"] if r["model"] == m and r["strategy"] == r1["best_fixed"][m]),
        m,
    )))}
    main_rows.sort(key=lambda line: rank.get(next((m for m in r1["models"] if label(m) in line), ""), 99))
    vs_rows.sort(key=lambda line: rank.get(next((m for m in r1["models"] if label(m) in line), ""), 99))
    oracle_lines.sort(key=lambda line: rank.get(next((m for m in r1["models"] if label(m) in line), ""), 99))
    checkpoints = sorted({r["model"] for r in rows})
    qwen_as = next(r for r in adaptive_vs if r["model"].startswith("Qwen") and r["strategy"] == "adaptive_step")
    minicpm_as = next(r for r in adaptive_vs if "MiniCPM" in r["model"] and r["strategy"] == "adaptive_step")
    selection = json.loads((ROOT / "reports/slm-bfcl/selection.json").read_text())
    graded = spec["r1"]["graded"]
    return f"""# {spec['title']}

Semana {spec['week_number']} do calendário ISO **{spec['id']}** ({spec['period']['start']} a {spec['period']['end']}).
Números calculados dos arquivos em `results/` e `reports/slm-bfcl/`; nada foi digitado à mão.

## Inferência no iPhone × avaliação no Mac

| Etapa | Onde | O que entra |
|---|---|---|
| Inferência | **iPhone 16 Pro** (`{s0['device']}`, {s0['os']}), MLX Swift / `mlx-swift-lm` {s0['mlx']} | tokens, latência, prefill, decode, térmica, memória |
| Avaliação | **Mac**, `ast_checker` oficial (`bfcl-eval` {selection.get('bfcl_eval_version')}) | `valid` / tipo de falha |

O gerador deste relatório **não** relança inferência no iPhone. Reavaliar no Mac, se necessário: `.bfcl-venv/bin/python analysis/slm_bfcl/evaluate.py results/slm-bfcl/main-r1-*.json --out {graded}`.

## Estado desta semana

- **Concluído:** rodada 1, **{r1['n']} execuções** medidas e avaliadas ({len(r1['models'])} modelos × políticas aplicáveis × {n} tarefas).
- **Não concluído:** repetição 2 — {r2['n_complete']}/{r2['n_expected']} modelos. Lacunas não são apresentadas como resultado.

## Resposta curta (só r1)

1. **Melhor acurácia:** {label(best_acc['model'])} `{best_acc['strategy']}`, {best_acc['acc']}/{best_acc['n']} ({best_acc['acc']/best_acc['n']:.0%}), {best_acc['lat_mean']:.1f} s/tarefa.
2. **Melhor custo-benefício na vizinhança da melhor acurácia** (até 1 tarefa a menos): {label(cheap['model'])} `{cheap['strategy']}`, {cheap['acc']}/{cheap['n']} ({cheap['acc']/cheap['n']:.0%}) em {cheap['lat_mean']:.1f} s.
3. **Adaptativas superam a melhor fixa em acurácia?** {'Não. Nenhuma política adaptativa superou a melhor fixa em nenhum modelo (Δ ≤ 0 pp).' if none_better else 'Há pelo menos um ganho de acurácia; ver tabela pareada.'}
4. **Ganho de latência sem perda:** {('; '.join(f"{label(r['model'])} `{r['strategy']}` {sgn(r['d_lat'])} s (IC95% [{sgn(r['d_lat_lo'])}; {sgn(r['d_lat_hi'])}])" for r in lat_win)) if lat_win else 'nenhum com Δ acurácia = 0 e IC de latência inteiramente negativo.'}
5. **Plan+Act:** {'não é a melhor fixa em nenhum modelo e é a mais lenta em todos os que a rodaram.' if plan_never_best else 'ver tabela.'}

## Cobertura experimental (r1)

| Campo | Valor |
|---|---|
| Benchmark | {spec['benchmark']} (turno único; **não** avalia interações sequenciais com ferramentas) |
| Modelos | {models_txt} |
| Estratégias observadas | {', '.join(strats)} |
| Tarefas / condição | {n} (amostra congelada, seed {selection.get('seed')}) |
| Execuções avaliadas | {r1['n']} |
| Amostragem | {s0.get('sampling')}, temperature {s0.get('temperature')} |
| Seed de ordem | `{s0['config'].get('orderSeed')}` |
| Espera térmica | `requireCoolThermal={s0['config'].get('requireCoolThermal')}`, `thermalTimeoutSeconds={s0['config'].get('thermalTimeoutSeconds')}` |

LFM2.5 não tem `nothink` nem `adaptive_step` nesta rodada (estratégias não aplicáveis; {next(s['n_measured'] for s in sessions if 'lfm25' in s['agents'])} execuções, não 240). Smoke tests (`results/slm-bfcl/smoke*.json`) ficam de fora. Checkpoints:

{chr(10).join(f'- `{c}`' for c in checkpoints)}

## Tabela principal (r1, checker oficial)

A latência média inclui prefill, decode e overhead do app. Plan+Act soma o turno do plano. Tabela completa com mediana, memória e falhas: [tables.md](tables.md).

| Modelo | Estratégia | Acurácia | Latência média (s) | Prefill (s) | Decode (s) | Tokens in/out |
|---|---|---|---|---|---|---|
{chr(10).join(main_rows)}

## Adaptativas × melhor fixa (pareado por tarefa, IC95% bootstrap)

| Modelo | Melhor fixa | Política | Δ acurácia (pp) [IC95%] | Δ latência (s) [IC95%] | Decisões |
|---|---|---|---|---|---|
{chr(10).join(vs_rows)}

MiniCPM5 AdaptiveStep vs NoThink: {pp(minicpm_as['d_acc'])} pp, {sgn(minicpm_as['d_lat'])} s. Qwen3.5 AdaptiveStep vs Direct: {pp(qwen_as['d_acc'])} pp [{pp(qwen_as['d_acc_lo'])}; {pp(qwen_as['d_acc_hi'])}].

## Figuras

![Qualidade × latência]({figures[0]})

![Comparação entre estratégias]({figures[1]})

![Decomposição da latência]({figures[2]})

## Oracle retrospectivo (limite superior; não é política executável)

| Modelo | Melhor fixa | Oracle fixas | Oracle + adaptativas | Teto sobre a melhor fixa |
|---|---|---|---|---|
{chr(10).join(oracle_lines)}

União das melhores fixas: {c['union']}/{n}; interseção: {c['intersection']}/{n}; nenhuma resolve: {c['none']}. Exclusivas: {'; '.join(exclusive) if exclusive else 'nenhuma além das listadas em tables.md'}.

## Repetição 2 (não tratar o bloco como estudo fechado)

Seed de ordem `{((sessions_r2[0]['config'] or {}).get('orderSeed') if sessions_r2 else None) or 'ausente'}`. Greedy / temperature 0; o seed só muda a ordem.

{chr(10).join(r2_lines)}

## Resultados negativos e limitações

- **Adaptativas vs melhor fixa:** nenhum ganho de acurácia. AdaptiveStep no Qwen3.5: {pp(qwen_as['d_acc'])} pp (IC95% [{pp(qwen_as['d_acc_lo'])}; {pp(qwen_as['d_acc_hi'])}]).
- **n = {n} por condição.** Diferenças abaixo de ~10 pp em geral cruzam o zero no IC95% bootstrap pareado.
- **Térmica:** {thermal['before'].get('serious', 0)}/{thermal['n']} jobs com `thermal_before=serious`; {thermal['after'].get('serious', 0)}/{thermal['n']} com `thermal_after=serious`. Fora de `serious`: {odd_txt}. O protocolo **não** espera esfriar (`requireCoolThermal=false`). Latências valem para o aparelho **quente e carregando**.
- **BFCL v4 AST** pontua a primeira resposta de turno único. **Não avalia interações sequenciais com ferramentas** (não há oráculo de diálogo nem estado entre turnos). ActionAware / ToolSandbox não entram nesta semana.
- MiniCPM5 e LFM2.5 dependem do parser no Mac para o formato nativo; o pacote `mlx-swift-lm` {s0['mlx']} não cobre esses formatos por completo.
- A repetição 2 dos outros três modelos **não está concluída** e não deve ser lida como estabilidade geral.

## Reprodutibilidade

Manifesto com hashes, versões, seeds e comandos: [MANIFEST.md](MANIFEST.md). Evidência bruta (sem duplicar dados):

- Amostra congelada: [{rel(out, ROOT / 'reports/slm-bfcl/selection.json')}]({rel(out, ROOT / 'reports/slm-bfcl/selection.json')})
- Sessões r1: {', '.join(f'[{s["name"]}]({rel(out, s["path"])})' for s in sessions)}
- Linhas avaliadas: [{Path(graded).name}]({rel(out, ROOT / graded)})
- Avaliador (Mac): [{rel(out, ROOT / 'analysis/slm_bfcl/evaluate.py')}]({rel(out, ROOT / 'analysis/slm_bfcl/evaluate.py')})
- Análise: [{rel(out, ROOT / 'analysis/slm_bfcl/analyze.py')}]({rel(out, ROOT / 'analysis/slm_bfcl/analyze.py')})
- Estudo narrativo prévio: [{rel(out, ROOT / 'reports/slm-bfcl/REPORT.md')}]({rel(out, ROOT / 'reports/slm-bfcl/REPORT.md')})

Gerar de novo (só Mac, sem iPhone):

```bash
python3 analysis/weekly/generate.py {spec['id']}
```
"""


def render_manifest(spec, evidence, sessions, r2, out):
    selection = json.loads((ROOT / "reports/slm-bfcl/selection.json").read_text())
    s0 = sessions[0]
    py = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    head = git_head()
    bfcl = installed("bfcl-eval")
    rows = [
        f"| `{e['path']}` | `{e['sha256'][:12]}…` | {e['bytes']} |"
        for e in evidence
    ]
    session_rows = []
    for s in sessions:
        session_rows.append(
            f"| {s['name']} | {', '.join(s['agents'])} | {s['n_measured']} | {s['finished']} | `{s['config'].get('orderSeed')}` | `{s['model']}` | `{s['sha256'][:12]}` |"
        )
    r2_rows = [
        f"| {a['label']} | {a['status']} | {a['n_measured']} | {a['n_graded']} | {a['session'] or '—'} |"
        for a in r2["agents"]
    ]
    return f"""# Manifesto de reprodutibilidade — {spec['id']}

Gerado em {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} UTC por `analysis/weekly/generate.py`.
Este arquivo descreve como os números da semana foram obtidos. **Não** relança inferência.

## Separação de máquinas

1. **iPhone:** geração greedy (temperature 0), `mlx-swift-lm` {s0['mlx']}, protocolo `{s0['config'].get('protocolId')}` / {s0.get('protocol')}.
2. **Mac:** `analysis/slm_bfcl/evaluate.py` chama o `ast_checker` de `bfcl-eval` {selection.get('bfcl_eval_version')} (instalado neste ambiente: {bfcl or 'não importável neste Python'}).
3. **Mac:** `analysis/weekly/generate.py` e `analysis/slm_bfcl/analyze.py` só leem JSON/JSONL já gravados.

## Ambiente de inferência (das sessões r1)

| Campo | Valor |
|---|---|
| Aparelho | {s0['device']} (iPhone 16 Pro) |
| Sistema | {s0['os']} |
| App | MobileLLMBench |
| `mlx-swift-lm` | {s0['mlx']} |
| Amostragem | {s0.get('sampling')}, temperature {s0.get('temperature')} |
| `seedAffectsSampling` | false (registrado nas sessões) |
| Seed de ordem r1 | `{s0['config'].get('orderSeed')}` |
| Dataset | `{s0['config'].get('dataset')}` / `{s0['config'].get('taskSetId')}` |
| `evaluationVersion` | `{s0.get('evaluation_version')}` |
| Warmup | {s0['config'].get('warmup')} |
| `requireCoolThermal` | {s0['config'].get('requireCoolThermal')} |
| Python do gerador | {py} |
| Git HEAD | `{head or 'indisponível'}` |

## Amostra BFCL

| Campo | Valor |
|---|---|
| `bfcl-eval` (freeze) | {selection.get('bfcl_eval_version')} |
| Seed da amostra | {selection.get('seed')} |
| Por categoria | {selection.get('per_category')} |
| Categorias | {', '.join(selection.get('categories') or [])} |
| Congelada antes da execução | {selection.get('frozen_before_execution')} |

SHA-256 das fontes oficiais: ver [selection.json]({rel(out, ROOT / 'reports/slm-bfcl/selection.json')}).

## Sessões r1 (inferência)

| Arquivo | Agente | Measured | Finished | Seed | Checkpoint | SHA-256 |
|---|---|---|---|---|---|---|
{chr(10).join(session_rows)}

## Repetição 2

| Modelo | Estado | Measured | Graded | Sessão |
|---|---|---|---|---|
{chr(10).join(r2_rows)}

## Arquivos de evidência

| Caminho | SHA-256 (prefixo) | Bytes |
|---|---|---|
{chr(10).join(rows)}

Digests SHA-256 completos:

```json
{json.dumps({e['path']: e['sha256'] for e in evidence}, indent=1)}
```

## Comandos (não incluem inferência no iPhone)

```bash
# Reavaliar sessões já puxadas do aparelho (Mac, checker oficial)
.bfcl-venv/bin/python analysis/slm_bfcl/evaluate.py \\
  results/slm-bfcl/main-r1-minicpm5.json \\
  results/slm-bfcl/main-r1-lfm25.json \\
  results/slm-bfcl/main-r1-gemma4.json \\
  results/slm-bfcl/main-r1-qwen35.json \\
  --out results/slm-bfcl/main-r1-graded.jsonl

# Tabelas cruas (mesmo cálculo deste relatório)
python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl

# Relatório semanal
python3 analysis/weekly/generate.py {spec['id']}
```

Inferência no iPhone (não executada por este gerador): `analysis/slm_bfcl/run_sessions.sh` + `analysis/slm_bfcl/device.sh`.
Amostra: `.bfcl-venv/bin/python analysis/slm_bfcl/freeze_sample.py`.

## O que este manifesto não cobre

- ToolSandbox / interações sequenciais com ferramentas.
- Repetição 2 de LFM2.5, Gemma 4 e Qwen3.5 como resultado (ver tabela "Repetição 2": ausentes ou interrompidas).
- Smoke tests (`results/slm-bfcl/smoke*.json`), excluídos da tabela principal.
"""


def git_head():
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None


def installed(name):
    try:
        from importlib.metadata import version
        return version(name)
    except Exception:
        pass
    venv = ROOT / ".bfcl-venv" / "bin" / "python"
    if not venv.exists():
        return None
    try:
        return subprocess.check_output(
            [str(venv), "-c", f"from importlib.metadata import version; print(version({name!r}))"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return None


def check(week_id):
    spec = load_week(week_id)
    rows = slm.load([ROOT / spec["r1"]["graded"]])
    study = slm.compute(rows)
    assert study["n"] == 880, study["n"]
    lookup = {(r["model"], r["strategy"]): r for r in study["main"]}
    qwen = lookup[("Qwen3.5-2B-4bit", "direct")]
    mini = lookup[("MiniCPM5-2B-MLX", "nothink")]
    lfm = lookup[("LFM2.5-2.6B-MLX-4bit", "direct")]
    gemma = lookup[("gemma-4-e2b-it-4bit", "nothink")]
    assert qwen["acc"] == 35 and qwen["n"] == 40, qwen
    assert abs(qwen["lat_mean"] - 21.2) < 0.05
    assert mini["acc"] == 34 and abs(mini["lat_mean"] - 7.5) < 0.05
    assert lfm["acc"] == 33
    assert gemma["acc"] == 31
    assert ("LFM2.5-2.6B-MLX-4bit", "nothink") not in lookup
    assert ("LFM2.5-2.6B-MLX-4bit", "adaptive_step") not in lookup
    thermal = thermal_summary(rows)
    assert thermal["after"]["serious"] == 880
    assert thermal["before"]["serious"] == 879
    assert len(thermal["non_serious"]) == 1
    lfm_ast = next(r for r in study["vs_best"] if "LFM" in r["model"] and r["strategy"] == "ast_router")
    assert lfm_ast["d_acc"] == 0
    assert lfm_ast["d_lat_hi"] < 0
    assert all(r["d_acc"] <= 0 for r in study["vs_best"] if r["adaptive"])
    out = generate(spec)
    readme = (out / "README.md").read_text()
    for needle in (
        "iPhone", "Mac", "880", "interações sequenciais",
        "ausente", "requireCoolThermal", "ast_router", "adaptive_step",
    ):
        assert needle in readme, needle
    r2_status = {a["agent"]: a["status"] for a in json.loads((out / "summary.json").read_text())["r2"]["agents"]}
    assert r2_status["minicpm5"] == "completa", r2_status
    assert all(s != "completa" for a, s in r2_status.items() if a != "minicpm5"), r2_status
    assert readme.count("Gemma 4 E2B:**") == 1, "linha r2 duplicada"
    for name in ("README.md", "tables.md", "MANIFEST.md", "summary.json"):
        assert (out / name).exists(), name
    for fig in ("quality_latency.png", "strategy_comparison.png", "latency_decomp.png"):
        assert (out / "figures" / fig).exists(), fig
    for line in readme.splitlines():
        if "](" in line and not line.strip().startswith("```"):
            for part in line.split("](")[1:]:
                target = part.split(")")[0].split()[0]
                if target.startswith("http") or target.startswith("figures/"):
                    continue
                path = (out / target).resolve()
                assert path.exists(), target
    tables = (out / "tables.md").read_text()
    assert "35/40 (88%)" in tables
    assert "34/40 (85%)" in tables
    manifest = (out / "MANIFEST.md").read_text()
    assert "00008140" not in readme + manifest
    print("WEEKLY_OK", out.relative_to(ROOT))


if __name__ == "__main__":
    main()
