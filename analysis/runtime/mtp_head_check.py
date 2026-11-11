"""Cabeça MTP própria no iPhone (`/v1/debug/mtp`, build `MLX_LM_MAIN`): aceitação e custos, sem especular.

    IPHONE_URL=http://127.0.0.1:18080 python3 analysis/runtime/mtp_head_check.py <requests.json> <saída.jsonl> \\
        <índices> [max_tokens] [modelo]

Para cada passo gravado, o alvo gera em greedy e a MTP prevê o token depois do próximo; o servidor devolve a
aceitação de 1 rascunho (vocabulário inteiro e reduzido) e os tempos sincronizados de cada parte.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from microbench import cool, post  # noqa: E402


def main():
    items = json.loads(Path(sys.argv[1]).read_text())
    out_path, indices = Path(sys.argv[2]), [int(i) for i in sys.argv[3].split(",")]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else 256
    model = sys.argv[5] if len(sys.argv) > 5 else "qwen35:direct"
    with out_path.open("a") as out:
        for index in indices:
            waited = cool()
            resp = post("/v1/debug/mtp", {**items[index]["req"], "model": model, "max_tokens": limit})
            row = {"index": index, "cooled_s": waited, **resp.get("result", resp), "thermal": resp.get("thermal")}
            out.write(json.dumps(row) + "\n")
            out.flush()
            print(row, flush=True)


if __name__ == "__main__":
    main()
