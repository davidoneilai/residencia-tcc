"""Remove dos resultados as entradas que falharam por inferência (sem `latency`), para o bfcl refazê-las.

Erro de conexão com o iPhone vira uma linha "Error during inference" e o bfcl pula o ID num rerun.
    python3 analysis/bfcl_mt/prune_errors.py [modelo] [id]    # sem argumentos: todos
Imprime quantas linhas removeu. Não toca em entradas com resultado (certas ou erradas).
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(os.environ.get("BFCL_MT_ROOT") or Path(__file__).resolve().parents[2] / "results" / "bfcl-mt") / "result"


def main():
    model = sys.argv[1] if len(sys.argv) > 1 else "*"
    wanted = sys.argv[2] if len(sys.argv) > 2 else None
    removed = 0
    for path in ROOT.glob(f"{model}/multi_turn/*_result.json"):
        keep = []
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            if "latency" not in row and (wanted is None or row["id"] == wanted):
                removed += 1
            else:
                keep.append(line)
        path.write_text("".join(f"{line}\n" for line in keep))
    print(removed)


if __name__ == "__main__":
    main()
