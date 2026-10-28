#!/usr/bin/env python3
"""Lê um JSON exportado pelo MobileLLMBench e grava CSV, figuras e report.md."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from metrics import aggregate, pareto_front, rows_of, same_population, self_check
from plots import write_plots


SUMMARY_FIELDS = [
    "model", "strategy", "category", "n", "n_success", "success_rate",
    "median_latency_ms", "p90_latency_ms", "mean_tokens", "median_time_to_tool_ms",
    "n_missing_latency", "cold_n", "warm_n", "start_unspecified_n",
    "cold_median_ms", "warm_median_ms", "exploratory",
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path)
    parser.add_argument("--out", type=Path, default=Path("analysis-out"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        self_check()
        print("ANALYSIS_OK")
        if args.input is None:
            return
    if args.input is None:
        raise SystemExit("Informe --input ou --check")
    payload = json.loads(args.input.read_text())
    report = aggregate(rows_of(payload))
    args.out.mkdir(parents=True, exist_ok=True)
    write_csv(args.out / "summary.csv", report["summary"], SUMMARY_FIELDS)
    write_csv(args.out / "failure_analysis.csv", report["failures"], ["model", "strategy", "category", "bucket", "kind", "n"])
    write_plots(report["strategies"], report["summary"], args.out)
    (args.out / "report.md").write_text(markdown(report))
    print(f"gravado em {args.out}")


def write_csv(path, rows, fields):
    import pandas as pd

    frame = pd.DataFrame(rows, columns=fields)
    frame.to_csv(path, index=False)


def markdown(report):
    front = pareto_front(report["strategies"])
    comparable = same_population(report["strategies"])
    lines = [
        "# Resumo experimental",
        "",
        "Análise exploratória: há no máximo uma repetição por condição." if report["exploratory"] else "Há mais de uma repetição.",
        "",
        f"Executadas: {report['executed']}. Puladas ou interrompidas: {report['skipped']}.",
        "As estratégias usam o mesmo conjunto de tarefas." if comparable else "As estratégias não usam o mesmo conjunto de tarefas. A fronteira de Pareto não foi traçada.",
        "",
        "| Estratégia | n | Sucesso | Mediana | p90 | Tokens | Observações sem latência |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in report["strategies"]:
        lines.append(
            f"| {row['strategy']} | {row['n']} | {fmt(row['success_rate'])} | {fmt(row['median_latency_ms'])} | {fmt(row['p90_latency_ms'])} | {fmt(row['mean_tokens'])} | {row['n_missing_latency']} |"
        )
    lines.append("")
    if front:
        lines.append("Fronteira: " + ", ".join(front) + ".")
    lines.append("")
    lines.append("Latência é totalLatencyMs. Se o JSON antigo não tiver o campo, usa totalMs menos modelLoadMs. Tentativas térmicas ou canceladas não entram no sucesso.")
    return "\n".join(lines) + "\n"


def fmt(value):
    if value is None:
        return "null"
    return f"{value:.4g}"


if __name__ == "__main__":
    main()
