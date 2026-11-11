"""Pilha fria (rodada A) e quente (rodada B) contra a referência da rodada A, pareado por entrada.

    python3 analysis/runtime/cold_warm.py <linhas.json de analyze_dac> <ref> <pilha> <rodada A> <rodada B>
"""
import json
import random
import sys

rows, ref, stack, run_a, run_b = json.load(open(sys.argv[1])), *sys.argv[2:6]
by = {(r["run"], r["cond"], r["id"]): r for r in rows}
ids = sorted({r["id"] for r in rows}, key=lambda x: int(x.rsplit("_", 1)[1]))


def paired(run):
    pairs = [(by[run_a, ref, i], by[run, stack, i]) for i in ids if (run_a, ref, i) in by and (run, stack, i) in by]
    deltas = [s["latency_s"] - r["latency_s"] for r, s in pairs]
    base = sum(r["latency_s"] for r, _ in pairs) / len(pairs)
    rng = random.Random(0)
    boot = sorted(sum(rng.choice(deltas) for _ in deltas) / len(deltas) for _ in range(10000))
    mean = sum(deltas) / len(deltas)
    return {"n": len(pairs), "ref_ok": sum(r["ok"] for r, _ in pairs), "stack_ok": sum(s["ok"] for _, s in pairs),
            "only_ref": [r["id"].rsplit("_", 1)[1] for r, s in pairs if r["ok"] and not s["ok"]],
            "only_stack": [r["id"].rsplit("_", 1)[1] for r, s in pairs if s["ok"] and not r["ok"]],
            "ref_s": round(base, 1), "stack_s": round(base + mean, 1), "delta_s": round(mean, 1),
            "ci95": [round(boot[250], 1), round(boot[9750], 1)], "delta_pct": round(100 * mean / base)}


print(json.dumps({"fria (A)": paired(run_a), "quente (B)": paired(run_b)}, ensure_ascii=False, indent=1))
