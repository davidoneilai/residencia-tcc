"""Anatomia do decode e teto do rascunho por cópia do contexto (prompt lookup), sobre logs gravados. Sem iPhone.

    <venv com mlx-lm>/bin/python -I analysis/runtime/decode_anatomy.py <tokenizer dir> <saída.json> \\
        <serve-requests.jsonl> <serve-log.jsonl> <início UTC> <fim UTC> <modelo> [persist]

Os dois logs ficam em Documents do app: `serve-requests.jsonl` (corpo de cada requisição) e `serve-log.jsonl`
(resposta: `raw_text`, `tool_calls` com argumentos, `completion_tokens`), ambos com a hora em UTC. O servidor atende
uma requisição por vez, então cada resposta casa com a última requisição anterior a ela. `<modelo>` filtra pelo
campo `model` da resposta (ex. `Qwen3.5-2B-4bit`); `persist` exige `persist_prefix` (pilha).

Os dois logs só guardam o nome das chamadas; os argumentos vêm da mensagem do assistente no histórico da requisição
seguinte da mesma conversa. Passos com chamada sem essa continuação (o último de cada tarefa) ficam de fora e são
contados em `steps_without_call_args`.

Para cada passo, a saída do modelo é reconstruída como ele a gerou: o `raw_text` (raciocínio, `</think>`, texto) mais
as chamadas no XML do template (`<tool_call>\\n<function=…>\\n<parameter=…>\\n…`), que o parser do stream consome.
Partes: raciocínio (até `</think>`), chamadas e texto final.

Rascunho por cópia: a cada passada, procura a última ocorrência anterior do sufixo de `n` tokens já gerados no
contexto do passo (mensagens: usuário, resultados de ferramentas e turnos anteriores; o catálogo de ferramentas fica de
fora, então é um piso) e no próprio texto gerado, e propõe os `k` tokens seguintes. Greedy: aceita enquanto for igual
ao que o modelo gerou. Tempo com o custo medido de uma passada no iPhone 16 Pro (`results/runtime/forward-cost.json`,
Qwen3.5, contexto 6,6k): sem proposta custa forward(1); com proposta de `m` tokens custa forward(1 + m).
"""
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

from transformers import AutoTokenizer

ROOT = Path(__file__).resolve().parents[2]
COST = {r["tokens"]: r["median_ms"] for r in json.loads((ROOT / "results/runtime/forward-cost.json").read_text())["rows"]}
SETTINGS = ((2, 2), (3, 2), (3, 3), (4, 4))


def when(row):
    return datetime.fromisoformat(row["time"].rstrip("Z"))


def context_text(messages):
    parts = []
    for m in messages:
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(x.get("text", "") if isinstance(x, dict) else str(x) for x in c)
        if c:
            parts.append(str(c))
        for call in m.get("tool_calls") or []:
            parts.append(json.dumps(call.get("function", call), ensure_ascii=False))
    return "\n".join(parts)


def call_xml(calls):
    """Chamadas como o template do Qwen3.5/LFM3 as escreve."""
    blocks = []
    for call in calls:
        f = call.get("function", call)
        args = f.get("arguments") or {}
        if isinstance(args, str):
            args = json.loads(args or "{}")
        body = "".join(f"<parameter={k}>\n{v if isinstance(v, str) else json.dumps(v)}\n</parameter>\n"
                       for k, v in args.items())
        blocks.append(f"<tool_call>\n<function={f['name']}>\n{body}</function>\n</tool_call>")
    return "\n".join(blocks)


def lookup(ctx, out, n, k):
    """(passadas, tokens aceitos, ms) do rascunho por sufixo de `n` tokens, até `k` propostos por passada."""
    seq, last = list(ctx), {}
    for p in range(n, len(seq)):
        last[tuple(seq[p - n:p])] = p  # continuação começa em p (sempre antes do fim)
    i, passes, accepted, ms = 0, 0, 0, 0.0
    while i < len(out):
        start = last.get(tuple(seq[-n:])) if len(seq) >= n else None
        proposal = seq[start:start + k] if start is not None else []
        good = 0
        while good < len(proposal) and i + good < len(out) and out[i + good] == proposal[good]:
            good += 1
        ms += COST.get(1 + len(proposal), COST[max(COST)])
        for t in out[i:i + good + 1]:
            if len(seq) >= n:
                last[tuple(seq[-n:])] = len(seq)
            seq.append(t)
        i += good + 1
        passes += 1
        accepted += good
    return passes, accepted, ms


