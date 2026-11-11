"""Critério pré-registrado (PROTOCOL-mtp.md / PROTOCOL-TEST-mtp.md): pilha + MTP contra a pilha, pareado.

    python3 analysis/runtime/mtp_decide.py <análise.json> <ref> <cand> <saída.json> [perda_máx]

Pares = mesma rodada e mesma entrada. Tempo: Δ médio (cand − ref) por par, IC95% bootstrap (10 000 reamostras,
seed 0), passa se o IC inteiro estiver abaixo de zero. Acerto: perda líquida (ref certo e cand errado menos o
contrário) ≤ perda_máx (padrão 1) e McNemar exato bilateral p ≥ 0,05 quando a perda líquida é positiva.
Sai com código 0 se os dois passam, 1 caso contrário.
"""
import json
import random
import sys
from math import comb


def mcnemar(b, c):
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    return min(1.0, 2 * sum(comb(n, i) for i in range(k + 1)) / 2 ** n)


def main():
    rows = json.load(open(sys.argv[1]))
    ref, cand, out = sys.argv[2], sys.argv[3], sys.argv[4]
    limit = int(sys.argv[5]) if len(sys.argv) > 5 else 1
    by = {}
    for r in rows:
        by.setdefault((r["run"], r["id"]), {})[r["cond"]] = r
    pairs = [(v[ref], v[cand]) for v in by.values() if ref in v and cand in v]
    deltas = [c["latency_s"] - r["latency_s"] for r, c in pairs]
    rng = random.Random(0)
    means = sorted(sum(rng.choice(deltas) for _ in deltas) / len(deltas) for _ in range(10000))
    lo, hi = means[249], means[9749]
    lost = sum(r["ok"] and not c["ok"] for r, c in pairs)
    won = sum(c["ok"] and not r["ok"] for r, c in pairs)
    p = mcnemar(lost, won)
    ref_mean = sum(r["latency_s"] for r, _ in pairs) / len(pairs)
    result = {
        "pairs": len(pairs), "ref": ref, "cand": cand,
        "ref_ok": sum(r["ok"] for r, _ in pairs), "cand_ok": sum(c["ok"] for _, c in pairs),
        "lost": lost, "won": won, "mcnemar_p": p,
        "ref_mean_s": ref_mean, "delta_mean_s": sum(deltas) / len(deltas), "delta_ci95": [lo, hi],
        "delta_pct": 100 * (sum(deltas) / len(deltas)) / ref_mean,
        "ref_decode_s": sum(r.get("decode_s") or 0 for r, _ in pairs) / len(pairs),
        "cand_decode_s": sum(c.get("decode_s") or 0 for _, c in pairs) / len(pairs),
    }
    result["time_pass"] = hi < 0
    result["accuracy_pass"] = (lost - won) <= limit and (lost <= won or p >= 0.05)
    result["pass"] = result["time_pass"] and result["accuracy_pass"]
    json.dump(result, open(out, "w"), indent=1)
    print(json.dumps(result, indent=1))
    sys.exit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
