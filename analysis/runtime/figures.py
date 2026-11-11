"""Figura do TEST final: tempo médio por tarefa (runtime atual × pilha fria × pilha quente) nos três SLMs.

    python3 analysis/runtime/figures.py

Lê as linhas por (rodada, condição, entrada) que `analyze_dac.py` grava em `reports/runtime/test-<modelo>.json`
e escreve `reports/runtime/figures/test-latency.{png,svg}`. Não usa o iPhone.
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPORTS = ROOT / "reports" / "runtime"
# (rótulo, json, referência, pilha, rodada A, rodada B)
MODELS = [
    ("Qwen3.5-2B\n(com raciocínio)", "qwen35", "rt-base-kv", "dacs-persist-kv", "tqA", "tqB"),
    ("MiniCPM5-2B\n(sem raciocínio)", "minicpm5", "nt-base-kv", "nt-dacs-persist-kv", "tmA", "tmB"),
    ("Gemma 4 E2B\n(sem raciocínio)", "gemma4", "nt-base-kv", "nt-dacs-persist-kv", "tgA", "tgB"),
]
# Rampa ordinal azul (uma matiz, claro → escuro), validada com o validador do skill dataviz (--ordinal, light).
COLORS = {"atual": "#86b6ef", "fria": "#2a78d6", "quente": "#104281"}
SURFACE, INK, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"


def means(name, ref, stack, run_a, run_b):
    rows = json.loads((REPORTS / f"test-{name}.json").read_text())

    def mean(run, cond):
        xs = [r["latency_s"] for r in rows if r["run"] == run and r["cond"] == cond]
        return sum(xs) / len(xs)

    return mean(run_a, ref), mean(run_a, stack), mean(run_b, stack)


def main():
    data = [(label, *means(*spec)) for label, *spec in MODELS]
    fig, ax = plt.subplots(figsize=(8.4, 4.6), dpi=200)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)
    height, gap = 0.24, 0.03
    for i, (label, atual, fria, quente) in enumerate(data):
        y = len(data) - 1 - i
        for k, (key, value) in enumerate([("atual", atual), ("fria", fria), ("quente", quente)]):
            pos = y + (1 - k) * (height + gap)
            ax.barh(pos, value, height=height, color=COLORS[key], edgecolor=SURFACE, linewidth=1)
            text = f"{value:.0f} s"
            if key != "atual":
                text += f"  ({100 * (value - atual) / atual:+.0f}%)".replace("-", "−")
            ax.text(value + 1.2, pos, text, va="center", fontsize=8.5, color=INK if key == "quente" else MUTED,
                    fontweight="bold" if key == "quente" else "normal")
    ax.set_yticks(range(len(data)))
    ax.set_yticklabels([d[0] for d in reversed(data)], fontsize=9.5, color=INK)
    ax.set_xlabel("tempo médio por tarefa no iPhone 16 Pro (s)", fontsize=9, color=MUTED)
    ax.set_xlim(0, max(d[1] for d in data) * 1.32)
    ax.tick_params(axis="x", colors=MUTED, labelsize=8.5, length=0)
    ax.tick_params(axis="y", length=0)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    handles = [plt.Rectangle((0, 0), 1, 1, color=COLORS[k]) for k in COLORS]
    ax.legend(handles, ["runtime atual", "pilha, 1ª vez do catálogo (fria)", "pilha, catálogo já visto (quente)"],
              loc="lower right", frameon=False, fontsize=8.5, labelcolor=INK)
    ax.set_title("BFCL Multi-Turn, 32 tarefas TEST: a pilha corta 31–63% do tempo,\nsem perda significativa de acerto",
                 fontsize=10.5, color=INK, loc="left", pad=12)
    fig.tight_layout()
    out = REPORTS / "figures"
    out.mkdir(exist_ok=True)
    for ext in ("png", "svg"):
        fig.savefig(out / f"test-latency.{ext}", facecolor=SURFACE)
    print(out / "test-latency.png")


if __name__ == "__main__":
    main()
