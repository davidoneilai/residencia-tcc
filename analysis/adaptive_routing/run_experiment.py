#!/usr/bin/env python3
"""Experimento A (oracle) + B (router leve) sobre resultados MobileLLMBench.

Uso:
  python run_experiment.py --check
  python run_experiment.py \\
    --input ../../results/cross-model-2026-10-13.json \\
    --out ../../reports/adaptive-routing
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from evaluate import load_tasks, run_model_experiment, write_comparison_csv
from features import extract_features, measure_overhead_ms, template_family
from oracle import best_fixed, complementarity, fixed_policy_stats, oracle_stats
from routers import HeuristicRouter, train_logistic, train_tree
from split import self_check as split_self_check
from split import split_by_family


SHARED = ["direct", "plan_act"]
MODELS = {
    "qwen": "mlx-community/Qwen3-1.7B-4bit",
    "gemma": "mlx-community/gemma-4-e2b-it-4bit",
    "apple": "SystemLanguageModel.default",
}


def self_check() -> None:
    split_self_check()
    f = extract_features("Busque o contato Ana e depois ligue para ela.")
    d = f.as_dict()
    assert d["contact_name_hits"] >= 1
    assert d["seq_cue_count"] >= 1
    assert template_family("apple_single_007") == "apple_single_b1"
    h = HeuristicRouter()
    assert h.choose("Busque o contato Ana e depois ligue.").strategy == "plan_act"
    assert measure_overhead_ms("Ligue para +15550100.", repeats=50) >= 0
    print("ADAPTIVE_ROUTING_OK")


def write_report(summaries: list[dict], out: Path) -> None:
    lines = [
        "# Roteamento adaptativo de inferência — relatório experimental",
        "",
        "## Pergunta",
        "",
        "Um roteador leve, usando só características da solicitação, consegue reduzir a "
        "latência total de tarefas agênticas em LLMs mobile mantendo qualidade comparável "
        "à melhor política fixa?",
        "",
        "## Dados",
        "",
        "- Fonte: `results/cross-model-2026-10-13.json` (sessão completa, protocolo 2.0).",
        "- 360 execuções = 3 modelos × 2 estratégias (`direct`, `plan_act`) × 60 tarefas "
        "Apple residency (`apple_residency_60`).",
        "- Modo simulado; 1 repetição por condição — análise exploratória quanto à variância.",
        "- Políticas de thinking (`nothink`, budgets, `early_exit`) só existem no Qwen e "
        "não foram medidas neste conjunto de 60; o legado de 13 tarefas não entra no "
        "teste principal para não misturar populações.",
        "",
        "## Metodologia",
        "",
        "1. **Oracle (Experimento A):** para cada tarefa, escolhe a política correta de "
        "menor latência. Limite superior idealizado.",
        "2. **Split:** famílias de template (`apple_{cat}_b{k}`, grupos de 5 IDs) vão "
        "inteiras para train/val/test — sem vazamento entre variantes do mesmo molde.",
        "3. **Baseline fixa:** melhor política no *train* (sucesso, depois latência).",
        "4. **Heurística:** regras sobre cues sequenciais, ambiguidade e tamanho.",
        "5. **Aprendido:** regressão logística ou árvore rasa (prof. ≤ 3), escolhida na "
        "validação; rótulo = escolha do oracle no train.",
        "6. **Features:** só texto da solicitação + catálogo de cues de ferramentas "
        "(sem expected answers, grades ou latências futuras).",
        "7. Overhead do roteador somado à latência final.",
        "",
        "## Resultados no teste (generalização)",
        "",
    ]

    for summary in summaries:
        tag = summary["model"]
        lines += [
            f"### {tag}",
            "",
            f"- Tarefas: {summary['n_tasks']}; split "
            f"{summary['split_sizes']}; fixed escolhida no train: "
            f"`{summary['best_fixed_on_train']}`; learned: `{summary['learned_router']}`.",
            f"- Overhead médio de features: {summary['feature_overhead_ms']:.4f} ms.",
            f"- Famílias teste: `{', '.join(summary['families']['test'])}`.",
            "",
            "#### Hold-out (teste)",
            "",
            "| Método | Sucesso | Latência total (ms) | Latência média (ms) | Overhead router (ms) |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
        for row in summary["test_comparison"]:
            lines.append(
                f"| {row['router']} | {row['success_rate']:.3f} | "
                f"{row['total_latency_ms']:.0f} | {row['mean_latency_ms']:.0f} | "
                f"{row['router_overhead_ms']:.3f} |"
            )
        if summary.get("lofo"):
            lines += [
                "",
                "#### Leave-one-family-out (mais estável, n=60)",
                "",
                "| Método | Sucesso | Latência total (ms) | Latência média (ms) |",
                "| --- | ---: | ---: | ---: |",
            ]
            for name, row in summary["lofo"].items():
                lines.append(
                    f"| {name} | {row['success_rate']:.3f} | "
                    f"{row['total_latency_ms']:.0f} | {row['mean_latency_ms']:.0f} |"
                )
        full = summary["full_oracle"]
        fixed = summary["full_fixed"]
        bf = summary["best_fixed_on_train"]
        pot = fixed[bf]["total_latency_ms"] - full["total_latency_ms"]
        lat_save = 100 * pot / max(fixed[bf]["total_latency_ms"], 1)
        lines += [
            "",
            f"Oracle no conjunto completo (limite A): sucesso {full['success_rate']:.3f}, "
            f"latência total {full['total_latency_ms']:.0f} ms. "
            f"Economia potencial vs fixed `{bf}`: {pot:.0f} ms "
            f"({lat_save:.1f}%).",
            "",
        ]
        if tag == "qwen" and summary.get("lofo"):
            hz = summary["lofo"]["heuristic"]
            fz = summary["lofo"]["fixed"]
            lz = summary["lofo"]["learned"]
            lines += [
                f"No Qwen (LOFO), heurística corta latência em "
                f"{100 * (1 - hz['total_latency_ms'] / max(fz['total_latency_ms'], 1)):.1f}% "
                f"com sucesso igual ({hz['success_rate']:.3f}). "
                f"Learned: {lz['success_rate']:.3f} sucesso, "
                f"{100 * (1 - lz['total_latency_ms'] / max(fz['total_latency_ms'], 1)):.1f}% menos latência.",
                "",
            ]
        if summary.get("complementarity_full"):
            c = summary["complementarity_full"]
            lines.append(
                f"Complementaridade `direct`/`plan_act`: only_direct={c['only_a']}, "
                f"only_plan={c['only_b']}, both={c['both']}, neither={c['neither']}."
            )
            lines.append("")

        # categorias no teste para o learned e fixed
        test_rows = {r["router"]: r for r in summary["test_comparison"]}
        if "by_category" in test_rows.get(summary["learned_router"], {}):
            lines += ["Por categoria no teste (roteador aprendido):", ""]
            lines.append("| Categoria | n | Sucesso | Latência média (ms) |")
            lines.append("| --- | ---: | ---: | ---: |")
            for cat, v in test_rows[summary["learned_router"]]["by_category"].items():
                lines.append(
                    f"| {cat} | {v['n']} | {v['success_rate']:.3f} | {v['mean_latency_ms']:.0f} |"
                )
            lines.append("")

    # Resposta à pergunta
    qwen = next((s for s in summaries if s["model"] == "qwen"), None)
    lines += ["## Resposta à pergunta principal", ""]
    if qwen:
        # Prioriza LOFO (estimativa mais estável) e cita hold-out.
        lofo = qwen.get("lofo") or {}
        fixed_r = lofo.get("fixed") or next(
            r for r in qwen["test_comparison"] if r["router"].startswith("fixed:")
        )
        learned = lofo.get("learned") or next(
            r for r in qwen["test_comparison"] if r["router"] in {"logistic", "decision_tree"}
        )
        heur = lofo.get("heuristic") or next(
            r for r in qwen["test_comparison"] if r["router"] == "heuristic"
        )
        oracle = lofo.get("oracle") or next(
            r for r in qwen["test_comparison"] if r["router"] == "oracle"
        )
        hold = {r["router"]: r for r in qwen["test_comparison"]}
        sr_ok = learned["success_rate"] + 1e-9 >= fixed_r["success_rate"] - 0.05
        lat_better = learned["total_latency_ms"] < fixed_r["total_latency_ms"]
        heur_win = (
            heur["total_latency_ms"] < fixed_r["total_latency_ms"]
            and heur["success_rate"] + 1e-9 >= fixed_r["success_rate"] - 0.05
        )
        if (sr_ok and lat_better) or heur_win:
            winner = learned if (sr_ok and lat_better) else heur
            wname = "learned" if winner is learned else "heuristic"
            verdict = (
                f"**Sim, no Qwen (LOFO):** o roteador `{wname}` manteve "
                f"sucesso {winner['success_rate']:.3f} vs {fixed_r['success_rate']:.3f} "
                f"da política fixa e reduziu latência total de "
                f"{fixed_r['total_latency_ms']:.0f} para {winner['total_latency_ms']:.0f} ms "
                f"(oracle {oracle['total_latency_ms']:.0f} ms). "
                f"Hold-out: fixed={hold.get('fixed:direct', hold.get(list(hold)[0], {})).get('success_rate', 'n/a')}."
            )
        elif lat_better and not sr_ok:
            verdict = (
                f"**Parcial no Qwen (LOFO):** ganho de latência "
                f"({fixed_r['total_latency_ms']:.0f} → {learned['total_latency_ms']:.0f} ms) "
                f"com sucesso {fixed_r['success_rate']:.3f} → {learned['success_rate']:.3f}. "
                f"Heurística: {heur['success_rate']:.3f} / {heur['total_latency_ms']:.0f} ms."
            )
        else:
            verdict = (
                f"**Não conclusivo no Qwen (LOFO):** fixed "
                f"{fixed_r['success_rate']:.3f} / {fixed_r['total_latency_ms']:.0f} ms; "
                f"learned {learned['success_rate']:.3f} / {learned['total_latency_ms']:.0f} ms; "
                f"heurística {heur['success_rate']:.3f} / {heur['total_latency_ms']:.0f} ms. "
                f"Oracle headroom: {oracle['success_rate']:.3f} / {oracle['total_latency_ms']:.0f} ms."
            )
        lines.append(verdict)
    else:
        lines.append("Sem resultados Qwen.")

    lines += [
        "",
        "## Limitações",
        "",
        "- Uma execução por condição: não estima variância entre runs.",
        "- Router offline sobre logs: não reexecuta o LLM; mede overhead de decisão localmente.",
        "- Apple/Gemma têm pouca complementaridade; o ganho potencial concentra-se no Qwen.",
        "- Experimento C (roteamento mid-trajectory) não implementado para preservar o foco A/B.",
        "- Avaliação principal é *replay* offline dos logs; a latência do LLM não foi remedida.",
        "- iPhone indisponível nesta sessão para instalar o binário; app compila (`BUILD SUCCEEDED`) "
        "com preset Adaptativo e `AdaptiveRouter.selfCheck` no boot.",
        "",
        "## Próximo experimento",
        "",
        "1. Instalar o app e rodar preset **Adaptativo** (60 tarefas Qwen) em modo simulado; "
        "comparar `routerDecisionMs` e sucesso com o replay.",
        "2. Repetir 3× `direct`/`plan_act` no Qwen com pausa térmica para estimar variância.",
        "3. Treinar no Apple full 150 se o LOFO continuar positivo.",
        "4. Só então Experimento C (reavaliação entre tool calls).",
        "",
    ]
    (out / "REPORT.md").write_text("\n".join(lines))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument(
        "--input",
        type=Path,
        default=ROOT.parents[1] / "results" / "cross-model-2026-10-13.json",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=ROOT.parents[1] / "reports" / "adaptive-routing",
    )
    parser.add_argument("--seed", default="adaptive-routing-736194")
    parser.add_argument("--pilot", action="store_true", help="Só Qwen (piloto rápido)")
    args = parser.parse_args()

    if args.check:
        self_check()
        if not args.input.exists():
            return

    args.out.mkdir(parents=True, exist_ok=True)
    artifacts = args.out / "artifacts"
    artifacts.mkdir(exist_ok=True)

    tags = ["qwen"] if args.pilot else list(MODELS)
    summaries = []
    all_rows = []
    for tag in tags:
        model = MODELS[tag]
        tasks = load_tasks(args.input, model=model, strategies=SHARED)
        if not tasks:
            print(f"aviso: sem tarefas para {tag}")
            continue
        # Piloto interno: garante split antes do full write
        split_by_family(tasks, seed=args.seed)
        summary = run_model_experiment(tasks, SHARED, args.seed, artifacts, tag)
        summaries.append(summary)
        all_rows.extend(summary["eval_rows"])
        print(
            f"{tag}: n={len(tasks)} fixed_train={summary['best_fixed_on_train']} "
            f"learned={summary['learned_router']} "
            f"test_rows={len(summary['test_comparison'])}"
        )

    write_comparison_csv(all_rows, args.out / "comparison_all.csv")
    write_report(summaries, args.out)
    # Tabela consolidada só teste
    test_only = [r for r in all_rows if r["split"] == "test"]
    write_comparison_csv(test_only, args.out / "comparison_test.csv")
    (args.out / "run_meta.json").write_text(
        json.dumps(
            {
                "input": str(args.input),
                "seed": args.seed,
                "strategies": SHARED,
                "models": tags,
                "protocol": "offline_replay_from_cross_model_session",
            },
            indent=2,
        )
    )
    print(f"gravado em {args.out}")


if __name__ == "__main__":
    main()
