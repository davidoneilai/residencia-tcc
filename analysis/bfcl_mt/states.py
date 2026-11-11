"""Custo de raciocínio por estado da trajetória (parte 3 do estudo DAC), a partir de resultados já gravados.

    .bfcl-venv/bin/python analysis/bfcl_mt/states.py <dir result/<modelo>> [dev|test]
Estado do passo: 1º do turno, depois de resultado ok, depois de erro, depois de chamada repetida.
Para cada estado: passos, tokens gerados (média e p90), quantos bateram no teto, quantos terminaram em texto.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

ERROR_CUES = ("error", "not found", "invalid", "does not exist", "no such", "failed", "unable", "cannot",
              "not allowed", "denied", "warning", "insufficient")
SLICE = Path(__file__).resolve().parents[2] / "results" / "bfcl-mt" / "slice.json"


def main():
    path = Path(sys.argv[1]) / "multi_turn" / "BFCL_v4_multi_turn_base_result.json"
    ids = set(json.loads(SLICE.read_text())[sys.argv[2] if len(sys.argv) > 2 else "dev"])
    stats = defaultdict(list)
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if r["id"] not in ids or "latency" not in r:
            continue
        # inference_log intercala o estado das classes (listas) com os turnos (dicts).
        for t, turn in enumerate(x for x in r["inference_log"] if isinstance(x, dict)):
            prev, seen = "first", []
            for k in sorted((k for k in turn if k.startswith("step_")), key=lambda k: int(k[5:])):
                s = int(k[5:])
                tokens = r["output_token_count"][t][s] if s < len(r["output_token_count"][t]) else None
                if tokens is None:
                    continue
                content = next((e["content"] for e in turn[k] if e.get("role") == "assistant"), None)
                calls = [json.dumps(c, sort_keys=True) for c in content] if isinstance(content, list) else []
                stats[prev].append((tokens, not calls))
                tools = [str(e["content"]).lower() for e in turn[k] if e.get("role") == "tool"]
                if any(c in seen for c in calls):
                    prev = "after_repeat"
                elif any(any(cue in x for cue in ERROR_CUES) for x in tools):
                    prev = "after_error"
                else:
                    prev = "after_ok"
                seen += calls
    print("| Estado | Passos | Tokens médios | p90 | ≥1024 | Terminou em texto |\n|---|---|---|---|---|---|")
    for state in ["first", "after_ok", "after_error", "after_repeat"]:
        xs = stats[state]
        if not xs:
            continue
        toks = sorted(x for x, _ in xs)
        print(f"| {state} | {len(xs)} | {sum(toks) / len(toks):.0f} | {toks[int(0.9 * (len(toks) - 1))]} "
              f"| {sum(x >= 1024 for x in toks)} | {sum(t for _, t in xs)} |")


if __name__ == "__main__":
    main()
