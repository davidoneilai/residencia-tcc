"""Figuras do relatório. SVG fica neste script; o app no iPhone exporta CSV e Markdown."""

from __future__ import annotations

from metrics import pareto_front, same_population


def write_plots(strategy_rows, category_rows, folder):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    folder.mkdir(parents=True, exist_ok=True)
    pareto(strategy_rows, folder, plt)
    accuracy(category_rows, folder, plt)
    latency(strategy_rows, folder, plt)


def pareto(rows, folder, plt):
    usable = [row for row in rows if row["median_latency_ms"] is not None and row["success_rate"] is not None]
    figure, axis = plt.subplots(figsize=(7, 4.5))
    if not usable:
        axis.set_title("Sem pontos")
    else:
        for row in usable:
            axis.scatter(row["median_latency_ms"], row["success_rate"], label=row["strategy"])
            axis.annotate(row["strategy"], (row["median_latency_ms"], row["success_rate"]))
        if same_population(rows):
            front = set(pareto_front(rows))
            ordered = sorted((row for row in usable if row["strategy"] in front), key=lambda row: row["median_latency_ms"])
            if len(ordered) >= 2:
                axis.plot([row["median_latency_ms"] for row in ordered], [row["success_rate"] for row in ordered])
            axis.set_title("Eficiência × qualidade")
        else:
            axis.set_title("Populações diferentes: sem fronteira")
    axis.set_xlabel("Latência mediana (ms)")
    axis.set_ylabel("Taxa de sucesso")
    axis.set_ylim(-0.05, 1.05)
    figure.tight_layout()
    figure.savefig(folder / "pareto.png")
    figure.savefig(folder / "pareto.svg")
    plt.close(figure)


def accuracy(rows, folder, plt):
    categories = sorted({row["category"] for row in rows if row["category"] != "all"})
    strategies = sorted({row["strategy"] for row in rows if row["category"] != "all"})
    figure, axis = plt.subplots(figsize=(8, 4.5))
    if not categories:
        axis.set_title("Sem categorias")
    else:
        width = 0.8 / max(len(strategies), 1)
        for index, strategy in enumerate(strategies):
            rates = []
            for category in categories:
                match = next((row for row in rows if row["strategy"] == strategy and row["category"] == category), None)
                rates.append(0 if match is None or match["success_rate"] is None else match["success_rate"])
            positions = [item + index * width for item in range(len(categories))]
            axis.bar(positions, rates, width=width, label=strategy)
        axis.set_xticks([item + width * (len(strategies) - 1) / 2 for item in range(len(categories))])
        axis.set_xticklabels(categories, rotation=20, ha="right")
        axis.set_ylim(0, 1)
        axis.legend()
    axis.set_ylabel("Taxa de sucesso")
    axis.set_title("Sucesso por categoria")
    figure.tight_layout()
    figure.savefig(folder / "accuracy_by_category.png")
    plt.close(figure)


def latency(rows, folder, plt):
    usable = [row for row in rows if row["category"] == "all" and row["median_latency_ms"] is not None]
    figure, axis = plt.subplots(figsize=(7, 4.5))
    if not usable:
        axis.set_title("Sem latência")
    else:
        names = [row["strategy"] for row in usable]
        axis.bar(names, [row["median_latency_ms"] for row in usable], label="mediana")
        axis.scatter(names, [row["p90_latency_ms"] or 0 for row in usable], label="p90", zorder=3)
        axis.legend()
    axis.set_ylabel("ms")
    axis.set_title("Latência por estratégia")
    figure.tight_layout()
    figure.savefig(folder / "latency_by_strategy.png")
    plt.close(figure)
