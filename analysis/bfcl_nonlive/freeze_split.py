"""Congela o split DEV/TESTE do BFCL v4 Non-Live antes de qualquer execução.

Fonte: dados oficiais empacotados em `bfcl-eval` (sem edição). Categorias Non-Live AST:
simple_python, multiple, parallel, parallel_multiple, irrelevance.

- `excluded`: IDs já usados em estudos anteriores (GPU: 10 primeiros por categoria; app:
  `BFCLSubset.json`; estudo SLM × AST: `BFCLv4AST.json`). Nunca entram no teste.
- `dev_prior`: os 40 de `BFCLv4AST.json`. Já executados; só podem servir ao desenvolvimento.
- `pilot`: 8 por categoria (40). DEV: piloto Direct × Reasoning e calibração do roteador.
- `test`: 32 por categoria (160). Só para a avaliação final, com a política congelada.

Gera `MobileLLMBench/BFCLv4NonLive.json` (piloto + teste, lido pelo app junto com o AST antigo)
e `reports/bfcl-nonlive/selection.json`. Não toca em `BFCLv4AST.json`.

    .bfcl-venv/bin/python analysis/bfcl_nonlive/freeze_split.py
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
PILOT, TEST = 8, 32
SEED = 20261105
APP = ROOT / "MobileLLMBench" / "BFCLv4NonLive.json"
SELECTION = ROOT / "reports" / "bfcl-nonlive" / "selection.json"


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def number(task_id):
    return int(task_id.rsplit("_", 1)[1])


def used_before():
    gpu = {f"{c}_{i}" for c in CATEGORIES[:4] for i in range(10)}
    subset = {t["id"] for t in json.loads((ROOT / "MobileLLMBench" / "BFCLSubset.json").read_text())["tasks"]}
    ast = [t["id"] for t in json.loads((ROOT / "MobileLLMBench" / "BFCLv4AST.json").read_text())["tasks"]]
    return gpu | subset | set(ast), ast


def main():
    assert not APP.exists() and not SELECTION.exists(), "split já congelado; não sobrescrever"
    excluded, dev_prior = used_before()
    rng = random.Random(SEED)
    tasks, pilot, test, hashes = [], {}, {}, {}
    for category in CATEGORIES:
        source = DATA / f"BFCL_v4_{category}.json"
        hashes[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
        answers = {}
        if category != "irrelevance":
            answer_file = DATA / "possible_answer" / source.name
            hashes["possible_answer/" + source.name] = hashlib.sha256(answer_file.read_bytes()).hexdigest()
            answers = {r["id"]: r["ground_truth"] for r in rows(answer_file)}
        pool = sorted((e for e in rows(source) if e["id"] not in excluded), key=lambda e: number(e["id"]))
        picked = rng.sample(pool, PILOT + TEST)
        split = {"pilot": picked[:PILOT], "test": picked[PILOT:]}
        pilot[category] = sorted((e["id"] for e in split["pilot"]), key=number)
        test[category] = sorted((e["id"] for e in split["test"]), key=number)
        for name, entries in split.items():
            for e in sorted(entries, key=lambda e: number(e["id"])):
                assert len(e["question"]) == 1, "Non-Live: turno único"
                tasks.append({
                    "id": e["id"], "category": category, "split": name,
                    "messages": e["question"][0], "function": e["function"],
                    "ground_truth": answers.get(e["id"], []),
                })
    flat = lambda d: {i for ids in d.values() for i in ids}
    assert not flat(pilot) & flat(test) and not (flat(pilot) | flat(test)) & excluded
    APP.write_text(json.dumps({"tasks": tasks}, ensure_ascii=False, indent=1) + "\n")
    SELECTION.parent.mkdir(parents=True, exist_ok=True)
    SELECTION.write_text(json.dumps({
        "frozen_before_execution": True,
        "benchmark": "BFCL v4 Non-Live (AST, turno único)",
        "bfcl_eval_version": version("bfcl-eval"),
        "seed": SEED, "categories": CATEGORIES,
        "per_category": {"pilot": PILOT, "test": TEST},
        "excluded_prior_ids": sorted(excluded, key=lambda i: (i.rsplit("_", 1)[0], number(i))),
        "excluded_reason": "usados antes: GPU (10 primeiros por categoria), app BFCLSubset.json, estudo SLM × AST BFCLv4AST.json",
        "dev_prior": dev_prior,
        "pilot": pilot,
        "test": test,
        "source_sha256": hashes,
        "app_file_sha256": hashlib.sha256(APP.read_bytes()).hexdigest(),
    }, indent=1) + "\n")
    print(f"pilot {len(flat(pilot))} · test {len(flat(test))} · excluídos {len(excluded)} → {APP.name}")


if __name__ == "__main__":
    main()
