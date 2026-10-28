"""Tabelas do estudo SLM × BFCL v4 AST a partir das linhas avaliadas pelo checker oficial.

    python3 analysis/slm_bfcl/analyze.py results/slm-bfcl/main-r1-graded.jsonl > reports/slm-bfcl/tables.md
"""
import json
import random
import statistics as st
import sys
from collections import Counter, defaultdict

FIXED = ["direct", "plan_act", "nothink", "budget_64"]
ADAPTIVE = ["ast_router", "adaptive_step"]
CATS = ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]
B = 10000


def load(paths):
    rows = [json.loads(l) for p in paths for l in open(p) if l.strip()]
    for r in rows:
        r["m"] = r["model"].split("/")[1].split("@")[0]
    return rows


def boot(diffs, seed=7):
    rng = random.Random(seed)
    n = len(diffs)
    means = sorted(sum(rng.choice(diffs) for _ in range(n)) / n for _ in range(B))
    return means[int(0.025 * B)], means[int(0.975 * B)]


def index_rows(rows):
    cell = defaultdict(dict)
    for r in rows:
        cell[(r["m"], r["strategy_id"])][r["task"]] = r
    return cell, sorted({r["m"] for r in rows})


def compute(rows):
    """Agrega linhas já avaliadas pelo checker oficial. Não infere no iPhone."""
    cell, models = index_rows(rows)
    main, best = [], {}
    for m in models:
        for s in FIXED + ADAPTIVE:
            t = cell.get((m, s))
            if not t:
                continue
            rs = list(t.values())
            acc = sum(r["valid"] for r in rs)
            lat = [r["total_ms"] / 1000 for r in rs]
            row = {
                "model": m,
                "strategy": s,
                "n": len(rs),
                "acc": acc,
                "lat_mean": st.mean(lat),
                "lat_median": st.median(lat),
                "prefill": st.mean((r["prefill_ms"] or 0) / 1000 for r in rs),
                "decode": st.mean((r["decode_ms"] or 0) / 1000 for r in rs),
                "tin": st.mean(r["input_tokens"] or 0 for r in rs),
                "tout": st.mean(r["output_tokens"] or 0 for r in rs),
                "mem": max(r["peak_mem_mb"] or 0 for r in rs),
                "fails": Counter(r["failure"] for r in rs if r["failure"]),
                "adaptive": s in ADAPTIVE,
            }
            main.append(row)
            if s in FIXED:
                key = (acc, -st.mean(lat))
                if m not in best or key > best[m][0]:
                    best[m] = (key, s)
    best_s = {m: best[m][1] for m in best}
    cats = []
    for m in models:
        for s in FIXED + ADAPTIVE:
            t = cell.get((m, s))
            if t:
                cats.append({
                    "model": m, "strategy": s,
                    "counts": {c: sum(r["valid"] for r in t.values() if r["category"] == c) for c in CATS},
                })
    vs = []
    for m in models:
        bs = best_s[m]
        ref = cell[(m, bs)]
        for s in ADAPTIVE + [x for x in FIXED if x != bs]:
            t = cell.get((m, s))
            if not t:
                continue
            ids = sorted(set(t) & set(ref))
            da = [t[i]["valid"] - ref[i]["valid"] for i in ids]
            dl = [(t[i]["total_ms"] - ref[i]["total_ms"]) / 1000 for i in ids]
            la, ha = boot(da)
            ll, hl = boot(dl)
            vs.append({
                "model": m, "best_fixed": bs, "strategy": s, "n": len(ids),
                "d_acc": st.mean(da), "d_acc_lo": la, "d_acc_hi": ha,
                "d_lat": st.mean(dl), "d_lat_lo": ll, "d_lat_hi": hl,
                "decisions": dict(Counter(t[i]["executed"] for i in ids)) if s in ADAPTIVE else {},
                "adaptive": s in ADAPTIVE,
            })
    oracle = []
    for m in models:
        bs = best_s[m]
        fixed = [s for s in FIXED if (m, s) in cell]
        ids = sorted(cell[(m, bs)])

        def n_oracle(pol):
            return sum(any(cell[(m, s)][i]["valid"] for s in pol) for i in ids)

        extra = sum(any(cell[(m, s)][i]["valid"] for s in fixed) and not cell[(m, bs)][i]["valid"] for i in ids)
        cheap = []
        for i in ids:
            ok = [cell[(m, s)][i] for s in fixed if cell[(m, s)][i]["valid"]]
            pick = min(ok, key=lambda r: r["total_ms"]) if ok else min((cell[(m, s)][i] for s in fixed), key=lambda r: r["total_ms"])
            cheap.append(pick["total_ms"] / 1000)
        refl = st.mean(cell[(m, bs)][i]["total_ms"] / 1000 for i in ids)
        allp = fixed + [s for s in ADAPTIVE if (m, s) in cell]
        n_tasks = len(ids)
        oracle.append({
            "model": m, "best_fixed": bs, "n": n_tasks,
            "best_acc": sum(cell[(m, bs)][i]["valid"] for i in ids),
            "oracle_fixed": n_oracle(fixed),
            "oracle_all": n_oracle(allp),
            "extra": extra,
            "cheap_lat": st.mean(cheap),
            "best_lat": refl,
        })
    ids = sorted(cell[(models[0], best_s[models[0]])]) if models else []
    n_tasks = len(ids)
    solved = {m: {i for i in ids if cell[(m, best_s[m])][i]["valid"]} for m in models}
    union = set().union(*solved.values()) if solved else set()
    inter = set(ids).intersection(*solved.values()) if solved else set()
    exclusive = {
        m: sorted(solved[m] - set().union(*(solved[o] for o in models if o != m)))
        for m in models
    }
    return {
        "n": len(rows),
        "n_tasks": n_tasks,
        "models": models,
        "cell": cell,
        "main": main,
        "best_fixed": best_s,
        "by_category": cats,
        "vs_best": vs,
        "oracle": oracle,
        "complementarity": {
            "union": len(union),
            "intersection": len(inter),
            "none": n_tasks - len(union),
            "solved": {m: len(solved[m]) for m in models},
            "exclusive": exclusive,
        },
    }


