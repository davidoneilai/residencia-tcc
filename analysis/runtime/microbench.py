"""Microbenchmarks de runtime no iPhone sobre prompts reais do DEV (corpos gravados pelo InferenceServer).

    .bfcl-venv/bin/python analysis/runtime/microbench.py draft  <requests.json> <saida.jsonl> [índices]
    .bfcl-venv/bin/python analysis/runtime/microbench.py prefix <requests.json> <saida.jsonl> [índices]

`requests.json`: lista de {req, id, turn, step} (corpo OpenAI exato de cada passo, ver `serve-requests.jsonl`).
- draft: cada passo roda com `grammar_draft` desligado e ligado (ordem alternada), os dois a partir do mesmo estado
  (só system + tools em memória: `POST /v1/debug/reset {"keep_system": true}`). Compara texto e chamadas.
- prefix: 1º passo de cada tarefa em três condições: atual (sem persistência, prefixo refeito), persistente frio
  (miss: refaz e grava) e persistente quente (lê do disco). Antes de cada uma, os KV em memória são apagados.
"""
import json
import os
import sys
import time
import urllib.request

# `IPHONE_URL` fixa um endereço quando o nome mDNS resolve para endereços sem rota (ex.: o IPv6 do cabo USB,
# `http://[fe80::…%en9]:8080`); o `bfcl.py` usa `OPENAI_BASE_URL` com o mesmo endereço + `/v1`.
URL = os.environ.get("IPHONE_URL", "http://iPhone-de-David.local:8080")


def post(path, body, timeout=900):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def thermal():
    with urllib.request.urlopen(URL + "/health", timeout=10) as r:
        return json.loads(r.read()).get("thermal")


def cool(limit=600, tick=None):
    """Espera a térmica sair de serious/critical (até `limit` s). `tick(waited, thermal)` a cada 20 s de espera."""
    waited = 0
    while (state := thermal()) in ("serious", "critical") and waited < limit:
        if tick:
            tick(waited, state)
        time.sleep(20)
        waited += 20
    return waited


def calls(message):
    return [(c["function"]["name"], json.loads(c["function"]["arguments"])) for c in message.get("tool_calls") or []]


def run(req, **flags):
    body = {**req, **flags}
    started = time.time()
    out = post("/v1/chat/completions", body)
    client = time.time() - started
    msg = out["choices"][0]["message"]
    d = out["device"]
    return {"client_s": client, "calls": calls(msg), "raw": d.get("raw_text"), "out": out["usage"]["completion_tokens"],
            "prompt": out["usage"]["prompt_tokens"],
            **{k: d.get(k) for k in ["ttft_ms", "prefill_ms", "prefill_tokens", "decode_ms", "latency_ms", "peak_memory_mb",
                                     "prefix_source", "prefix_load_ms", "prefix_save_ms", "prefix_build_ms",
                                     "reused_from", "thermal_before", "thermal_after", "forced_close", "think_tokens",
                                     "draft_passes", "draft_verify_passes", "draft_proposed", "draft_accepted",
                                     "draft_full_accepts", "draft_refeeds", "draft_refeed_tokens", "draft_grammar_ms", "draft_wait_ms"]}}


def main():
    mode, src, dst = sys.argv[1:4]
    items = json.load(open(src))
    idx = [int(x) for x in sys.argv[4].split(",")] if len(sys.argv) > 4 else range(len(items))
    with open(dst, "a") as f:
        for n, i in enumerate(idx):
            it = items[i]
            base = {k: v for k, v in it["req"].items() if k not in ("grammar_draft", "persist_prefix")}
            waited = cool()
            rows = []
            if mode == "draft":
                order = [False, True] if n % 2 == 0 else [True, False]
                for flag in order:
                    post("/v1/debug/reset", {"keep_system": True})
                    rows.append({"cond": "draft" if flag else "base", **run(base, grammar_draft=flag)})
            else:
                post("/v1/debug/reset", {"disk": True})
                rows.append({"cond": "current", **run(base)})
                post("/v1/debug/reset", {})
                rows.append({"cond": "persist-cold", **run(base, persist_prefix=True)})
                post("/v1/debug/reset", {})
                rows.append({"cond": "persist-warm", **run(base, persist_prefix=True)})
            ref = rows[0]
            for r in rows:
                r.update({"mode": mode, "index": i, "id": it["id"], "turn": it["turn"], "step": it["step"], "cooled_s": waited,
                          "same_text": r["raw"] == ref["raw"], "same_calls": r["calls"] == ref["calls"]})
                f.write(json.dumps(r) + "\n")
                f.flush()
            print(i, it["id"][16:], it["turn"], it["step"], " | ".join(
                f"{r['cond']}: out {r['out']} dec {r['decode_ms'] / 1000:.1f}s ttft {r['ttft_ms'] / 1000:.2f}s "
                f"{r['prefix_source']} acc {r.get('draft_accepted')}/{r.get('draft_proposed')} "
                f"ref {r.get('draft_refeeds')} {'=' if r['same_text'] and r['same_calls'] else '≠'}" for r in rows), flush=True)


if __name__ == "__main__":
    main()
