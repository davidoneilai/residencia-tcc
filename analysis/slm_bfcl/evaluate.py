"""Avalia sessões on-device do estudo SLM × BFCL v4 AST com o checker oficial.

Normalização (igual para todos os modelos):
1. Chamadas nativas do parser MLX (`astCalls`); sem elas, o formato nativo do MiniCPM5
   `<function name="f"><param name="k">v</param></function>` é lido do texto.
2. Valores string de parâmetros não-string são decodificados (JSON, depois literal Python),
   como o parser XML do Qwen3.5 já faz com o schema; o checker oficial decide o resto.
3. `irrelevance`: acerto = nenhuma chamada (regra oficial de `relevance_file_runner`).

    .bfcl-venv/bin/python analysis/slm_bfcl/evaluate.py session-*.json --out rows.jsonl
"""
import argparse
import ast
import json
import re
import sys
from pathlib import Path

import bfcl_eval
from bfcl_eval.constants.enums import Language
from bfcl_eval.eval_checker.ast_eval.ast_checker import ast_checker

DATA = Path(bfcl_eval.__file__).parent / "data"
CHECKER_MODEL = "Qwen_Qwen3-1.7B-FC"  # só define a regra de nomes: OSS-FC, sem underscore_to_dot
FUNC = re.compile(r'<function name="([^"]+)">(.*?)</function>', re.S)
PARAM = re.compile(r'<param name="([^"]+)">(.*?)</param>', re.S)
THINK = re.compile(r"<think>.*?</think>|<\|channel>.*?<channel\|>", re.S)
MARKERS = ("<tool_call", "<function", "<|tool_call", "[TOOL_CALLS]", "call:")


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


PROMPTS, ANSWERS = {}, {}
for category in ["simple_python", "multiple", "parallel", "parallel_multiple", "irrelevance"]:
    for r in rows(DATA / f"BFCL_v4_{category}.json"):
        PROMPTS[r["id"]] = r
    if category != "irrelevance":
        for r in rows(DATA / "possible_answer" / f"BFCL_v4_{category}.json"):
            ANSWERS[r["id"]] = r["ground_truth"]


def decode(value):
    if not isinstance(value, str):
        return value
    text = value.strip()
    if text.startswith("<![CDATA[") and text.endswith("]]>"):
        text = text[9:-3]
    for parse in (json.loads, ast.literal_eval):
        try:
            return parse(text)
        except Exception:
            pass
    return value


def coerce(args, schema):
    props = schema.get("parameters", {}).get("properties", {})
    out = {}
    for key, value in args.items():
        kind = props.get(key, {}).get("type", "string")
        out[key] = value if kind == "string" else decode(value)
    return out


def native_calls(raw):
    calls = []
    for item in json.loads(raw or "[]"):
        fn = item.get("function", item)
        calls.append((fn["name"], fn.get("arguments") or {}))
    return calls


def pythonic_calls(body):
    """`[f(a=1), m.g(b="x")]` do LFM2.5 (entre `<|tool_call_start|>`/`<|tool_call_end|>` ou nu)."""
    for chunk in reversed(re.findall(r"\[[\s\S]*?\)\s*\]", body)):
        try:
            tree = ast.parse(chunk.strip(), mode="eval").body
        except SyntaxError:
            continue
        if not isinstance(tree, ast.List) or not all(isinstance(e, ast.Call) for e in tree.elts):
            continue
        try:
            return [(ast.unparse(e.func), {k.arg: ast.literal_eval(k.value) for k in e.keywords}) for e in tree.elts]
        except ValueError:
            continue
    return []


def text_calls(text):
    body = THINK.sub("", text or "")
    if "</think>" in body:
        body = body.rsplit("</think>", 1)[1]
    found = [(name, {k: v for k, v in PARAM.findall(params)}) for name, params in FUNC.findall(body)]
    return found or pythonic_calls(body)


