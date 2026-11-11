"""Resumo das comparações do `mtp_device.py`: por condição, ganho pareado de decode contra a condição `0`.

    python3 analysis/runtime/mtp_summary.py <saída.jsonl> [...]

Ganho = (ms por token sem MTP) / (ms por token com a condição), no mesmo passo; média geométrica entre passos.
Só passos com o mesmo número de tokens entram na média "mesma saída"; todos entram na de ms/token.
"""
import json
import math
import sys
from collections import defaultdict


def main():
    rows = [json.loads(line) for path in sys.argv[1:] for line in open(path)]
    by = defaultdict(dict)
    for r in rows:
        by[r["index"]][str(r["block"])] = r
    conditions = sorted({c for v in by.values() for c in v if c != "0"})
    for c in conditions:
        gains, same, prop, acc, wasted, synced = [], 0, 0, 0, 0, 0
        for runs in by.values():
            base, run = runs.get("0"), runs.get(c)
            if not base or not run or not base["decode_ms"] or not run["decode_ms"]:
                continue
            gains.append((base["decode_ms"] / base["tokens"]) / (run["decode_ms"] / run["tokens"]))
            same += run["raw"] == base["raw"] and run["calls"] == base["calls"]
            prop += run.get("mtp_proposed") or 0
            acc += run.get("mtp_accepted") or 0
            wasted += run.get("mtp_wasted_rounds") or 0
            synced += run.get("mtp_synced") or 0
        if not gains:
            continue
        geo = math.exp(sum(map(math.log, gains)) / len(gains))
        print(f"{c:>22}  n={len(gains):2d}  ganho={geo:.3f}x  (min {min(gains):.2f}, max {max(gains):.2f})  "
              f"aceitação={acc / max(prop, 1):.3f}  desperdiçadas={wasted}  sincronizadas={synced}  "
              f"mesma saída={same}/{len(gains)}")


if __name__ == "__main__":
    main()
