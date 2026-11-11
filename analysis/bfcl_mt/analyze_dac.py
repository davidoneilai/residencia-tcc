"""Tabelas do estudo DAC (BFCL Multi-Turn, Qwen3.5-2B no iPhone) a partir de results/bfcl-mt/dac/<rodada>/.

    .bfcl-venv/bin/python analysis/bfcl_mt/analyze_dac.py <saida.md> <rodada> [rodada ...] [--conds a,b,c] [--ref cond]

Cada rodada é uma repetição (mesmas entradas, ordem girada). Lê result/ e score/ do bfcl (rode `evaluate` antes),
`trace.jsonl` (bloco `device` por passo) e os logs de decisão (`controller-log.jsonl` de A, `dac-log.jsonl` de DAC).
Grava também <saida>.json com as linhas por (rodada, condição, entrada).
"""
import json
import random
import sys
from collections import Counter, defaultdict
from math import comb
import os
from pathlib import Path

BASE = Path(__file__).resolve().parents[2] / "results" / "bfcl-mt" / "dac"
FILE = "multi_turn/BFCL_v4_multi_turn_base_{}.json"
SLM = os.environ.get("BENCH_SLM", "qwen35")  # mesmo nome do runner (run_eval.py)
LABEL = {
    "reason-off": "Reasoning fixo, sem cache",
    "reason-prefix": "Reasoning, prefix cache antigo",
    "reason-kv": "Reasoning + cache incremental (kv)",
    "a-kv": "Política A original (kv)",
    "dac-kv": "DAC: kv + recuperação",
    "dacs-kv": "DAC + seletiva (guardas de decode)",
    "reason-guard-kv": "Reasoning + kv + guardas",
    "reason-b512-kv": "Reasoning + kv, orçamento fixo 512",
    "dacs256-kv": "DAC seletiva, orçamento fixo 256",
    "dacs128-kv": "DAC seletiva, orçamento fixo 128",
    "paca-kv": "PACA (orçamento por progresso)",
    "rt-base-kv": "Runtime atual (Reasoning 512, kv)",
    "rt-persist-kv": "+ prefixo persistente",
    "rt-draft-kv": "+ rascunho da gramática",
    "rt-both-kv": "+ prefixo persistente + rascunho",
    "dacs-persist-kv": "DACS + prefixo persistente (pilha completa)",
    "dacs-persist-mtp-kv": "Pilha + MTP em pipeline (escalonador por custo)",
    "nt-base-kv": "NoThink + kv",
    "nt-dacs-persist-kv": "NoThink: DAC + repeat_guard + prefixo persistente",
}


def flat(x):
    return [z for y in x for z in y] if x and isinstance(x[0], list) else list(x)


def last_attempt(rows):
    """Só a última tentativa de cada entrada: uma tentativa que caiu por conexão recomeça do passo 0."""
    keep = defaultdict(list)
    for r in rows:
        key = (r.get("condition") or r.get("slm"), r["id"])
        if r["step"] == 0 and r.get("turn", 0) == 0:
            keep[key] = []
        keep[key].append(r)
    return keep


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()] if path.exists() else []


