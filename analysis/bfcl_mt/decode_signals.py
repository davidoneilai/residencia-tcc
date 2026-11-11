"""Sinais observáveis durante o decode do raciocínio (offline, sobre o `raw_text` completo do servidor).

    .bfcl-venv/bin/python analysis/bfcl_mt/decode_signals.py <rodada> <condição>

Para cada passo LLM, tokeniza o raciocínio (antes de `</think>`) com o tokenizer do Qwen3.5 e marca, por posição:
- decisão: primeiro token em que todas as funções que o passo chamou de fato já foram citadas no raciocínio;
- hesitação: marcadores de autocorreção ("Wait", "Actually", "let me check again", ...);
- repetição: 8-gramas de tokens e frases (normalizadas) que já tinham saído no mesmo raciocínio;
- outras funções do catálogo citadas depois da decisão (o plano mudou?).
Resposta: tokens de texto (depois de `</think>`) e de chamadas (saída − raciocínio − texto; o parser do MLX tira as
chamadas do texto). Custo em segundos pelo decode do passo.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

from tokenizers import Tokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_dac import BASE, FILE, SLM, last_attempt, read_jsonl  # noqa: E402

TOK = Tokenizer.from_file(str(next(Path.home().glob(
    ".cache/huggingface/hub/models--mlx-community--Qwen3.5-2B-4bit/snapshots/*/tokenizer.json"))))
DOCS = Path(sys.prefix) / "lib/python3.12/site-packages/bfcl_eval/data/multi_turn_func_doc"
CATALOG = {json.loads(l)["name"] for f in DOCS.glob("*.json") for l in f.read_text().splitlines() if l.strip()}
HESITATE = re.compile(r"\b(wait|actually|hmm|hold on|let me (?:re-?read|reconsider|check again|verify|think again)|"
                      r"on second thought|i made a mistake|but (?:wait|actually)|let me re-?check)\b", re.I)
N = 8


GENERIC = {"get", "set", "list", "all", "by", "the", "info", "details", "id", "of", "for", "to", "and", "a"}
WORD = re.compile(r"[A-Za-z]+")


def keys(name):
    """Radicais (4 letras) das palavras do nome que não são genéricas: place_order → {plac, orde}."""
    parts = re.sub(r"([a-z])([A-Z])", r"\1_\2", name).lower().split("_")
    return {w[:4] for w in parts if w and w not in GENERIC} or {parts[0][:4]}


def mentions(text, offsets, names, window=10):
    """Posição (token) da primeira menção de cada função: o nome exato ou todos os radicais a ≤ `window` palavras."""
    words = [(m.group().lower()[:4], m.end()) for m in WORD.finditer(text)]
    first = {}
    for name in names:
        exact = re.search(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", text)
        end = exact.end() if exact else None
        need = keys(name)
        for i in range(len(words)):
            found, last = set(), None
            for w, e in words[i:i + window]:
                if w in need and w not in found:
                    found.add(w); last = e
                if found == need:
                    break
            if found == need and words[i][0] in need:
                end = last if end is None else min(end, last)
                break
        if end is not None:
            first[name] = next((k for k, (a, b) in enumerate(offsets) if b >= end), len(offsets))
    return first


def scalars(x):
    if isinstance(x, dict):
        for v in x.values():
            yield from scalars(v)
    elif isinstance(x, list):
        for v in x:
            yield from scalars(v)
    elif x is not None and not isinstance(x, bool):
        yield x


def arg_ready(think, offsets, args):
    """Posição em que o último valor de argumento (que aparece no raciocínio) foi escrito pela 1ª vez; e quantos
    valores aparecem. Números comparados como número (227.16 casa com $227.16)."""
    pos, found = [], 0
    for v in args:
        sv = str(v)
        if isinstance(v, (int, float)):
            pat = r"(?<![\d.])" + re.escape(f"{v:g}" if isinstance(v, float) else sv) + r"(?![\d])"
        else:
            if len(sv) < 2:
                continue
            pat = re.escape(sv)
        m = re.search(pat, think, re.I)
        if m:
            found += 1
            pos.append(next((k for k, (a, b) in enumerate(offsets) if b >= m.end()), len(offsets)))
    return (max(pos) if pos else None), found


def analyse(text, called, out, args=()):
    think, _, answer = text.partition("</think>")
    enc = TOK.encode(think, add_special_tokens=False)
    ids, offs = enc.ids, enc.offsets
    T = len(ids)
    first = mentions(think, offs, CATALOG)
    decision = max((first[n] for n in called), default=None) if called and all(n in first for n in called) else None
    args = list(args)
    apos, afound = arg_ready(think, offs, args)
    ready = max(decision, apos) if decision is not None and apos is not None else decision
    hes = [next((i for i, (a, b) in enumerate(offs) if b > m.start()), T) for m in HESITATE.finditer(think)]
    seen, rep = set(), []
    for i in range(T - N + 1):
        g = tuple(ids[i:i + N])
        if g in seen:
            rep.append(i + N - 1)
        seen.add(g)
    sent_seen, sent_rep = set(), []
    for m in re.finditer(r"[^.\n!?]{25,}[.\n!?]", think):
        s = re.sub(r"\W+", " ", m.group().lower()).strip()
        if s in sent_seen:
            sent_rep.append(next((i for i, (a, b) in enumerate(offs) if b > m.start()), T))
        sent_seen.add(s)
    others_after = sorted({n for n, p in first.items() if decision is not None and p > decision and n not in called})
    # O parser de tool calls do MLX tira as chamadas do texto: elas são o resto da saída.
    text_tok = len(TOK.encode(answer, add_special_tokens=False).ids)
    calls_tok = max(0, out - T - 1 - text_tok) if called else 0
    return {"think": T, "decision": decision, "ready": ready, "args_total": len(args), "args_in_think": afound, "hes": hes, "rep8": rep, "rep_sent": sent_rep,
            "others_after": others_after, "calls_tok": calls_tok, "text_tok": text_tok,
            "closed": "</think>" in text}


def main():
    run, cond = sys.argv[1], sys.argv[2]
    root = BASE / run
    model = f"iphone-{SLM}-dac-{cond}"
    score = root / "score" / model / FILE.format("score")
    fails = {json.loads(l)["id"] for l in score.read_text().splitlines()[1:] if l.strip()} if score.exists() else set()
    trace = last_attempt(read_jsonl(root / "trace.jsonl"))
    emitted = {}
    res = root / "result" / model / FILE.format("result")
    for line in (res.read_text().splitlines() if res.exists() else []):
        r = json.loads(line)
        for ti, turn in enumerate(x for x in r.get("inference_log", []) if isinstance(x, dict)):
            for k, msgs in turn.items():
                if not k.startswith("step_"):
                    continue
                content = next((m["content"] for m in msgs if m["role"] == "assistant"), "")
                vals = []
                if isinstance(content, list):
                    for c in content:
                        for _, a in c.items():
                            try:
                                vals += list(scalars(json.loads(a) if a else {}))
                            except ValueError:
                                pass
                emitted[r["id"], ti, int(k[5:])] = vals
    rows = []
    for (c, entry), steps in sorted(trace.items()):
        if c != cond:
            continue
        for t in steps:
            dev = t["device"]
            out = t.get("completion_tokens") or 1
            a = analyse(dev.get("raw_text") or "", list(dict.fromkeys(t.get("calls") or [])), out,
                        emitted.get((entry, t["turn"], t["step"]), []))
            a.update({"id": entry[16:], "ok": entry not in fails, "turn": t["turn"], "step": t["step"],
                      "calls": t.get("calls"), "forced": bool(dev.get("forced_close")),
                      "server_think": dev.get("think_tokens"), "out": out,
                      "s_per_tok": dev.get("decode_ms", 0) / 1000 / out, "client_s": t.get("client_s", 0),
                      "decode_s": dev.get("decode_ms", 0) / 1000})
            rows.append(a)
    (root / "decode-signals.json").write_text(json.dumps(rows))

    print(f"{len(rows)} passos; {sum(r['forced'] for r in rows)} com raciocínio fechado à força; "
          f"tokenizer vs servidor (think): {sum(abs(r['think'] - (r['server_think'] or r['think'])) for r in rows)} "
          "tokens de diferença no total")
    print("\n| entrada | t.s | ok | think | forçado | decisão em | pós-decisão | hesitações (posições) | 8-gramas rep. "
          "(1ª pos.) | frases rep. | outras funções depois | args prontos em (achados/total) | pós-pronto | chamadas |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        post = r["think"] - r["decision"] if r["decision"] is not None else None
        print(f"| {r['id']} | {r['turn']}.{r['step']} | {'✓' if r['ok'] else '✗'} | {r['think']} | "
              f"{'sim' if r['forced'] else ''} | {r['decision'] if r['decision'] is not None else '—'} | "
              f"{post if post is not None else '—'} | {len(r['hes'])} {r['hes'][:4]} | "
              f"{len(r['rep8'])} ({r['rep8'][0] if r['rep8'] else '—'}) | {len(r['rep_sent'])} | "
              f"{', '.join(r['others_after'][:3])} | "
              f"{r['ready'] if r['ready'] is not None else '—'} ({r['args_in_think']}/{r['args_total']}) | "
              f"{r['think'] - r['ready'] if r['ready'] is not None else '—'} | {', '.join(r['calls'] or []) or 'texto'} |")

    total = sum(r["client_s"] for r in rows)
    dec = sum(r["decode_s"] for r in rows)
    think_s = sum(r["think"] * r["s_per_tok"] for r in rows)
    calls_s = sum(r["calls_tok"] * r["s_per_tok"] for r in rows)
    text_s = sum(r["text_tok"] * r["s_per_tok"] for r in rows)
    post_s = sum(max(0, r["think"] - r["decision"]) * r["s_per_tok"] for r in rows if r["decision"] is not None)
    print(f"\nTempo total (cliente) {total:.0f} s; decode {dec:.0f} s ({100 * dec / total:.0f}%): "
          f"raciocínio {think_s:.0f} s, chamadas {calls_s:.0f} s, texto {text_s:.0f} s.")
    ready_s = sum(max(0, r["think"] - r["ready"]) * r["s_per_tok"] for r in rows if r["ready"] is not None)
    print(f"Raciocínio depois de citar as funções: {post_s:.0f} s ({100 * post_s / total:.0f}% do total); "
          f"depois de funções e argumentos prontos (teto de 'fechar ao decidir'): {ready_s:.0f} s "
          f"({100 * ready_s / total:.0f}%).")
    with_call = [r for r in rows if r["calls"]]
    print(f"Passos com chamada: {len(with_call)}; decisão localizada em {sum(r['decision'] is not None for r in with_call)}.")


if __name__ == "__main__":
    main()
