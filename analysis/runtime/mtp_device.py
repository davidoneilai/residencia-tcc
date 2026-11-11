"""Especulação MTP no iPhone contra o decode atual, sobre passos reais do DEV (requisições gravadas).

    IPHONE_URL=http://127.0.0.1:18080 python3 analysis/runtime/mtp_device.py <requests.json> <saída.jsonl> \\
        <índices> <condições> [modelo]

Condições: `0` = sem MTP; `2`, `3`… = `mtp_block` (iterador da biblioteca: 1, 2… rascunhos); `full` / `subset` =
`mtp_pipe` (iterador próprio em pipeline, vocabulário inteiro ou reduzido), com `+N` opcional para `mtp_top` e
`@N` para `mtp_context` e `~P` para `mtp_gate` (ex.: `subset+4096@256~0.6`).
Para cada passo e cada condição, roda a mesma requisição com as
opções da pilha (`think_budget` 512, `repeat_guard`, prefixo persistente), com o mesmo estado de partida: KV em
memória apagados e o prefixo vindo do disco. Ordem das condições alternada entre passos; espera térmica antes de
cada execução. Compara texto e chamadas com o bloco 0 (greedy: têm de ser idênticos) e registra decode, tok/s e a
aceitação da MTP (`mtp_proposed`/`mtp_accepted` do servidor).
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from microbench import calls, cool, post  # noqa: E402


def options(condition):
    """Campos do corpo para uma condição (ver o docstring)."""
    if condition == "0":
        return {}
    if condition.isdigit():
        return {"mtp_block": int(condition)}
    condition, _, gate = condition.partition("~")
    condition, _, context = condition.partition("@")
    pipe, _, top = condition.partition("+")
    return {"mtp_pipe": pipe, **({"mtp_context": int(context)} if context else {}),
            **({"mtp_top": int(top)} if top else {}), **({"mtp_gate": float(gate)} if gate else {})}


def main():
    items = json.loads(Path(sys.argv[1]).read_text())
    out_path, indices = Path(sys.argv[2]), [int(i) for i in sys.argv[3].split(",")]
    blocks = sys.argv[4].split(",")
    model = sys.argv[5] if len(sys.argv) > 5 else "qwen35:direct:kv"
    with out_path.open("a") as out:
        for n, index in enumerate(indices):
            req = {**items[index]["req"], "model": model, "think_budget": 512, "repeat_guard": True,
                   "persist_prefix": True}
            order = blocks[n % len(blocks):] + blocks[:n % len(blocks)]
            # Garante o prefixo no disco antes das condições medidas.
            post("/v1/debug/reset", {})
            post("/v1/chat/completions", {**req, "max_tokens": 1})
            reference = {}
            for block in order:
                waited = cool()
                post("/v1/debug/reset", {})
                body = {**req, **options(block)}
                resp = post("/v1/chat/completions", body)
                d = resp["device"]
                tokens = resp["usage"]["completion_tokens"]
                row = {"index": index, "block": block, "cooled_s": waited, "tokens": tokens,
                       "decode_ms": d.get("decode_ms"), "latency_ms": d.get("latency_ms"),
                       "tok_s": round(tokens / (d["decode_ms"] / 1000), 2) if d.get("decode_ms") else None,
                       "mtp_proposed": d.get("mtp_proposed"), "mtp_accepted": d.get("mtp_accepted"),
                       "mtp_wasted_rounds": d.get("mtp_wasted_rounds"), "mtp_replays": d.get("mtp_replays"),
                       "mtp_wait_ms": d.get("mtp_wait_ms"), "mtp_prefill_ms": d.get("mtp_prefill_ms"),
                       "mtp_synced": d.get("mtp_synced"), "mtp_proposed_by_conf": d.get("mtp_proposed_by_conf"),
                       "mtp_accepted_by_conf": d.get("mtp_accepted_by_conf"),
                       "prefix_source": d.get("prefix_source"), "forced_close": d.get("forced_close"),
                       "thermal_after": d.get("thermal_after"), "raw": d.get("raw_text"),
                       "calls": calls(resp["choices"][0]["message"])}
                reference[block] = row
                out.write(json.dumps(row, ensure_ascii=False) + "\n")
                out.flush()
            base = reference.get("0")
            for block, row in reference.items():
                same = base is not None and row["raw"] == base["raw"] and row["calls"] == base["calls"]
                print(index, block, {k: row[k] for k in ("tokens", "tok_s", "decode_ms", "mtp_proposed",
                                                          "mtp_accepted", "prefix_source", "forced_close")},
                      "igual ao sem MTP:", same, flush=True)


if __name__ == "__main__":
    main()
