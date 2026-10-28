"""Foundation Models Bench -> JSONL de results/, com energia do powermetrics quando houver log.

python fmb_energy.py run.json results/fmb_apple_agentic.jsonl [powermetrics.txt]
"""
import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

from metrics import append_jsonl

HEADER = re.compile(r"\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\) \*\*\*")
POWER = re.compile(r"Combined Power \(CPU \+ GPU \+ ANE\): (\d+) mW")


def power_samples(text):
    """[(início, fim, watts)]; o cabeçalho do powermetrics marca o fim de cada amostra."""
    samples, end, span = [], None, None
    for line in text.splitlines():
        if m := HEADER.search(line):
            end = datetime.strptime(" ".join(m[1].split()), "%a %b %d %H:%M:%S %Y %z")
            span = timedelta(milliseconds=float(m[2]))
        elif (m := POWER.search(line)) and end:
            samples.append((end - span, end, int(m[1]) / 1000))
            end = None
    return samples


def energy_j(samples, start, end):
    total = 0.0
    for a, b, watts in samples:
        overlap = (min(b, end) - max(a, start)).total_seconds()
        if overlap > 0:
            total += watts * overlap
    return total


def covered(samples, start, end):
    return bool(samples) and samples[0][0] <= start and samples[-1][1] >= end


def stamp(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def rows(report, samples):
    for trial in report["trials"]:
        metrics = trial["metrics"]
        start, end = stamp(metrics["startedAt"]), stamp(metrics["endedAt"])
        if end <= start:
            # ponytail: o JSON grava segundos inteiros; tentativa de menos de 1 s ganha janela de 1 s.
            end = start + timedelta(seconds=1)
        row = {
            "task_id": f"{trial['scenario']['id']}#{trial['iteration']}",
            "benchmark": f"fmb_{report['suite']}",
            "model": f"apple_{trial['model']}",
            "strategy": "direct",
            "success": all(check["passed"] for check in trial["grade"]["checks"]),
            "score": None,
            "agent_inference_ms": metrics["duration"] * 1000,
            "prompt_tokens": metrics.get("inputTokenCount") or 0,
            "output_tokens": metrics["outputTokenCount"],
            "model_calls": 1,
            "tool_calls": len(trial.get("toolCalls") or []),
            "device": report["environment"].get("hardwareModel"),
        }
        if covered(samples, start, end):
            row["energy_j"] = energy_j(samples, start, end)
            row["energy_j_per_token"] = row["energy_j"] / max(row["output_tokens"], 1)
        yield row


def main():
    report = json.loads(Path(sys.argv[1]).read_text())
    samples = power_samples(Path(sys.argv[3]).read_text()) if len(sys.argv) > 3 else []
    out = Path(sys.argv[2])
    n = 0
    for row in rows(report, samples):
        append_jsonl(out, row)
        n += 1
    print("escreveu", out, "linhas", n, "com energia" if samples else "sem energia")


if __name__ == "__main__":
    main()