def load_run(run, conds):
    root = BASE / run
    trace = last_attempt(read_jsonl(root / "trace.jsonl"))
    dac = last_attempt(read_jsonl(root / "dac-log.jsonl"))
    alog = last_attempt([{**r, "condition": "a"} for r in read_jsonl(root / "controller-log.jsonl")])
    out = {}
    for cond in conds:
        model = f"iphone-{SLM}-dac-{cond}"
        res_path, score_path = root / "result" / model / FILE.format("result"), root / "score" / model / FILE.format("score")
        if not res_path.exists() or not score_path.exists():
            continue
        fails = {json.loads(line)["id"]: json.loads(line)["error"]["error_type"]
                 for line in score_path.read_text().splitlines()[1:] if line.strip()}
        for line in res_path.read_text().splitlines():
            r = json.loads(line)
            if "latency" not in r:
                continue
            steps = trace.get((cond, r["id"]), [])
            dev = [s["device"] for s in steps]
            decisions = dac.get((cond, r["id"]), []) if cond.startswith("dac") else (
                alog.get(("a", r["id"]), []) if cond == "a-kv" else [])
            calls = [[json.dumps(c, sort_keys=True) for c in step] if isinstance(step, list) else []
                     for turn in r["result"] for step in turn]
            out[cond, r["id"]] = {
                "run": run, "cond": cond, "id": r["id"], "ok": r["id"] not in fails, "error": fails.get(r["id"]),
                "latency_s": sum(flat(r["latency"])), "steps": len(flat(r["latency"])),
                "llm_steps": len(steps), "in_tokens": sum(flat(r["input_token_count"])),
                "out_tokens": sum(flat(r["output_token_count"])),
                "prefill_s": sum(d.get("prefill_ms", 0) for d in dev) / 1000,
                "prefill_tokens": sum(d.get("prefill_tokens", 0) for d in dev),
                "decode_s": sum(d.get("decode_ms", 0) for d in dev) / 1000,
                "overhead_s": sum(d.get("template_ms", 0) + d.get("cache_ms", 0) - d.get("fill_ms", 0)
                                  - d.get("prefix_build_ms", 0) for d in dev) / 1000,
                "ttft_s": [d.get("ttft_ms", 0) / 1000 for d in dev],
                "server_s": sum(d.get("latency_ms", 0) for d in dev) / 1000,
                "peak_mb": max((d.get("peak_memory_mb", 0) for d in dev), default=0),
                "thermal": [d.get("thermal_after") for d in dev],
                "capped": sum(1 for s in steps if s.get("finish") == "length"),
                "forced": sum(1 for d in dev if d.get("forced_close")),
                "repeat_cut": sum(1 for d in dev if d.get("repeat_cut")),
                "reused_from": Counter(d.get("reused_from") for d in dev),
                "triggers": Counter(d["trigger"] for d in decisions),
                # Recuperada = turno com nota que terminou sem stop (respondeu ou seguiu sem repetir/errar).
                "recovered_turns": sum(
                    1 for t in {d["turn"] for d in decisions if d["trigger"].startswith("detect")}
                    if not any(d["turn"] == t and d["trigger"].startswith("recovery_failed") for d in decisions)),
                "note_tokens_chars": sum(d.get("note_chars", 0) for d in decisions),
                "loop3": int(any(step_calls and turn_calls.count(step_calls) >= 3
                                 for turn_calls in [[json.dumps(s, sort_keys=True) for s in turn] for turn in r["result"]]
                                 for step_calls in turn_calls)),
                # Chamadas com argumentos parseados (a ordem das chaves vem de um Dictionary do Swift, aleatória por
                # processo); texto final conta só como "respondeu".
                "responses": [json.dumps([[k, json.loads(v)] for c in s for k, v in c.items()], sort_keys=True)
                              if isinstance(s, list) else "TEXT" for turn in r["result"] for s in turn],
            }
    return out


def mcnemar(a, b):
    n = a + b
    return 1.0 if n == 0 else min(1.0, 2 * sum(comb(n, k) for k in range(min(a, b) + 1)) / 2 ** n)


def boot(diffs, reps=10000, seed=20261106):
    if not diffs:
        return float("nan"), float("nan")
    rng = random.Random(seed)
    means = sorted(sum(rng.choices(diffs, k=len(diffs))) / len(diffs) for _ in range(reps))
    return means[int(0.025 * reps)], means[int(0.975 * reps)]


def mean(xs):
    xs = list(xs)
    return sum(xs) / len(xs) if xs else float("nan")


