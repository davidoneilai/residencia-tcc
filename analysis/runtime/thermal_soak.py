"""Decode contínuo no iPhone por N minutos: tok/s de decode e térmica por requisição (teste 3 do PLAN-sota.md).

    IPHONE_URL=http://127.0.0.1:18080 python3 analysis/runtime/thermal_soak.py <modelo> <minutos> <saída.jsonl>

Uma requisição longa atrás da outra (768 tokens, sem pausa de resfriamento), para ver quanto o decode cai quando o
aparelho esquenta. tok/s = tokens gerados / tempo de decode medido no servidor.
"""
import json
import os
import sys
import time
import urllib.request

URL = os.environ.get("IPHONE_URL", "http://iPhone-de-David.local:8080")
PROMPT = ("Write a long, detailed, step-by-step explanation of how a city water treatment plant works, "
          "covering every stage in depth. Do not stop early.")


def main():
    model, minutes, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    started = time.time()
    with open(out, "w") as f:
        while time.time() - started < minutes * 60:
            body = json.dumps({"model": model, "messages": [{"role": "user", "content": PROMPT}],
                               "max_tokens": 768}).encode()
            req = urllib.request.Request(URL + "/v1/chat/completions", data=body,
                                         headers={"Content-Type": "application/json"})
            resp = json.loads(urllib.request.urlopen(req, timeout=900).read())
            d, tokens = resp["device"], resp["usage"]["completion_tokens"]
            row = {"elapsed_s": round(time.time() - started), "tokens": tokens, "decode_ms": d.get("decode_ms"),
                   "tok_s": round(tokens / (d["decode_ms"] / 1000), 2) if d.get("decode_ms") else None,
                   "thermal_before": d.get("thermal_before"), "thermal_after": d.get("thermal_after")}
            f.write(json.dumps(row) + "\n")
            f.flush()
            print(row, flush=True)


if __name__ == "__main__":
    main()
