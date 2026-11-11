"""DAC (Dynamic Agentic Compute) para o BFCL Multi-Turn: política A + recuperação curta antes de parar.

A (controller.py) para o turno na 3ª chamada idêntica ou no 3º erro seguido. DAC detecta antes e tenta recuperar:
- detecção: a última chamada já saiu neste turno (mesmo nome e argumentos) ou `ERROR_DETECT` erros seguidos;
- intervenção: uma mensagem curta no histórico (papel user, prefixo `NOTE`) que cita a chamada repetida ou o erro.
  O resultado da ferramenta não muda; a nota só aponta para ele. Uma por turno;
- tentativa extra: o modelo gera mais um passo com a nota no contexto;
- se esse passo (ou qualquer um depois dele no turno) repetir uma chamada ou devolver erro, o turno para,
  como no `stop` de A. Parar não é sucesso: o BFCL avalia o estado que ficou.
Toda decisão vai para `log_path` (uma linha por passo) com o gatilho e o tamanho da nota.

Seletiva (DACS) = DAC + guardas de decode no servidor (`think_budget`, `repeat_guard`), sem outra chamada de LLM.
`TraceMixin` grava o bloco `device` (prefill, decode, TTFT, térmica, memória) de cada passo de qualquer condição.
"""
import json
import os
import time
from types import SimpleNamespace

from bfcl_eval.model_handler.api_inference.openai_completion import OpenAICompletionsHandler

from controller import BEST_FIXED, _calls, _get, is_error

# Variantes SFT herdam a estratégia da base. MiniCPM5 fica em nothink: o `</think>` dele não é um token só,
# então o think_budget não fecha o raciocínio e com thinking o SFT entra em laço ("Wait, but…", 2026-11-08).
DAC_FIXED = {**BEST_FIXED, "qwen35_sft": BEST_FIXED["qwen35"], "minicpm5_sft": BEST_FIXED["minicpm5"]}
# LFM3: a estratégia sai da 1ª rodada do DEV no build novo (PROTOCOL-lfm3.md); a cadeia exporta `DAC_FIXED_LFM3`.
DAC_FIXED["lfm3"] = os.environ.get("DAC_FIXED_LFM3", "direct")

ERROR_DETECT = 2
STEP_TIMEOUT = 240
NOTE = "[Harness note]"
SNIPPET = 200


def _short(text):
    text = " ".join(str(text).split())
    return text if len(text) <= SNIPPET else text[:SNIPPET] + "…"


def _turn(messages):
    """Mensagens do turno atual: depois da última pergunta real do usuário (a nota não abre turno)."""
    start = max((i for i, m in enumerate(messages) if _get(m, "role") == "user"
                 and not str(_get(m, "content", "")).startswith(NOTE)), default=-1) + 1
    return messages[start:]


def _tool_after(turn, index):
    """Conteúdo das respostas de ferramenta depois da mensagem `index` do turno."""
    return [_get(m, "content") for m in turn[index + 1:] if _get(m, "role") == "tool"]


def decide(messages, base):
    """(estratégia | 'stop', gatilho, nota | None) para o próximo passo, só a partir do turno atual."""
    turn = _turn(messages)
    noted = [i for i, m in enumerate(turn) if _get(m, "role") == "user"]
    steps = [(i, _calls(m)) for i, m in enumerate(turn) if _get(m, "role") == "assistant"]
    calls = [c for _, cs in steps for c in cs]
    if not steps:
        return base, "default", None
    last_index, last_calls = steps[-1]
    last_results = _tool_after(turn, last_index)
    repeated = bool(calls) and calls.count(calls[-1]) >= 2
    if noted:
        # Depois da nota: qualquer repetição ou erro encerra o turno.
        after = [cs for i, cs in steps if i > noted[0]]
        if not after:
            return base, "default", None
        if repeated:
            return "stop", "recovery_failed_repeat", None
        if any(is_error(r) for r in last_results):
            return "stop", "recovery_failed_error", None
        return base, "recovered" if len(after) == 1 else "default", None
    if repeated:
        name, args = calls[-1]
        first = next(i for i, cs in steps if calls[-1] in cs)
        result = _short((_tool_after(turn, first) or [""])[0])
        return base, "detect_repeat", (
            f"{NOTE} You already called {name}({args}) in this task and it returned: {result}. "
            "Calling it again returns the same result. Use that result to take the next step the request needs, "
            "or reply to the user if the request is already complete.")
    tools = [_get(m, "content") for m in turn if _get(m, "role") == "tool"]
    streak = 0
    for content in reversed(tools):
        if not is_error(content):
            break
        streak += 1
    if streak >= ERROR_DETECT:
        name = last_calls[-1][0] if last_calls else "the function"
        return base, "detect_error", (
            f"{NOTE} Your last {streak} function calls failed. Last error from {name}: {_short(tools[-1])}. "
            "Check that function's parameters in the tool definitions and the current state before calling again, "
            "try a different function, or reply to the user if the request cannot be completed.")
    return base, "default", None