def pairs(requests_log, serve_log, start, end, model, persist):
    reqs = [json.loads(line) for line in open(requests_log)]
    reqs = [r for r in reqs if start <= when(r) <= end]
    out, j = [], 0
    for line in open(serve_log):
        resp = json.loads(line)
        t = when(resp)
        if not (start <= t <= end) or model not in resp.get("model", "") or (persist and not resp.get("persist_prefix")):
            continue
        while j + 1 < len(reqs) and when(reqs[j + 1]) <= t:
            j += 1
        if reqs and when(reqs[j]) <= t:
            out.append((reqs[j]["request"], resp))
    return out


def main():
    tok = AutoTokenizer.from_pretrained(sys.argv[1])
    out_path = Path(sys.argv[2])
    start, end = datetime.fromisoformat(sys.argv[5]), datetime.fromisoformat(sys.argv[6])
    rows = pairs(sys.argv[3], sys.argv[4], start, end, sys.argv[7], len(sys.argv) > 8 and sys.argv[8] == "persist")
    totals, per = defaultdict(float), []
    for index, (req, resp) in enumerate(rows):
        # Os argumentos das chamadas só aparecem no histórico da requisição seguinte (mensagem do assistente).
        n_msgs = len(req["messages"])
        nxt = rows[index + 1][0]["messages"] if index + 1 < len(rows) else []
        assistant = nxt[n_msgs] if len(nxt) > n_msgs and nxt[:n_msgs] == req["messages"] else None
        if resp.get("tool_calls") and not (assistant and assistant.get("role") == "assistant"):
            totals["steps_without_call_args"] += 1
            continue
        raw = resp.get("raw_text") or ""
        think, sep, rest = raw.partition("</think>")
        if not sep:
            think, rest = "", raw
        calls = call_xml((assistant or {}).get("tool_calls") or []) if resp.get("tool_calls") else ""
        parts = {"think": think + sep, "text": rest, "call": calls}
        ids = {k: tok.encode(v, add_special_tokens=False) for k, v in parts.items()}
        out = ids["think"] + ids["text"] + ids["call"]
        ctx = tok.encode(context_text(req["messages"]), add_special_tokens=False)
        row = {"time": resp["time"], **{f"{k}_tokens": len(v) for k, v in ids.items()}, "out_tokens": len(out),
               "completion_tokens": resp.get("completion_tokens"), "base_ms": len(out) * COST[1]}
        for n, k in SETTINGS:
            p, a, ms = lookup(ctx, out, n, k)
            row.update({f"pld_n{n}_k{k}_passes": p, f"pld_n{n}_k{k}_accepted": a, f"pld_n{n}_k{k}_ms": ms})
            # Só nas chamadas: quanto o rascunho aceitaria dentro do bloco `<tool_call>`.
            pc, ac, _ = lookup(ctx + ids["think"] + ids["text"], ids["call"], n, k)
            row.update({f"pld_n{n}_k{k}_call_accepted": ac})
        per.append(row)
        for key, value in row.items():
            if isinstance(value, (int, float)):
                totals[key] += value
    s = {"steps": len(per), **{k: round(v) for k, v in totals.items()}}
    for k in ("think", "text", "call"):
        s[f"share_{k}"] = round(totals[f"{k}_tokens"] / max(totals["out_tokens"], 1), 3)
    for n, k in SETTINGS:
        p = f"pld_n{n}_k{k}"
        s[f"{p}_accept_rate"] = round(totals[f"{p}_accepted"] / max(totals["out_tokens"], 1), 3)
        s[f"{p}_call_accept_rate"] = round(totals[f"{p}_call_accepted"] / max(totals["call_tokens"], 1), 3)
        s[f"{p}_tokens_per_pass"] = round(totals["out_tokens"] / max(totals[f"{p}_passes"], 1), 3)
        s[f"{p}_decode_speedup_est"] = round(totals["base_ms"] / max(totals[f"{p}_ms"], 1), 3)
    out_path.write_text(json.dumps({"summary": s, "steps": per}, ensure_ascii=False, indent=1))
    print(json.dumps(s, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
