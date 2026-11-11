"""Smoke das estratégias do InferenceServer no iPhone, com uma requisição no formato do iOSWorld.

Falha se alguma estratégia não emite a tool, ou se o prefix cache muda a resposta do Direct.
Uso: python analysis/iosworld/smoke_strategies.py [slm] [url]
"""
import json
import sys
import time
import urllib.request

SLM = sys.argv[1] if len(sys.argv) > 1 else "qwen35"
URL = (sys.argv[2] if len(sys.argv) > 2 else "http://iPhone-de-David.local:8080") + "/v1/chat/completions"

TOOLS = [{"type": "function", "function": {
    "name": f"mcp__clock__{name}", "description": desc,
    "parameters": {"type": "object", "properties": props, "required": list(props)}}}
    for name, desc, props in [
        ("add_alarm", "Add an alarm. time like '6:45 AM'.", {"time": {"type": "string"}, "label": {"type": "string"}}),
        ("list_alarms", "List alarms.", {}),
        ("toggle_alarm", "Toggle an alarm by label.", {"label_or_index": {"type": "string"}}),
        ("navigate_to_tab", "Open a Clock tab.", {"tab": {"type": "string"}}),
    ]]
MESSAGES = [
    {"role": "system", "content": "You control an iPhone through tools. Call one tool per step. " * 20},
    {"role": "user", "content": "Set a new alarm for 6:45 AM labeled 'Gym' in the Clock app."},
]


def call(model):
    body = json.dumps({"model": model, "max_tokens": 4096, "messages": MESSAGES, "tools": TOOLS}).encode()
    request = urllib.request.Request(URL, body, {"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(request, timeout=600) as response:
        out = json.load(response)
    calls = out["choices"][0]["message"].get("tool_calls") or []
    # A ordem das chaves em `arguments` vem de um dicionário Swift e muda entre chamadas.
    first = calls and (calls[0]["function"]["name"], json.loads(calls[0]["function"]["arguments"]))
    print(f"{model:28} {time.time() - started:6.1f}s out={out['usage']['completion_tokens']:4} call={first}")
    return first or None


strategies = ["direct", "budget_64", "plan_act"] + ([] if SLM == "lfm25" else ["nothink"])
results = {s: call(f"{SLM}:{s}") for s in strategies}
cold = call(f"{SLM}:direct:prefix")
warm = call(f"{SLM}:direct:prefix")

missing = [s for s, first in results.items() if first is None]
assert not missing, f"sem tool call: {missing}"
assert cold == warm == results["direct"], "prefix cache mudou a resposta do Direct"
print("ok")
