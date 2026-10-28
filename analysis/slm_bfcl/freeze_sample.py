"""Congela a amostra BFCL v4 AST antes de qualquer execução.

Fonte: dados oficiais empacotados em `bfcl-eval` (sem edição). Exclui os IDs já usados
nos testes BFCL anteriores (app: 20; GPU: 40 = 10 primeiros de cada categoria).
Gera o JSON do app e `reports/slm-bfcl/selection.json`.

    .bfcl-venv/bin/python analysis/slm_bfcl/freeze_sample.py
"""
import hashlib
import json
import random
from importlib.metadata import version
from pathlib import Path

import bfcl_eval

ROOT = Path(__file__).resolve().parents[2]
DATA = Path(bfcl_eval.__file__).parent / "data"
CATEGORIES = ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]
PER_CATEGORY = 8
SEED = 20261027
PRIOR = {f"{c}_{i}" for c in CATEGORIES[:4] for i in range(10)}


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def main():
    rng = random.Random(SEED)
    tasks, chosen, hashes = [], {}, {}
    for category in CATEGORIES:
        source = DATA / f"BFCL_v4_{category}.json"
        hashes[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
        entries = rows(source)
        answers = {}
        if category != "irrelevance":
            answer_file = DATA / "possible_answer" / source.name
            hashes["possible_answer/" + source.name] = hashlib.sha256(answer_file.read_bytes()).hexdigest()
            answers = {r["id"]: r["ground_truth"] for r in rows(answer_file)}
        pool = sorted((e for e in entries if e["id"] not in PRIOR), key=lambda e: int(e["id"].rsplit("_", 1)[1]))
        picked = sorted(rng.sample(pool, PER_CATEGORY), key=lambda e: int(e["id"].rsplit("_", 1)[1]))
        chosen[category] = [e["id"] for e in picked]
        for e in picked:
            assert len(e["question"]) == 1, "AST de turno único"
            tasks.append({
                "id": e["id"], "category": category,
                "messages": e["question"][0], "function": e["function"],
                "ground_truth": answers.get(e["id"], []),
            })
    app = ROOT / "MobileLLMBench" / "BFCLv4AST.json"
    app.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False, indent=1) + "\n")
    out = ROOT / "reports" / "slm-bfcl" / "selection.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "frozen_before_execution": True,
        "bfcl_eval_version": version("bfcl-eval"),
        "seed": SEED, "per_category": PER_CATEGORY, "categories": CATEGORIES,
        "excluded_prior_ids": sorted(PRIOR),
        "excluded_reason": "usados nos testes BFCL anteriores (app bfcl_subset_20 e GPU 40)",
        "ids": chosen,
        "source_sha256": hashes,
        "app_file_sha256": hashlib.sha256(app.read_bytes()).hexdigest(),
    }, indent=1) + "\n")
    print(json.dumps(chosen, indent=1))


if __name__ == "__main__":
    main()