def grade(result):
    task_id = result["experiment"]
    entry = PROMPTS[task_id]
    category = task_id.rsplit("_", 1)[0]
    calls = native_calls(result.get("astCalls"))
    source = "native"
    if not calls:
        calls = text_calls(result.get("response"))
        source = "text_native_format" if calls else "none"
    schemas = {f["name"]: f for f in entry["function"]}
    decoded = [{name: coerce(args, schemas.get(name, {}))} for name, args in calls]
    visible = THINK.sub("", result.get("response") or "")
    format_error = not calls and any(m in visible for m in MARKERS)
    if category == "irrelevance":
        valid, error = not decoded, ([] if not decoded else ["irrelevance: chamou função"])
        kind = None if valid else "called_on_irrelevance"
    elif not decoded:
        valid, error = False, ["sem chamada"]
        kind = "format_error" if format_error else ("length" if result.get("stopReason") == "length" else "missing_call")
    else:
        verdict = ast_checker(entry["function"], decoded, ANSWERS[task_id], Language.PYTHON, category, CHECKER_MODEL)
        valid, error = verdict["valid"], verdict.get("error", [])
        etype = verdict.get("error_type", "")
        kind = None if valid else ("wrong_function" if "wrong_func" in etype or "wrong_count" in etype
                                   else "invalid_arguments")
    return {
        "task": task_id, "category": category,
        "agent": result.get("modelId") or result["model"], "model": result["model"],
        "strategy_id": result.get("strategyId") or result["strategy"], "executed": result["strategy"],
        "run": result.get("runIndex"), "phase": result.get("phase"),
        "valid": bool(valid), "failure": kind, "error": error[:2] if isinstance(error, list) else error,
        "call_source": source, "n_calls": len(decoded), "calls": decoded,
        "total_ms": result.get("totalLatencyMs") or result.get("totalMs"),
        "inference_ms": result.get("inferenceMs"), "prefill_ms": result.get("ttftMs"),
        "repeated_prefill_ms": result.get("repeatedPrefillMs"), "decode_ms": result.get("decodeLatencyMs"),
        "plan_ms": result.get("planLatencyMs"),
        "input_tokens": result.get("inputTokens"), "output_tokens": result.get("outputTokens"),
        "thinking_tokens": result.get("thinkingTokens"), "stop": result.get("stopReason"),
        "peak_mem_mb": result.get("peakMemoryMB"), "mem_after_mb": result.get("memoryAfterMB"),
        "thermal_before": result.get("thermalBefore"), "thermal_after": result.get("thermalAfter"),
        "router": result.get("routerReason") or (result.get("controllerTrace") or [None])[0],
        "app_error": result.get("error"),
    }


def self_check():
    assert text_calls('<think>x</think><function name="f"><param name="a">3</param></function>') == [("f", {"a": "3"})]
    assert text_calls('ok <|tool_call_start|>[m.f(a=1), g(b="x")]<|tool_call_end|>') == [("m.f", {"a": 1}), ("g", {"b": "x"})]
    assert coerce({"a": "3", "b": "x", "c": "[1, 2]", "d": "(1, 2)"},
                  {"parameters": {"properties": {"a": {"type": "integer"}, "b": {"type": "string"},
                                                 "c": {"type": "array"}, "d": {"type": "tuple"}}}}) \
        == {"a": 3, "b": "x", "c": [1, 2], "d": (1, 2)}
    gt = ANSWERS["simple_python_35"][0]
    name, args = next(iter(gt.items()))
    good = {name: {k: v[0] for k, v in args.items() if v and v[0] != ""}}
    fn = PROMPTS["simple_python_35"]["function"]
    assert ast_checker(fn, [good], ANSWERS["simple_python_35"], Language.PYTHON, "simple_python", CHECKER_MODEL)["valid"]
    assert not ast_checker(fn, [{name: {}}], ANSWERS["simple_python_35"], Language.PYTHON, "simple_python", CHECKER_MODEL)["valid"]


def main():
    self_check()
    parser = argparse.ArgumentParser()
    parser.add_argument("sessions", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = []
    for path in args.sessions:
        session = json.loads(path.read_text())
        for result in session["results"]:
            if result.get("dataset") != "bfcl_ast" or result.get("phase") != "measured":
                continue
            row = grade(result)
            row["session"] = path.name
            out.append(row)
    args.out.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in out))
    ok = sum(r["valid"] for r in out)
    print(f"{ok}/{len(out)} válidos → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
