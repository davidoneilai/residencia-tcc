"""Tabelas do BFCL Multi-Turn no iPhone para uma fatia congelada (dev ou test).

Lê results/bfcl-mt/{result,score}/ e controller-log.jsonl; só os IDs da fatia entram.
Avalie antes com `bfcl.py evaluate --model <m> --test-category multi_turn_base --partial-eval`.
    python3 analysis/bfcl_mt/analyze.py dev
"""
import json
import random
import sys
from collections import Counter
from math import comb
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "results" / "bfcl-mt"
FILE = "multi_turn/BFCL_v4_multi_turn_base_{}.json"
BEST = {"qwen35": "direct", "lfm25": "direct", "minicpm5": "nothink", "gemma4": "nothink"}
CONTRAST = {"qwen35": "nothink", "minicpm5": "direct", "gemma4": "direct"}


def total(x):
    return sum(total(i) for i in x) if isinstance(x, list) else (x or 0)


def steps(x):
    return sum(steps(i) for i in x) if isinstance(x, list) and x and isinstance(x[0], list) else len(x)


def load(model, ids):
    path = ROOT / "result" / model / FILE.format("result")
    score = ROOT / "score" / model / FILE.format("score")
    if not path.exists() or not score.exists():
        return {}
    failed = {json.loads(line)["id"] for line in score.read_text().splitlines()[1:] if line.strip()}
    out = {}
    for line in path.read_text().splitlines():
        row = json.loads(line)
        if row["id"] in ids and "latency" in row:
            out[row["id"]] = {"ok": row["id"] not in failed, "s": total(row["latency"]),
                              "steps": steps(row["latency"]), "in": total(row["input_token_count"])}
    return out


def mcnemar(a, b):
    """p bicaudal exato sobre os pares discordantes."""
    n = a + b
    if n == 0:
        return 1.0
    return min(1.0, 2 * sum(comb(n, k) for k in range(min(a, b) + 1)) / 2 ** n)


def boot(diffs, reps=10000, seed=20261104):
    rng = random.Random(seed)
    means = sorted(sum(rng.choices(diffs, k=len(diffs))) / len(diffs) for _ in range(reps))
    return means[int(0.025 * reps)], means[int(0.975 * reps)]


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "dev"
    ids = set(json.loads((ROOT / "slice.json").read_text())[name])
    print(f"# BFCL-MT `{name}` ({len(ids)} entradas), iPhone 16 Pro, KV incremental\n")
    print("| SLM | Condição | n | Acerto | Tempo/entrada (s) | Passos/entrada | Tokens de entrada/entrada |")
    print("|---|---|---|---|---|---|---|")
    runs = {}
    for slm in BEST:
        for cond in [BEST[slm], CONTRAST.get(slm), "adaptive"]:
            if not cond:
                continue
            got = load(f"iphone-{slm}-{cond}-prefix", ids)
            runs[slm, cond] = got
            if not got:
                continue
            n = len(got)
            tag = {BEST[slm]: " (melhor fixa AST)", "adaptive": " (A)"}.get(cond, "")
            print(f"| {slm} | {cond}{tag} | {n} | {sum(r['ok'] for r in got.values())}/{n} "
                  f"| {sum(r['s'] for r in got.values()) / n:.0f} | {sum(r['steps'] for r in got.values()) / n:.1f} "
                  f"| {sum(r['in'] for r in got.values()) / n / 1000:.1f} mil |")

    print("\n## A contra a melhor fixa (pareado por entrada)\n")
    print("| SLM | n | A certa, fixa errada | A errada, fixa certa | p (McNemar) | Δ tempo A − fixa (s) | IC95% |")
    print("|---|---|---|---|---|---|---|")
    for slm in BEST:
        a, f = runs.get((slm, "adaptive"), {}), runs.get((slm, BEST[slm]), {})
        common = sorted(set(a) & set(f))
        if not common:
            continue
        win = sum(a[i]["ok"] and not f[i]["ok"] for i in common)
        loss = sum(f[i]["ok"] and not a[i]["ok"] for i in common)
        diffs = [a[i]["s"] - f[i]["s"] for i in common]
        lo, hi = boot(diffs)
        print(f"| {slm} | {len(common)} | {win} | {loss} | {mcnemar(win, loss):.2f} "
              f"| {sum(diffs) / len(diffs):+.0f} | [{lo:+.0f}; {hi:+.0f}] |")

    log = ROOT / "controller-log.jsonl"
    if log.exists():
        rows = [json.loads(line) for line in log.read_text().splitlines() if line.strip()]
        # Só a última tentativa de cada (SLM, entrada): uma tentativa que caiu por conexão recomeça no passo 0.
        last = {}
        for r in rows:
            if r["id"] in ids:
                key = (r["slm"], r["id"])
                if r["step"] == 0:
                    last[key] = []
                last.setdefault(key, []).append(r)
        rows = [r for group in last.values() for r in group]
        print("\n## Decisões de A por passo\n")
        print("| SLM | Passos | default | tool_error → direct | repeat → direct | repeat_stop | error_stop |")
        print("|---|---|---|---|---|---|---|")
        for slm in BEST:
            c = Counter(r["trigger"] for r in rows if r["slm"] == slm)
            if c:
                print(f"| {slm} | {sum(c.values())} | {c['default']} | {c['tool_error']} | {c['repeat']} "
                      f"| {c['repeat_stop']} | {c['error_stop']} |")


if __name__ == "__main__":
    main()
