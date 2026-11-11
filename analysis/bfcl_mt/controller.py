"""Política adaptativa A para o BFCL Multi-Turn, no cliente: escolhe `<slm>:<estratégia>` a cada passo.

Uma regra para os quatro SLMs, sem gold e sem treino:
- padrão = a melhor fixa do modelo no BFCL AST (Semana 8);
- `slow` (Direct, thinking ligado) no passo seguinte a um sinal da trajetória: a tool devolveu erro,
  ou o modelo repetiu uma chamada idêntica neste turno;
- `stop`: encerra o turno sem chamar o modelo quando a mesma chamada já saiu `REPEAT_STOP` vezes,
  ou quando houve `ERROR_STOP` erros seguidos.
A muda só por decisão no DEV; congelada antes do TESTE (ver `FROZEN`).
"""
import json
import time
from types import SimpleNamespace

from bfcl_eval.model_handler.api_inference.openai_completion import OpenAICompletionsHandler

BEST_FIXED = {"qwen35": "direct", "lfm25": "direct", "minicpm5": "nothink", "gemma4": "nothink"}
SLOW = "direct"
REPEAT_STOP = 3
ERROR_STOP = 3
FROZEN = False
ERROR_CUES = ("error", "not found", "invalid", "does not exist", "no such", "failed", "unable",
              "cannot", "not allowed", "denied", "warning", "insufficient")


def _get(obj, key, default=None):
    return obj.get(key, default) if isinstance(obj, dict) else getattr(obj, key, default)


def _calls(message):
    """(nome, args normalizados) das tool calls de uma mensagem do assistente."""
    out = []
    for call in _get(message, "tool_calls") or []:
        fn = _get(call, "function")
        try:
            args = json.dumps(json.loads(_get(fn, "arguments") or "{}"), sort_keys=True)
        except (TypeError, ValueError):
            args = str(_get(fn, "arguments"))
        out.append((_get(fn, "name"), args))
    return out


def is_error(text):
    lower = str(text).lower()
    return any(cue in lower for cue in ERROR_CUES)


def decide(messages, base):
    """(estratégia | 'stop', gatilho) para o próximo passo, só a partir do histórico do turno atual."""
    start = max((i for i, m in enumerate(messages) if _get(m, "role") == "user"), default=-1) + 1
    turn = messages[start:]
    calls = [c for m in turn if _get(m, "role") == "assistant" for c in _calls(m)]
    if calls and calls.count(calls[-1]) >= REPEAT_STOP:
        return "stop", "repeat_stop"
    tools = [_get(m, "content") for m in turn if _get(m, "role") == "tool"]
    streak = 0
    for content in reversed(tools):
        if not is_error(content):
            break
        streak += 1
    if streak >= ERROR_STOP:
        return "stop", "error_stop"
    if streak:
        return SLOW, "tool_error"
    if calls and calls.count(calls[-1]) >= 2:
        return SLOW, "repeat"
    return base, "default"


class AdaptiveHandler(OpenAICompletionsHandler):
    """`model_name` = `<slm>:adaptive[:prefix]`; cada passo vai ao servidor como `<slm>:<estratégia>[:prefix]`."""

    log_path = None

    def inference_multi_turn_FC(self, test_entry, *args, **kwargs):
        self._entry = test_entry["id"]
        self._step = 0
        return super().inference_multi_turn_FC(test_entry, *args, **kwargs)

    def _query_FC(self, inference_data):
        parts = self.model_name.split(":")
        slm, suffix = parts[0], ":".join(parts[2:])
        strategy, trigger = decide(inference_data["message"], BEST_FIXED[slm])
        self._log({"id": getattr(self, "_entry", None), "step": self._step, "slm": slm,
                   "strategy": strategy, "trigger": trigger})
        self._step += 1
        if strategy == "stop":
            # Resposta vazia: o harness do BFCL encerra o turno como faz com texto sem tool call.
            message = SimpleNamespace(role="assistant", content="", tool_calls=None)
            reply = SimpleNamespace(choices=[SimpleNamespace(message=message)],
                                    usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0))
            inference_data["message"].append({"role": "assistant", "content": ""})
            self._stopped = True
            return reply, 0.0
        name = f"{slm}:{strategy}" + (f":{suffix}" if suffix else "")
        kwargs = {"messages": inference_data["message"], "model": name, "temperature": self.temperature,
                  "store": False}
        if inference_data["tools"]:
            kwargs["tools"] = inference_data["tools"]
        inference_data["inference_input_log"] = {"message": repr(inference_data["message"]),
                                                 "tools": inference_data["tools"]}
        return self.generate_with_backoff(**kwargs)

    def _add_assistant_message_FC(self, inference_data, model_response_data):
        # O stop já gravou a própria mensagem; não duplica.
        if getattr(self, "_stopped", False):
            self._stopped = False
            return inference_data
        return super()._add_assistant_message_FC(inference_data, model_response_data)

    def _log(self, row):
        if self.log_path:
            with open(self.log_path, "a") as f:
                f.write(json.dumps({"time": time.strftime("%FT%T"), **row}) + "\n")


def self_check():
    def call(name, **args):
        return {"type": "function", "function": {"name": name, "arguments": json.dumps(args)}}

    user = {"role": "user", "content": "cd to docs and list files"}
    assert decide([user], "nothink") == ("nothink", "default")
    ok = [user, {"role": "assistant", "tool_calls": [call("cd", folder="docs")]},
          {"role": "tool", "content": '{"current_working_directory": "docs"}'}]
    assert decide(ok, "nothink") == ("nothink", "default")
    err = ok[:2] + [{"role": "tool", "content": "Error during execution: no such directory"}]
    assert decide(err, "nothink") == ("direct", "tool_error")
    again = ok + [{"role": "assistant", "tool_calls": [call("cd", folder="docs")]},
                  {"role": "tool", "content": "{}"}]
    assert decide(again, "direct") == ("direct", "repeat")
    loop = again + [{"role": "assistant", "tool_calls": [call("cd", folder="docs")]},
                    {"role": "tool", "content": "{}"}]
    assert decide(loop, "direct") == ("stop", "repeat_stop")
    errors = [user] + [m for _ in range(3) for m in (
        {"role": "assistant", "tool_calls": [call("ls", n=_)]}, {"role": "tool", "content": '{"error": "x"}'})]
    assert decide(errors, "nothink") == ("stop", "error_stop")
    # Só o turno atual conta: o loop antigo não para o turno novo.
    assert decide(loop + [{"role": "user", "content": "now go back"}], "nothink") == ("nothink", "default")
    # Mensagens do SDK (objetos com atributos) valem igual a dicts.
    obj = SimpleNamespace(role="assistant", tool_calls=[SimpleNamespace(
        function=SimpleNamespace(name="cd", arguments='{"folder": "docs"}'))])
    assert _calls(obj) == [("cd", '{"folder": "docs"}')]


if __name__ == "__main__":
    self_check()
    print("ok")
