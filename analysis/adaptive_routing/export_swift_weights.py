#!/usr/bin/env python3
"""Atualiza LogisticWeights no AdaptiveRouter.swift a partir do JSON treinado."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / "MobileLLMBench" / "AdaptiveRouter.swift"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--weights",
        type=Path,
        default=ROOT / "reports" / "adaptive-routing" / "artifacts" / "qwen_learned.json",
    )
    args = parser.parse_args()
    data = json.loads(args.weights.read_text())
    if data.get("name") != "logistic":
        raise SystemExit(f"esperado logistic, veio {data.get('name')}")
    text = SWIFT.read_text()
    replacements = {
        "threshold": data["threshold"],
        "bias": data["bias"],
        "mean": data["mean"],
        "std": data["std"],
        "weights": data["weights"],
    }
    for key, value in replacements.items():
        if isinstance(value, list):
            body = ", ".join(f"{v:.8g}" for v in value)
            pattern = rf"(static let {key}: \[Double\] = \[)[^\]]*(\])"
            text, n = re.subn(pattern, rf"\g<1>{body}\2", text, count=1)
        else:
            pattern = rf"(static let {key}: Double = )[^\n]+"
            text, n = re.subn(pattern, rf"\g<1>{float(value):.8g}", text, count=1)
        if n != 1:
            raise SystemExit(f"não atualizou {key}")
    SWIFT.write_text(text)
    print(f"atualizado {SWIFT}")


if __name__ == "__main__":
    main()
