"""Avaliação mínima de runtime no BFCL-MT (iPhone, Qwen3.5-2B): cada entrada × cada condição `rt-*`, ordem girada,
com os KV em memória apagados antes de cada execução (`POST /v1/debug/reset`): cada tarefa começa como uma sessão nova.
O prefixo persistido em disco sobrevive ao reset (é o que `rt-persist`/`rt-both` medem).

    .bfcl-venv/bin/python analysis/runtime/run_eval.py <rodada> <id,id,...> [cond ...]
Resultados em results/bfcl-mt/dac/<rodada>/ (mesmo formato do estudo DAC; ver analyze_dac.py).
O progresso vai para a aba Ao vivo do app (`POST /v1/progress`). `BENCH_RUNS=st1,st2,st3` faz a contagem e a
previsão cobrirem a cadeia inteira de rodadas (mesmas entradas e quantidade de condições em todas);
`rodada@slm:cond+cond` quando a cadeia troca de modelo ou de condições (ex. `sf1@qwen35_sft:rt-base-kv+dacs-persist-kv`).
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from microbench import cool, post, thermal  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CONDS = ["rt-base-kv", "rt-persist-kv", "rt-draft-kv", "rt-both-kv"]
# `BENCH_SLM=qwen35_sft` roda as mesmas condições em outro modelo do servidor (ver `iphone-<slm>-dac-<cond>` no bfcl.py).
SLM = os.environ.get("BENCH_SLM", "qwen35")


def has_result(root, cond, entry, slm=None):
    p = root / "result" / f"iphone-{slm or SLM}-dac-{cond}" / "multi_turn" / "BFCL_v4_multi_turn_base_result.json"
    if not p.exists():
        return False
    return any(json.loads(l)["id"] == entry and "latency" in json.loads(l) for l in p.read_text().splitlines() if l.strip())


def main():
    run, ids = sys.argv[1], sys.argv[2].split(",")
    conds = sys.argv[3:] or CONDS
    root = ROOT / "results" / "bfcl-mt" / "dac" / run
    root.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, "BFCL_MT_ROOT": str(root)}
    log = open(root / "run.log", "a")

    def say(msg):
        line = f"{time.strftime('%T')} {msg}"
        print(line, flush=True)
        log.write(line + "\n")
        log.flush()

    py = str(ROOT / ".bfcl-venv/bin/python")
    chain = []
    for item in [r for r in os.environ.get("BENCH_RUNS", run).split(",") if r] or [run]:
        name, _, rest = item.partition("@")
        slm, _, cs = rest.partition(":")
        chain.append((name, slm or SLM, cs.split("+") if cs else conds))
    runs = [name for name, _, _ in chain]
    total = sum(len(ids) * len(cs) for _, _, cs in chain)
    durations, failures = [], 0

    def done():
        return sum(has_result(ROOT / "results" / "bfcl-mt" / "dac" / r, c, e, slm)
                   for r, slm, cs in chain for c in cs for e in ids)

    def report(state, i, cond, cooled=0, waiting=None):
        # Nunca derruba o bench: o app pode estar fechado ou em outra aba.
        finished = done()
        left = total - finished
        eta = int(sum(durations) / len(durations) * left) if durations and left else None
        round_ = f"{run} ({runs.index(run) + 1}/{len(runs)})" if run in runs else run
        label = f"{run} · {SLM} · {ids[i] if i is not None else '-'} · {cond or '-'}"
        if waiting:
            label += f" · térmica {waiting}"
        body = {"done": finished, "total": total, "label": label, "state": state, "round": round_,
                "task": f"{i + 1}/{len(ids)} · {ids[i]}" if i is not None else None,
                "condition": f"{conds.index(cond) + 1}/{len(conds)} · {cond}" if cond else None,
                "cooled_s": cooled, "eta_s": eta, "failures": failures}
        try:
            post("/v1/progress", {k: v for k, v in body.items() if v is not None}, timeout=5)
        except Exception:
            pass

    def online(limit=3600):
        """Espera o iPhone voltar (mDNS some quando a rede oscila ou o app sai da frente); até `limit` s."""
        started = time.time()
        while True:
            try:
                thermal()
                return
            except Exception as error:
                if time.time() - started > limit:
                    raise
                if time.time() - started < 1:
                    say(f"SEM CONEXÃO com o iPhone ({error}); tentando de novo a cada 30 s")
                time.sleep(30)

    for i, entry in enumerate(ids):
        (root / "test_case_ids_to_generate.json").write_text(json.dumps({"multi_turn_base": [entry]}))
        order = conds[i % len(conds):] + conds[:i % len(conds)]
        for cond in order:
            for attempt in (1, 2, 3):
                if has_result(root, cond, entry):
                    break
                subprocess.run([py, "analysis/bfcl_mt/prune_errors.py", f"iphone-{SLM}-dac-{cond}", entry],
                               cwd=ROOT, env=env, capture_output=True)
                while True:
                    online()
                    try:
                        waited = cool(tick=lambda w, t, i=i, cond=cond: report("esfriando", i, cond, w, t))
                        files = post("/v1/debug/reset", {})["prefix_files"]
                        break
                    except OSError:
                        continue
                say(f"{cond} {entry} (tentativa {attempt}) cooled={waited}s prefix_files={files}")
                report("rodando", i, cond, waited)
                started = time.time()
                with open(root / "bfcl.log", "a") as out:
                    subprocess.run([py, "analysis/bfcl_mt/bfcl.py", "generate", "--model", f"iphone-{SLM}-dac-{cond}",
                                    "--run-ids"], cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT)
                if has_result(root, cond, entry):
                    durations.append(time.time() - started + waited)
            if not has_result(root, cond, entry):
                failures += 1
                say(f"FAILED {cond} {entry}")
                report("rodando", i, cond)
    for cond in conds:
        with open(root / "bfcl.log", "a") as out:
            subprocess.run([py, "analysis/bfcl_mt/bfcl.py", "evaluate", "--model", f"iphone-{SLM}-dac-{cond}",
                            "--test-category", "multi_turn_base", "--partial-eval"], cwd=ROOT, env=env, stdout=out,
                           stderr=subprocess.STDOUT)
    say("== done")
    report("terminou" if run == runs[-1] else "rodando", None, None)


if __name__ == "__main__":
    main()
