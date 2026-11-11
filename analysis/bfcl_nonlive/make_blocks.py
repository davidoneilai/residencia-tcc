"""Divide um split em blocos para `run_blocks.sh`, antes de executar. Estratificado por categoria, seed fixa.

    python3 analysis/bfcl_nonlive/make_blocks.py dev 4 reports/bfcl-nonlive/blocks-budget-dev.json
    python3 analysis/bfcl_nonlive/make_blocks.py test2 4 reports/bfcl-nonlive/blocks-budget-test2.json
"""
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SEED = 20261105


def ids(split):
    first = json.loads((ROOT / "reports" / "bfcl-nonlive" / "selection.json").read_text())
    if split == "test2":
        return json.loads((ROOT / "reports" / "bfcl-nonlive" / "selection-test2.json").read_text())["test2"]
    by = {c: list(first["pilot"][c]) for c in first["categories"]}
    for i in first["dev_prior"]:
        by[i.rsplit("_", 1)[0]].append(i)
    return by


def main():
    split, n, out = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
    assert not out.exists(), "blocos já congelados; não sobrescrever"
    rng = random.Random(SEED)
    blocks = [[] for _ in range(n)]
    k = 0
    for category, members in sorted(ids(split).items()):
        members = sorted(members)
        rng.shuffle(members)
        for i in members:
            blocks[k % n].append(i)
            k += 1
    out.write_text(json.dumps({"split": split, "seed": SEED, "blocks": blocks}, indent=1) + "\n")
    print(f"{split}: {[len(b) for b in blocks]} → {out}")


if __name__ == "__main__":
    main()
