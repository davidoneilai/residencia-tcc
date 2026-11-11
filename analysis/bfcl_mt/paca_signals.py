"""Sinais de progresso por passo nos logs DEV do DAC (entrada para a PACA).

    .bfcl-venv/bin/python analysis/bfcl_mt/paca_signals.py [rodada ...] [--conds a,b]

Junta o `inference_log` do bfcl (chamadas, argumentos, resultados das tools) com o `trace.jsonl` (tokens, decode,
texto bruto com o raciocínio) e classifica cada passo pelo que ele produziu no turno:
- `new`: só chamadas inéditas no turno, sem erro, resultado inédito (progresso);
- `same_result`: chamada inédita sem erro, mas o resultado já tinha saído no turno (sem efeito novo);
- `repeat`: alguma chamada idêntica (nome + argumentos) a uma anterior do turno;
- `error`: alguma tool devolveu erro;
- `text`: sem chamada (resposta ao usuário; o BFCL encerra o turno);
- `capped`: chegou ao teto de tokens sem chamada.
"""
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_dac import BASE, FILE, SLM, last_attempt, read_jsonl  # noqa: E402
from controller import is_error  # noqa: E402

CLOSE = "</think>"


def think_tokens(row):
    """Tokens de raciocínio do passo: exato quando o servidor informa (`think_budget` ligado); senão, proporção de
    caracteres do `raw_text`. O servidor corta o `raw_text` em 500 caracteres: sem `</think>` nele, o tamanho é
    desconhecido (None), a não ser no teto."""
    dev = row.get("device", {})
    if dev.get("think_tokens") is not None:
        return dev["think_tokens"]
    text, out = dev.get("raw_text") or "", row.get("completion_tokens") or 0
    if CLOSE not in text:
        return out if row.get("finish") == "length" else (0 if len(text) < 500 else None)
    head = len(text.split(CLOSE, 1)[0])
    return round(out * head / max(1, len(text)))


def steps_of(run, cond):
    """Uma linha por passo LLM: (entrada, turno, passo, classe, classe anterior, tokens, decode)."""
    root = BASE / run
    model = f"iphone-{SLM}-dac-{cond}"
    res, score = root / "result" / model / FILE.format("result"), root / "score" / model / FILE.format("score")
    if not res.exists() or not score.exists():
        return []
    fails = {json.loads(l)["id"] for l in score.read_text().splitlines()[1:] if l.strip()}
    trace = last_attempt(read_jsonl(root / "trace.jsonl"))
    out = []
    for line in res.read_text().splitlines():
        r = json.loads(line)
        if "latency" not in r:
            continue
        rows = {(t["turn"], t["step"]): t for t in trace.get((cond, r["id"]), [])}
        for turn_index, turn in enumerate(x for x in r["inference_log"] if isinstance(x, dict)):
            seen_calls, seen_results, prev = [], set(), "turn_start"
            keys = sorted((k for k in turn if k.startswith("step_")), key=lambda k: int(k[5:]))
            for k in keys:
                msgs = turn[k]
                t = rows.get((turn_index, int(k[5:])))
                if t is None:  # stop do controlador: sem chamada ao modelo
                    continue
                content = next((m["content"] for m in msgs if m["role"] == "assistant"), "")
                calls = [(n, json.dumps(json.loads(a), sort_keys=True) if a else "{}")
                         for c in content for n, a in c.items()] if isinstance(content, list) else []
                results = [m["content"] for m in msgs if m["role"] == "tool"]
                if not calls:
                    kind = "capped" if t.get("finish") == "length" else "text"
                elif any(c in seen_calls for c in calls):
                    kind = "repeat"
                elif any(is_error(x) for x in results):
                    kind = "error"
                elif all(x in seen_results for x in results):
                    kind = "same_result"
                else:
                    kind = "new"
                seen_calls += calls
                seen_results |= set(results)
                out.append({"run": run, "cond": cond, "id": r["id"], "ok": r["id"] not in fails, "turn": turn_index,
                            "step": int(k[5:]), "kind": kind, "prev": prev, "think": think_tokens(t),
                            "out": t.get("completion_tokens") or 0, "decode_s": t["device"].get("decode_ms", 0) / 1000,
                            "client_s": t.get("client_s", 0), "forced": bool(t["device"].get("forced_close"))})
                prev = kind
    return out


def main():
    args = sys.argv[1:]
    conds = ["reason-kv", "dacs-kv"]
    if "--conds" in args:
        i = args.index("--conds"); conds = args[i + 1].split(","); del args[i:i + 2]
    runs = args or ["r1", "r2", "r3"]
    for cond in conds:
        rows = [s for run in runs for s in steps_of(run, cond) if s["think"] is not None]
        if not rows:
            continue
        print(f"\n## {cond}: {len(rows)} passos, {len({(s['run'], s['id']) for s in rows})} entradas")
        total = sum(s["decode_s"] for s in rows)
        print("| contexto (classe anterior) | passos | think médio | saída média | decode s (%) | próximo: new/same/repeat/error/text/capped |")
        print("|---|---|---|---|---|---|")
        by_prev = defaultdict(list)
        for s in rows:
            by_prev[s["prev"]].append(s)
        for prev, ss in sorted(by_prev.items(), key=lambda x: -len(x[1])):
            nxt = Counter(s["kind"] for s in ss)
            dec = sum(s["decode_s"] for s in ss)
            print(f"| {prev} | {len(ss)} | {sum(s['think'] for s in ss) / len(ss):.0f} | "
                  f"{sum(s['out'] for s in ss) / len(ss):.0f} | {dec:.0f} ({100 * dec / total:.0f}%) | "
                  + "/".join(str(nxt[k]) for k in ["new", "same_result", "repeat", "error", "text", "capped"]) + " |")
        print("\n| classe do passo | passos | think médio | decode s (%) | em entradas certas |")
        print("|---|---|---|---|---|")
        by_kind = defaultdict(list)
        for s in rows:
            by_kind[s["kind"]].append(s)
        for kind, ss in sorted(by_kind.items(), key=lambda x: -len(x[1])):
            dec = sum(s["decode_s"] for s in ss)
            print(f"| {kind} | {len(ss)} | {sum(s['think'] for s in ss) / len(ss):.0f} | {dec:.0f} ({100 * dec / total:.0f}%) | "
                  f"{sum(s['ok'] for s in ss)} |")
        # Raciocínio longo compra progresso? Classe do passo por faixa de think.
        print("\n| think do passo | passos | new | same/repeat/error | text | capped |")
        print("|---|---|---|---|---|---|")
        for lo, hi in [(0, 64), (64, 128), (128, 256), (256, 512), (512, 2048)]:
            ss = [s for s in rows if lo <= s["think"] < hi]
            c = Counter(s["kind"] for s in ss)
            if ss:
                print(f"| {lo}–{hi} | {len(ss)} | {c['new']} | {c['same_result'] + c['repeat'] + c['error']} | "
                      f"{c['text']} | {c['capped']} |")
    Path(BASE / "paca-signals.json").write_text(json.dumps(
        [s for run in runs for cond in conds for s in steps_of(run, cond)]))


if __name__ == "__main__":
    main()
