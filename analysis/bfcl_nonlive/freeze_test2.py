"""Congela o TESTE-2 do BFCL v4 Non-Live (estudo B, orçamento de raciocínio) antes de qualquer execução nele.

32 IDs novos por categoria, disjuntos de tudo que já foi usado: os excluídos de `selection.json`,
`dev_prior`, `pilot` e `test`. Gera `MobileLLMBench/BFCLv4NonLiveTest2.json` (lido pelo app) e
`reports/bfcl-nonlive/selection-test2.json`. Não toca em `selection.json`.

    .bfcl-venv/bin/python analysis/bfcl_nonlive/freeze_test2.py
"""
import hashlib
import json
import random
from importlib.metadata import version
from pathlib import Path

from freeze_split import CATEGORIES, DATA, ROOT, SELECTION, number, rows

PER_CATEGORY = 32
SEED = 20261106
APP = ROOT / "MobileLLMBench" / "BFCLv4NonLiveTest2.json"
OUT = ROOT / "reports" / "bfcl-nonlive" / "selection-test2.json"


def main():
    assert not APP.exists() and not OUT.exists(), "TESTE-2 já congelado; não sobrescrever"
    first = json.loads(SELECTION.read_text())
    flat = lambda part: set(part) if isinstance(part, list) else {i for ids in part.values() for i in ids}
    used = set(first["excluded_prior_ids"]) | flat(first["dev_prior"]) | flat(first["pilot"]) | flat(first["test"])
    rng = random.Random(SEED)
    tasks, chosen = [], {}
    for category in CATEGORIES:
        source = DATA / f"BFCL_v4_{category}.json"
        answers = {}
        if category != "irrelevance":
            answers = {r["id"]: r["ground_truth"] for r in rows(DATA / "possible_answer" / source.name)}
        pool = sorted((e for e in rows(source) if e["id"] not in used), key=lambda e: number(e["id"]))
        picked = sorted(rng.sample(pool, PER_CATEGORY), key=lambda e: number(e["id"]))
        chosen[category] = [e["id"] for e in picked]
        for e in picked:
            assert len(e["question"]) == 1, "Non-Live: turno único"
            tasks.append({"id": e["id"], "category": category, "split": "test2",
                          "messages": e["question"][0], "function": e["function"],
                          "ground_truth": answers.get(e["id"], [])})
    assert not {t["id"] for t in tasks} & used
    APP.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False, indent=1) + "\n")
    OUT.write_text(json.dumps({
        "frozen_before_execution": True, "study": "B, orçamento de raciocínio",
        "bfcl_eval_version": version("bfcl-eval"), "seed": SEED, "categories": CATEGORIES,
        "per_category": PER_CATEGORY, "excluded_used_ids": len(used),
        "test2": chosen, "source_sha256": first["source_sha256"],
        "app_file_sha256": hashlib.sha256(APP.read_bytes()).hexdigest(),
    }, indent=1) + "\n")
    print(f"test2 {len(tasks)} · excluídos {len(used)} → {APP.name}")


if __name__ == "__main__":
    main()
