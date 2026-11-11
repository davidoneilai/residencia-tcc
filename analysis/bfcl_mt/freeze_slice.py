"""Congela as fatias DEV e TESTE do BFCL v4 Multi-Turn antes de qualquer execução nelas.

Fonte: `multi_turn_base` empacotado em `bfcl-eval` (sem edição). Só entradas curtas
(≤ 3 turnos e ≤ 4 chamadas no gabarito), para caber no iPhone. Exclui os IDs do smoke de 29/10.
DEV desenha e congela a política adaptativa A; TESTE só roda com A congelada.

    .bfcl-venv/bin/python analysis/bfcl_mt/freeze_slice.py
"""
import hashlib
import json
import random
from importlib.metadata import version
from pathlib import Path

import bfcl_eval

ROOT = Path(__file__).resolve().parents[2]
DATA = Path(bfcl_eval.__file__).parent / "data"
CATEGORY = "multi_turn_base"
MAX_TURNS = 3
MAX_CALLS = 4
DEV_SIZE = 12
SEED = 20261104
PRIOR = {"multi_turn_base_94", "multi_turn_base_187", "multi_turn_base_195"}


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main():
    source = DATA / f"BFCL_v4_{CATEGORY}.json"
    answer = DATA / "possible_answer" / source.name
    gold = {r["id"]: r["ground_truth"] for r in rows(answer)}
    pool = sorted(
        (e for e in rows(source)
         if e["id"] not in PRIOR and len(e["question"]) <= MAX_TURNS
         and sum(len(t) for t in gold[e["id"]]) <= MAX_CALLS),
        key=lambda e: int(e["id"].rsplit("_", 1)[1]))
    order = [e["id"] for e in pool]
    random.Random(SEED).shuffle(order)
    by_number = lambda i: int(i.rsplit("_", 1)[1])  # noqa: E731
    dev, test = sorted(order[:DEV_SIZE], key=by_number), sorted(order[DEV_SIZE:], key=by_number)
    meta = {e["id"]: {"turns": len(e["question"]), "gold_calls": sum(len(t) for t in gold[e["id"]]),
                      "classes": e["involved_classes"]} for e in pool}
    out = ROOT / "results" / "bfcl-mt" / "slice.json"
    out.write_text(json.dumps({
        "frozen_before_execution": True,
        "bfcl_eval_version": version("bfcl-eval"),
        "category": CATEGORY, "seed": SEED, "max_turns": MAX_TURNS, "max_gold_calls": MAX_CALLS,
        "excluded_prior_ids": sorted(PRIOR), "excluded_reason": "smoke de 29/10 (Qwen3.5 Direct/NoThink)",
        "sha256": {source.name: hashlib.sha256(source.read_bytes()).hexdigest(),
                   "possible_answer/" + source.name: hashlib.sha256(answer.read_bytes()).hexdigest()},
        "pool_size": len(pool), "dev": dev, "test": test,
        "entries": {i: meta[i] for i in dev + test},
    }, indent=1) + "\n")
    print(f"pool {len(pool)}: dev {len(dev)}, test {len(test)} -> {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
