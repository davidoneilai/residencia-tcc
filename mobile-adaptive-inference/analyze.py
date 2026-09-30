import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "results")
    groups = defaultdict(list)
    for path in sorted(root.glob("*.jsonl")):
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            groups[(row["model"], row["strategy"], row["benchmark"])].append(row)

    print("model strategy benchmark success_rate mean_inference_ms median_inference_ms mean_output_tokens")
    points = []
    for key in sorted(groups):
        rows = groups[key]
        rate = statistics.fmean(1.0 if row["success"] else 0.0 for row in rows)
        times = [row["agent_inference_ms"] for row in rows]
        tokens = [row["output_tokens"] for row in rows]
        mean_ms = statistics.fmean(times)
        median_ms = statistics.median(times)
        mean_tokens = statistics.fmean(tokens)
        print(key[0], key[1], key[2], f"{rate:.4f}", f"{mean_ms:.2f}", f"{median_ms:.2f}", f"{mean_tokens:.2f}")
        points.append((key, rate, mean_ms, mean_tokens, rows))

    def scatter(path, y_index, ylabel):
        fig, ax = plt.subplots()
        for key, rate, mean_ms, mean_tokens, _rows in points:
            y = (rate, mean_ms, mean_tokens)[y_index]
            ax.scatter(rate, y)
            ax.annotate(" ".join(key), (rate, y), fontsize=6)
        ax.set_xlabel("success_rate")
        ax.set_ylabel(ylabel)
        fig.tight_layout()
        fig.savefig(path)
        plt.close(fig)

    if not points:
        return
    scatter(root / "quality_latency.png", 1, "mean_inference_ms")
    scatter(root / "quality_tokens.png", 2, "mean_output_tokens")

    energy = []
    for key, rate, _mean_ms, _mean_tokens, rows in points:
        if rows and all(isinstance(row.get("energy_j"), (int, float)) for row in rows):
            energy.append((key, rate, statistics.fmean(row["energy_j"] for row in rows)))
    if not energy:
        return
    fig, ax = plt.subplots()
    for key, rate, joules in energy:
        ax.scatter(rate, joules)
        ax.annotate(" ".join(key), (rate, joules), fontsize=6)
    ax.set_xlabel("success_rate")
    ax.set_ylabel("mean_energy_j")
    fig.tight_layout()
    fig.savefig(root / "quality_energy.png")
    plt.close(fig)


if __name__ == "__main__":
    main()