def render_tables(study):
    n = study["n_tasks"] or 40
    lines = [
        f"## Tabela principal (BFCL v4 AST, {n} tarefas, checker oficial)",
        "",
        "| Modelo | Estratégia | Acurácia | Latência média (s) | Mediana (s) | Prefill (s) | Decode (s) | Tokens in/out | Pico mem (MB) | Falhas |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for r in study["main"]:
        fails = ", ".join(f"{k} {v}" for k, v in r["fails"].most_common())
        lines.append(
            f"| {r['model']} | {r['strategy']} | {r['acc']}/{r['n']} ({r['acc'] / r['n']:.0%}) | {r['lat_mean']:.1f} | {r['lat_median']:.1f} | "
            f"{r['prefill']:.1f} | {r['decode']:.1f} | {r['tin']:.0f}/{r['tout']:.0f} | {r['mem']:.0f} | {fails} |"
        )
    lines += [
        "",
        f"## Por categoria (acertos de {n // len(CATS) if CATS else 8})",
        "",
        "| Modelo | Estratégia | " + " | ".join(CATS) + " |",
        "|---|---|" + "---|" * len(CATS),
    ]
    for r in study["by_category"]:
        lines.append(f"| {r['model']} | {r['strategy']} | " + " | ".join(str(r["counts"][c]) for c in CATS) + " |")
    lines += [
        "",
        "## Adaptativas × melhor fixa do mesmo modelo (pareado por tarefa; IC95% bootstrap)",
        "",
        "| Modelo | Melhor fixa | Política | Δ acurácia (pp) | IC95% | Δ latência média (s) | IC95% | Decisões |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for r in study["vs_best"]:
        dec = dict(r["decisions"]) if r["decisions"] else ""
        lines.append(
            f"| {r['model']} | {r['best_fixed']} | {r['strategy']} | {100 * r['d_acc']:+.1f} | [{100 * r['d_acc_lo']:+.1f}, {100 * r['d_acc_hi']:+.1f}] | "
            f"{r['d_lat']:+.1f} | [{r['d_lat_lo']:+.1f}, {r['d_lat_hi']:+.1f}] | {dec} |"
        )
    lines += [
        "",
        "## Oracle retrospectivo (escolha por tarefa entre políticas avaliadas; limite superior)",
        "",
        "| Modelo | Melhor fixa | Oracle fixas | Oracle fixas+adaptativas | Tarefas resolvidas só por ≠ melhor fixa | Oracle mais barato: latência média (s) vs melhor fixa |",
        "|---|---|---|---|---|---|",
    ]
    for r in study["oracle"]:
        lines.append(
            f"| {r['model']} | {r['best_fixed']} {r['best_acc']}/{r['n']} | {r['oracle_fixed']}/{r['n']} | {r['oracle_all']}/{r['n']} | {r['extra']} | {r['cheap_lat']:.1f} vs {r['best_lat']:.1f} |"
        )
    c = study["complementarity"]
    lines += [
        "",
        "## Complementaridade entre modelos (melhor fixa de cada)",
        "",
        f"União: {c['union']}/{n} · interseção: {c['intersection']}/{n} · nenhuma resolve: {c['none']}",
        "",
    ]
    for m in study["models"]:
        lines.append(f"- {m}: {c['solved'][m]}/{n}; exclusivas: {c['exclusive'][m]}")
    return "\n".join(lines) + "\n"


def main():
    sys.stdout.write(render_tables(compute(load(sys.argv[1:]))))


if __name__ == "__main__":
    main()
