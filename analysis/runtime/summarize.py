"""Resumo dos microbenchmarks de runtime (saída de microbench.py).

    .bfcl-venv/bin/python analysis/runtime/summarize.py draft  results/runtime/draft-ab.jsonl
    .bfcl-venv/bin/python analysis/runtime/summarize.py prefix results/runtime/prefix-cold-warm.jsonl
"""
import json
import random
import sys
from collections import defaultdict


def boot(xs, reps=10000, seed=20261107):
    if not xs:
        return float("nan"), float("nan")
    rng = random.Random(seed)
    means = sorted(sum(rng.choices(xs, k=len(xs))) / len(xs) for _ in range(reps))
    return means[int(0.025 * reps)], means[int(0.975 * reps)]


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def draft(rows):
    pairs = defaultdict(dict)
    seen = defaultdict(int)
    for r in rows:
        key = (r["index"], seen[(r["index"], r["cond"])])
        seen[(r["index"], r["cond"])] += 1
        pairs[key][r["cond"]] = r
    pairs = [p for p in pairs.values() if "base" in p and "draft" in p]
    same = sum(p["draft"]["raw"] == p["base"]["raw"] and p["draft"]["calls"] == p["base"]["calls"] for p in pairs)
    print(f"{len(pairs)} pares (passo × repetição); saída idêntica (texto + chamadas) em {same}/{len(pairs)}")
    print("\n| passo | tokens | chamadas | decode base (ms) | decode rascunho (ms) | Δ decode | aceitos/propostos | verificações | refeeds |")
    print("|---|---|---|---|---|---|---|---|---|")
    by = defaultdict(list)
    for p in pairs:
        by[p["base"]["index"]].append(p)
    rel, dms, per_acc = [], [], []
    for idx, ps in sorted(by.items()):
        b = mean(p["base"]["decode_ms"] for p in ps)
        d = mean(p["draft"]["decode_ms"] for p in ps)
        acc = sum(p["draft"]["draft_accepted"] for p in ps)
        prop = sum(p["draft"]["draft_proposed"] for p in ps)
        ver = sum(p["draft"]["draft_verify_passes"] for p in ps)
        ref = sum(p["draft"]["draft_refeeds"] for p in ps)
        p0 = ps[0]
        print(f"| {p0['base']['id'][16:]} {p0['base']['turn']}.{p0['base']['step']} | {p0['base']['out']} | "
              f"{', '.join(c[0] for c in p0['base']['calls'])} | {b:.0f} | {d:.0f} | {100 * (d - b) / b:+.1f}% | "
              f"{acc}/{prop} | {ver} | {ref} |")
        for p in ps:
            rel.append((p["draft"]["decode_ms"] - p["base"]["decode_ms"]) / p["base"]["decode_ms"])
            dms.append(p["draft"]["decode_ms"] - p["base"]["decode_ms"])
            if p["draft"]["draft_accepted"]:
                per_acc.append(-dms[-1] / p["draft"]["draft_accepted"])
    lo, hi = boot(rel)
    print(f"\nΔ decode médio por passo: {100 * mean(rel):+.1f}% (IC95% {100 * lo:+.1f}% a {100 * hi:+.1f}%); "
          f"{mean(dms):+.0f} ms por passo; {mean(per_acc):.1f} ms economizados por token aceito.")
    tot_b = sum(p["base"]["decode_ms"] for p in pairs)
    tot_d = sum(p["draft"]["decode_ms"] for p in pairs)
    lat_b = sum(p["base"]["latency_ms"] for p in pairs)
    lat_d = sum(p["draft"]["latency_ms"] for p in pairs)
    print(f"Soma: decode {tot_b / 1000:.1f} s → {tot_d / 1000:.1f} s ({100 * (tot_d - tot_b) / tot_b:+.1f}%); "
          f"latência do servidor {lat_b / 1000:.1f} s → {lat_d / 1000:.1f} s ({100 * (lat_d - lat_b) / lat_b:+.1f}%).")
    acc = sum(p["draft"]["draft_accepted"] for p in pairs)
    prop = sum(p["draft"]["draft_proposed"] for p in pairs)
    out = sum(p["draft"]["out"] for p in pairs)
    print(f"Tokens aceitos do rascunho: {acc}/{prop} propostos ({100 * acc / max(1, prop):.1f}%), "
          f"{100 * acc / out:.1f}% dos tokens gerados; espera na verificação {mean(p['draft']['draft_wait_ms'] for p in pairs):.0f} ms/passo; "
          f"gramática {mean(p['draft']['draft_grammar_ms'] for p in pairs):.1f} ms/passo (CPU).")
    print(f"tokens/s (decode): base {mean(p['base']['out'] / p['base']['decode_ms'] * 1000 for p in pairs):.1f}, "
          f"rascunho {mean(p['draft']['out'] / p['draft']['decode_ms'] * 1000 for p in pairs):.1f}; "
          f"pico de memória base {mean(p['base']['peak_memory_mb'] for p in pairs):.0f} MB, "
          f"rascunho {mean(p['draft']['peak_memory_mb'] for p in pairs):.0f} MB")


def prefix(rows):
    by = defaultdict(dict)
    for r in rows:
        by[r["index"]][r["cond"]] = r
    print("| passo | prompt | condição | origem do prefixo | TTFT (ms) | prefill (ms) | carregar/gravar (ms) | latência (ms) | "
          "pico MB | saída = atual |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for idx, conds in sorted(by.items()):
        for name in ["current", "persist-cold", "persist-warm"]:
            r = conds.get(name)
            if not r:
                continue
            io = r["prefix_load_ms"] if name == "persist-warm" else r["prefix_save_ms"]
            print(f"| {r['id'][16:]} {r['turn']}.{r['step']} | {r['prompt']} | {name} | {r['prefix_source']} | "
                  f"{r['ttft_ms']:.0f} | {r['prefill_ms']:.0f} | {io:.0f} | {r['latency_ms']:.0f} | "
                  f"{r['peak_memory_mb']:.0f} | {'sim' if r['same_text'] and r['same_calls'] else 'NÃO'} |")
    warm = [c["persist-warm"] for c in by.values() if "persist-warm" in c]
    cur = [c["current"] for c in by.values() if "current" in c]
    if warm and cur:
        print(f"\nTTFT médio: atual {mean(r['ttft_ms'] for r in cur):.0f} ms → persistente quente "
              f"{mean(r['ttft_ms'] for r in warm):.0f} ms; leitura do disco {mean(r['prefix_load_ms'] for r in warm):.0f} ms; "
              f"gravação (frio) {mean(c['persist-cold']['prefix_save_ms'] for c in by.values() if 'persist-cold' in c):.0f} ms.")


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    rows = [json.loads(l) for l in open(path) if l.strip()]
    (draft if mode == "draft" else prefix)(rows)