def main():
    args = sys.argv[1:]
    out_path = Path(args.pop(0))
    conds = list(LABEL)
    ref = "reason-kv"
    if "--conds" in args:
        i = args.index("--conds"); conds = args[i + 1].split(","); del args[i:i + 2]
    if "--ref" in args:
        i = args.index("--ref"); ref = args[i + 1]; del args[i:i + 2]
    runs = args
    rows = {}
    for run in runs:
        for (cond, entry), row in load_run(run, conds).items():
            rows[run, cond, entry] = row
    conds = [c for c in conds if any(k[1] == c for k in rows)]
    entries = sorted({k[2] for k in rows}, key=lambda x: int(x.rsplit("_", 1)[1]))
    lines = [f"# DAC — BFCL Multi-Turn, Qwen3.5-2B no iPhone 16 Pro", "",
             f"Rodadas: {', '.join(runs)}; entradas: {len(entries)}. Tempos em s por entrada (média sobre entradas × rodadas).", ""]

    lines += ["| Condição | n | Acerto (por rodada) | Tempo | TTFT/passo | Prefill | Decode | Overhead | Tok. entrada | "
              "Tok. prefill | Tok. saída | Passos | Loops ≥3 | Teto 1024 | Pico MB |", "|" + "---|" * 15]
    for c in conds:
        rs = [r for k, r in rows.items() if k[1] == c]
        per_run = [sum(r["ok"] for k, r in rows.items() if k[1] == c and k[0] == run) for run in runs]
        n_run = [sum(1 for k in rows if k[1] == c and k[0] == run) for run in runs]
        acc = " · ".join(f"{a}/{n}" for a, n in zip(per_run, n_run) if n)
        ttft = [t for r in rs for t in r["ttft_s"]]
        lines.append(
            f"| {LABEL.get(c, c)} | {len(rs)} | {acc} | {mean(r['latency_s'] for r in rs):.1f} | {mean(ttft):.2f} "
            f"| {mean(r['prefill_s'] for r in rs):.1f} | {mean(r['decode_s'] for r in rs):.1f} "
            f"| {mean(r['overhead_s'] for r in rs):.1f} | {mean(r['in_tokens'] for r in rs) / 1000:.1f} mil "
            f"| {mean(r['prefill_tokens'] for r in rs) / 1000:.2f} mil | {mean(r['out_tokens'] for r in rs):.0f} "
            f"| {mean(r['steps'] for r in rs):.1f} | {sum(r['loop3'] for r in rs)} | {sum(r['capped'] for r in rs)} "
            f"| {max((r['peak_mb'] for r in rs), default=0):.0f} |")

    lines += ["", f"## Pareado contra `{ref}` (entrada × rodada)", "",
              "| Condição | pares | certa só aqui | certa só na ref. | p (McNemar, por entrada × rodada) | Δ tempo (s) | IC95% | Δ tempo (%) |",
              "|---|---|---|---|---|---|---|---|"]
    for c in conds:
        if c == ref:
            continue
        keys = [(run, e) for run in runs for e in entries if (run, c, e) in rows and (run, ref, e) in rows]
        if not keys:
            continue
        win = sum(rows[run, c, e]["ok"] and not rows[run, ref, e]["ok"] for run, e in keys)
        loss = sum(rows[run, ref, e]["ok"] and not rows[run, c, e]["ok"] for run, e in keys)
        diffs = [rows[run, c, e]["latency_s"] - rows[run, ref, e]["latency_s"] for run, e in keys]
        base = mean(rows[run, ref, e]["latency_s"] for run, e in keys)
        lo, hi = boot(diffs)
        lines.append(f"| {LABEL.get(c, c)} | {len(keys)} | {win} | {loss} | {mcnemar(win, loss):.2f} "
                     f"| {mean(diffs):+.1f} | [{lo:+.1f}; {hi:+.1f}] | {100 * mean(diffs) / base:+.0f}% |")

    lines += ["", "## Mecanismos (soma sobre entradas × rodadas)", "",
              "| Condição | Detecções (repetição/erro) | Recuperadas | Falharam → stop | Stops de A | Raciocínio fechado à força | Corte de chamada repetida | Caracteres de nota | KV reaproveitado (conv/turn/system/none) |",
              "|---|---|---|---|---|---|---|---|---|"]
    for c in conds:
        rs = [r for k, r in rows.items() if k[1] == c]
        t = sum((r["triggers"] for r in rs), Counter())
        reuse = sum((r["reused_from"] for r in rs), Counter())
        lines.append(
            f"| {LABEL.get(c, c)} | {t['detect_repeat']}/{t['detect_error']} | {sum(r['recovered_turns'] for r in rs)} "
            f"| {t['recovery_failed_repeat'] + t['recovery_failed_error']} | {t['repeat_stop'] + t['error_stop']} "
            f"| {sum(r['forced'] for r in rs)} | {sum(r['repeat_cut'] for r in rs)} | {sum(r['note_tokens_chars'] for r in rs)} "
            f"| {reuse['conv']}/{reuse['turn']}/{reuse['system']}/{reuse['none'] + reuse[None]} |")

    lines += ["", "## Por entrada (acertos nas rodadas · tempo médio s)", "",
              "| Entrada | " + " | ".join(LABEL.get(c, c) for c in conds) + " |", "|---" * (len(conds) + 1) + "|"]
    for e in entries:
        cells = []
        for c in conds:
            rs = [rows[run, c, e] for run in runs if (run, c, e) in rows]
            if not rs:
                cells.append("—")
                continue
            errs = Counter(r["error"].split(":")[-1] for r in rs if r["error"])
            cells.append(f"{sum(r['ok'] for r in rs)}/{len(rs)} · {mean(r['latency_s'] for r in rs):.0f}"
                         + (f" ({', '.join(errs)})" if errs else ""))
        lines.append(f"| {e.replace('multi_turn_base_', '')} | " + " | ".join(cells) + " |")

    lines += ["", "## Modos de falha (entradas × rodadas)", "", "| Condição | " + " | ".join(
        ["force_terminated", "instance_state_mismatch", "execution_response_mismatch", "empty_turn_model_response",
         "outros"]) + " |", "|---" * 6 + "|"]
    for c in conds:
        errs = Counter((r["error"] or "").split(":")[-1] for k, r in rows.items() if k[1] == c and r["error"])
        known = ["force_terminated", "instance_state_mismatch", "execution_response_mismatch",
                 "empty_turn_model_response"]
        lines.append(f"| {LABEL.get(c, c)} | " + " | ".join(str(errs[k]) for k in known)
                     + f" | {sum(v for k, v in errs.items() if k not in known)} |")

    therm = Counter(t for r in rows.values() for t in r["thermal"])
    lines += ["", f"Térmica ao fim de cada passo (todas as condições): {dict(therm)}.", ""]

    # Mesma trajetória? Respostas idênticas passo a passo contra a referência.
    lines += ["## Consistência contra a referência (chamadas e argumentos; texto final = TEXT)", ""]
    for c in conds:
        if c == ref:
            continue
        same = total = identical = 0
        for run in runs:
            for e in entries:
                if (run, c, e) in rows and (run, ref, e) in rows:
                    a, b = rows[run, c, e]["responses"], rows[run, ref, e]["responses"]
                    k = 0
                    while k < min(len(a), len(b)) and a[k] == b[k]:
                        k += 1
                    same += k
                    total += max(len(a), len(b))
                    identical += a == b
        if total:
            lines.append(f"- {LABEL.get(c, c)}: {identical} trajetórias idênticas; {same}/{total} passos iguais antes da divergência.")
    out_path.write_text("\n".join(lines) + "\n")
    json_rows = [{k: (dict(v) if isinstance(v, Counter) else v) for k, v in r.items() if k != "responses"}
                 for r in rows.values()]
    out_path.with_suffix(".json").write_text(json.dumps(json_rows, indent=1) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