class TraceMixin:
    """Uma linha por passo em `trace_path`: id, turno, passo, condição, latência do cliente e o `device` do iPhone."""

    trace_path = None
    condition = None
    extra_body = None

    def inference_multi_turn_FC(self, test_entry, *args, **kwargs):
        self._entry, self._turn_index, self._tstep = test_entry["id"], 0, 0
        # Um passo leva < 2 min. Sem isto, um iPhone que travou (app fora do primeiro plano) prende o cliente 600 s e o
        # retry do SDK continua a trajetória no meio, sobre um cache frio; falhando rápido, o runner refaz a entrada.
        self.client = self.client.with_options(timeout=STEP_TIMEOUT, max_retries=0)
        return super().inference_multi_turn_FC(test_entry, *args, **kwargs)

    def _add_next_turn_user_message_FC(self, inference_data, user_message):
        self._turn_index += 1
        self._tstep = 0
        return super()._add_next_turn_user_message_FC(inference_data, user_message)

    def generate_with_backoff(self, **kwargs):
        if self.extra_body:
            kwargs["extra_body"] = self.extra_body
        response, latency = super().generate_with_backoff(**kwargs)
        extra = getattr(response, "model_extra", None) or {}
        message = response.choices[0].message
        self._write(self.trace_path, {
            "condition": self.condition, "server_model": kwargs.get("model"), "client_s": latency,
            "messages": len(kwargs.get("messages", [])), "prompt_tokens": response.usage.prompt_tokens,
            "completion_tokens": response.usage.completion_tokens,
            "finish": response.choices[0].finish_reason,
            "calls": [c.function.name for c in message.tool_calls or []], "device": extra.get("device", {})})
        self._tstep += 1
        return response, latency

    def _write(self, path, row):
        if path:
            with open(path, "a") as f:
                f.write(json.dumps({"time": time.strftime("%FT%T"), "id": getattr(self, "_entry", None),
                                    "turn": getattr(self, "_turn_index", None),
                                    "step": getattr(self, "_tstep", None), **row}) + "\n")


class TracedHandler(TraceMixin, OpenAICompletionsHandler):
    """Estratégia fixa com o rastreio do `device`."""


class DACHandler(TraceMixin, OpenAICompletionsHandler):
    """`model_name` = `<slm>:dac[:cache]`; cada passo vai ao servidor como `<slm>:<melhor fixa>[:cache]`."""

    log_path = None

    def _query_FC(self, inference_data):
        parts = self.model_name.split(":")
        slm, suffix = parts[0], ":".join(parts[2:])
        strategy, trigger, note = decide(inference_data["message"], DAC_FIXED[slm])
        if note:
            inference_data["message"].append({"role": "user", "content": note})
        self._write(self.log_path, {"condition": self.condition, "slm": slm, "strategy": strategy, "trigger": trigger,
                                    "note_chars": len(note or "")})
        if strategy == "stop":
            return self._stop(inference_data)
        name = f"{slm}:{strategy}" + (f":{suffix}" if suffix else "")
        kwargs = {"messages": inference_data["message"], "model": name, "temperature": self.temperature,
                  "store": False}
        if inference_data["tools"]:
            kwargs["tools"] = inference_data["tools"]
        inference_data["inference_input_log"] = {"message": repr(inference_data["message"]),
                                                 "tools": inference_data["tools"]}
        return self.generate_with_backoff(**kwargs)

    def _stop(self, inference_data):
        """Mesmo stop de A: resposta vazia, o harness do BFCL encerra o turno."""
        message = SimpleNamespace(role="assistant", content="", tool_calls=None)
        reply = SimpleNamespace(choices=[SimpleNamespace(message=message)],
                                usage=SimpleNamespace(prompt_tokens=0, completion_tokens=0))
        inference_data["message"].append({"role": "assistant", "content": ""})
        self._stopped = True
        self._tstep += 1
        return reply, 0.0

    def _add_assistant_message_FC(self, inference_data, model_response_data):
        if getattr(self, "_stopped", False):
            self._stopped = False
            return inference_data
        return super()._add_assistant_message_FC(inference_data, model_response_data)


def self_check():
    def call(name, **args):
        return {"type": "function", "function": {"name": name, "arguments": json.dumps(args)}}

    def step(name, result, **args):
        return [{"role": "assistant", "tool_calls": [call(name, **args)]}, {"role": "tool", "content": result}]

    user = {"role": "user", "content": "list files in temp"}
    assert decide([user], "direct") == ("direct", "default", None)
    once = [user] + step("ls", '{"current_directory_content": ["temp"]}', a=True)
    assert decide(once, "direct")[:2] == ("direct", "default")
    twice = once + step("ls", '{"current_directory_content": ["temp"]}', a=True)
    strategy, trigger, note = decide(twice, "direct")
    assert (strategy, trigger) == ("direct", "detect_repeat") and note.startswith(NOTE) and "temp" in note
    noted = twice + [{"role": "user", "content": note}]
    # A nota não abre turno novo: a repetição de antes continua no turno.
    assert len(_turn(noted)) == len(noted) - 1
    assert decide(noted, "direct") == ("direct", "default", None)
    progress = noted + step("cd", '{"current_working_directory": "temp"}', folder="temp")
    assert decide(progress, "direct") == ("direct", "recovered", None)
    later = progress + step("ls", '{"current_directory_content": ["a.txt"]}', a=False)
    assert decide(later, "direct") == ("direct", "default", None)
    assert decide(noted + step("ls", "{}", a=True), "direct")[:2] == ("stop", "recovery_failed_repeat")
    failed = noted + step("cd", '{"error": "cd: no such directory"}', folder="tmp")
    assert decide(failed, "direct")[:2] == ("stop", "recovery_failed_error")
    errors = [user] + step("ls", '{"error": "x"}', folder="a") + step("cat", '{"error": "y"}', file_name="b")
    strategy, trigger, note = decide(errors, "direct")
    assert trigger == "detect_error" and "cat" in note and "y" in note
    one_error = [user] + step("ls", '{"error": "x"}', folder="a")
    assert decide(one_error, "direct")[:2] == ("direct", "default")
    # Turno novo zera tudo, inclusive a nota do turno anterior.
    assert decide(failed + [{"role": "user", "content": "now post it"}], "direct") == ("direct", "default", None)


if __name__ == "__main__":
    self_check()
    print("ok")
