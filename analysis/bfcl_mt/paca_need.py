"""O conteúdo do passo prediz quanto raciocínio ele precisa? Análise offline dos logs DEV (sem iPhone).

    .bfcl-venv/bin/python analysis/bfcl_mt/paca_need.py [rodada ...] [--conds a,b]

Alvo: raciocínio natural (fechou sozinho, sem teto/budget) > `LONG` tokens; o estouro (teto ou fechado à força) fica à
parte. Sinais:
- pós-hoc (só para entender a necessidade): de onde vêm os argumentos das chamadas que o passo emitiu — do pedido do
  usuário, de resultados de ferramentas anteriores ou de nenhum dos dois (valor calculado/novo);
- pré-passo (o que um controlador vê antes de gerar): posição no turno, tamanho do pedido, números no pedido,
  resultados de ferramenta no turno, números nesses resultados, erro no último resultado.
Para cada sinal pré-passo: AUC contra o alvo e a fração dos passos longos que um limiar simples capturaria.
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from analyze_dac import BASE, FILE, SLM, last_attempt, read_jsonl  # noqa: E402
from controller import is_error  # noqa: E402
from paca_signals import think_tokens  # noqa: E402

LONG = 128
NUM = re.compile(r"-?\d+(?:\.\d+)?")


def scalars(x):
    if isinstance(x, dict):
        for v in x.values():
            yield from scalars(v)
    elif isinstance(x, list):
        for v in x:
            yield from scalars(v)
    elif x is not None and not isinstance(x, bool):
        yield x


def norm(v):
    s = str(v).strip().lower()
    try:
        f = float(s)
        return f"{f:g}"
    except ValueError:
        return s


def bag(text):
    """Valores que um texto contém: números normalizados e o texto em minúsculas para busca de strings."""
    text = str(text)
    return {norm(n) for n in NUM.findall(text)}, text.lower()


def source(value, user, tools):
    v = norm(value)
    if not v:
        return "user"
    numeric = bool(NUM.fullmatch(str(value).strip()))
    in_user = v in user[0] if numeric else v in user[1]
    in_tools = v in tools[0] if numeric else v in tools[1]
    if in_user:
        return "user"
    return "tool" if in_tools else "new"


def steps(run, cond):
    root = BASE / run
    model = f"iphone-{SLM}-dac-{cond}"
    res, score = root / "result" / model / FILE.format("result"), root / "score" / model / FILE.format("score")
    if not res.exists():
        return []
    fails = {json.loads(l)["id"] for l in score.read_text().splitlines()[1:] if l.strip()} if score.exists() else set()
    trace = last_attempt(read_jsonl(root / "trace.jsonl"))
    out = []
    for line in res.read_text().splitlines():
        r = json.loads(line)
        if "latency" not in r:
            continue
        rows = {(t["turn"], t["step"]): t for t in trace.get((cond, r["id"]), [])}
        user_text, tool_text = "", ""
        for ti, turn in enumerate(x for x in r["inference_log"] if isinstance(x, dict)):
            query = " ".join(m["content"] for m in turn.get("begin_of_turn_query", []) if m.get("role") == "user")
            user_text += " " + query
            turn_results = []
            keys = sorted((k for k in turn if k.startswith("step_")), key=lambda k: int(k[5:]))
            for si, k in enumerate(keys):
                t = rows.get((ti, int(k[5:])))
                msgs = turn[k]
                content = next((m["content"] for m in msgs if m["role"] == "assistant"), "")
                results = [str(m["content"]) for m in msgs if m["role"] == "tool"]
                th = think_tokens(t) if t is not None else None
                if th is not None:
                    dev = t["device"]
                    runaway = t.get("finish") == "length" and "</think>" not in (dev.get("raw_text") or "") \
                        or bool(dev.get("forced_close"))
                    srcs = []
                    if isinstance(content, list):
                        ub, tb = bag(user_text), bag(tool_text)
                        for c in content:
                            for _, a in c.items():
                                try:
                                    args = json.loads(a) if a else {}
                                except ValueError:
                                    args = {}
                                srcs += [source(v, ub, tb) for v in scalars(args)]
                    last_res = turn_results[-1] if turn_results else ""
                    out.append({
                        "run": run, "cond": cond, "id": r["id"], "ok": r["id"] not in fails, "turn": ti, "step": si,
                        "think": th, "runaway": runaway, "long": (not runaway) and th > LONG,
                        "has_call": isinstance(content, list) and bool(content),
                        "args_tool": srcs.count("tool"), "args_new": srcs.count("new"), "args_user": srcs.count("user"),
                        # Pré-passo:
                        "first": si == 0, "query_chars": len(query), "query_nums": len(NUM.findall(query)),
                        "turn_results": len(turn_results), "result_nums": len(NUM.findall(last_res)),
                        "result_chars": len(last_res), "last_error": bool(last_res) and is_error(last_res),
                        "turn_index": ti,
                    })
                turn_results += results
                tool_text += " " + " ".join(results)
    return out


def auc(pos, neg):
    if not pos or not neg:
        return float("nan")
    wins = sum((p > n) + 0.5 * (p == n) for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def main():
    args = sys.argv[1:]
    conds = ["dacs-kv"]
    if "--conds" in args:
        i = args.index("--conds"); conds = args[i + 1].split(","); del args[i:i + 2]
    runs = args or ["r1", "r2", "r3"]
    rows = [s for run in runs for c in conds for s in steps(run, c)]
    nat = [s for s in rows if not s["runaway"]]
    longs = [s for s in nat if s["long"]]
    print(f"{len(rows)} passos ({', '.join(conds)}; {', '.join(runs)}): {len(longs)} longos (>{LONG}, naturais), "
          f"{sum(s['runaway'] for s in rows)} estouros, {len(nat) - len(longs)} curtos")

    print("\n## Pós-hoc: de onde vêm os argumentos × raciocínio (passos naturais com chamada)")
    print("| argumentos do passo | passos | longos | think médio |")
    print("|---|---|---|---|")
    groups = defaultdict(list)
    for s in nat:
        if not s["has_call"]:
            groups["sem chamada (texto)"].append(s)
        elif s["args_new"]:
            groups["algum valor novo (calculado)"].append(s)
        elif s["args_tool"]:
            groups["algum valor de resultado de tool"].append(s)
        else:
            groups["só valores do pedido / sem args"].append(s)
    for g, ss in groups.items():
        print(f"| {g} | {len(ss)} | {sum(x['long'] for x in ss)} | {sum(x['think'] for x in ss) / len(ss):.0f} |")

    print("\n## Pré-passo: o sinal separa os passos longos? (passos naturais)")
    print("| sinal | AUC | longos com sinal alto (≥ mediana dos longos) / passos com sinal alto |")
    print("|---|---|---|")
    for key in ["first", "query_chars", "query_nums", "turn_results", "result_nums", "result_chars", "last_error",
                "turn_index"]:
        pos = [float(s[key]) for s in longs]
        neg = [float(s[key]) for s in nat if not s["long"]]
        cut = sorted(pos)[len(pos) // 2] if pos else 0
        hi = [s for s in nat if float(s[key]) >= cut]
        print(f"| {key} | {auc(pos, neg):.2f} | {sum(s['long'] for s in hi)}/{len(hi)} (limiar {cut:g}) |")

    print("\n## Estouros: onde acontecem")
    for s in rows:
        if s["runaway"]:
            print(f"- {s['run']} {s['id'][16:]} t{s['turn']} s{s['step']} think={s['think']} first={s['first']} "
                  f"query_nums={s['query_nums']} turn_results={s['turn_results']} ok={s['ok']}")
    Path(BASE / "paca-need.json").write_text(json.dumps(rows))


if __name__ == "__main__":
    main()
