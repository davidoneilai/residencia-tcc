"""PACA (Progress-Aware Compute Allocation) para o BFCL Multi-Turn: o orçamento de raciocínio e a recuperação de cada
passo dependem do progresso do turno. Sem treino, sem outra chamada de LLM; usa o KV incremental e o `think_budget`
por requisição que o servidor já tem.

Cada passo do turno é classificado pelo que produziu (como em `paca_signals.py`):
`new` (chamadas inéditas, sem erro, resultado inédito) é progresso; `repeat`, `same_result` e `error` são estagnação.
Raciocínio fechado à força (`forced_close` do servidor) que não trouxe progresso também conta como estagnação.

Alocação (sinais dos logs DEV, `paca_signals.py`):
- início do turno (planejar): `B_PLAN`. Raciocínio que passa de ~256 tokens sem fechar quase nunca fecha (3/270 passos
  da `reason-kv` fecharam entre 256 e 1023; 12 foram ao teto, todos em entradas erradas);
- depois de progresso (continuar): `B_CONT`; o modelo só encadeia a próxima chamada ou responde (mediana 51 tokens);
- primeira estagnação: volta a `B_PLAN` (replanejar), sem nota;
- segunda estagnação seguida, ou chamada repetida (a repetição prende: 45/57 passos depois de uma repetição repetem):
  nota contextual curta (a evidência: chamada e resultado, ou o erro) + `B_PLAN`;
- estagnação depois da nota sem progresso entre elas: para o turno. Progresso depois da nota zera a estagnação
  e libera outra nota, até `MAX_NOTES` por turno. Parar não é sucesso: o BFCL avalia o estado que ficou.
"""
import json

from controller import _calls, _get, is_error
from dac import DACHandler, NOTE, _short, _turn

B_PLAN = 256
B_CONT = 128
MAX_NOTES = 2


def classify(calls, results, seen_calls, seen_results):
    if any(c in seen_calls for c in calls):
        return "repeat"
    if any(is_error(r) for r in results):
        return "error"
    if results and all(r in seen_results for r in results):
        return "same_result"
    return "new"


def _results(turn, index):
    """Respostas de ferramenta do passo `index` (até a próxima mensagem que não é de tool)."""
    out = []
    for m in turn[index + 1:]:
        if _get(m, "role") != "tool":
            break
        out.append(str(_get(m, "content")))
    return out


def decide(messages, forced):
    """(orçamento | 'stop', gatilho, nota | None, estado) do próximo passo, só a partir do turno atual.
    `forced[i]` = o servidor fechou o raciocínio à força no i-ésimo passo LLM do turno."""
    turn = _turn(messages)
    seen_calls, seen_results, kinds, notes, stagnation = [], set(), [], [], 0
    last_note = None
    for i, m in enumerate(turn):
        role = _get(m, "role")
        if role == "user":  # nota da PACA
            notes.append(len(kinds))
            last_note = len(kinds)
            continue
        if role != "assistant":
            continue
        calls = _calls(m)
        results = _results(turn, i)
        kind = classify(calls, results, seen_calls, seen_results) if calls else "text"
        if kind != "new" and len(kinds) < len(forced) and forced[len(kinds)]:
            kind += "+forced"
        kinds.append(kind)
        seen_calls += calls
        seen_results |= set(results)
        stagnation = 0 if kind == "new" else stagnation + 1
    state = {"kinds": kinds, "stagnation": stagnation, "notes": len(notes)}
    if not kinds:
        return B_PLAN, "plan", None, state
    last = kinds[-1]
    if last == "new":
        return B_CONT, "continue", None, state
    after_note = last_note is not None and kinds[last_note:] and "new" not in kinds[last_note:]
    if after_note:
        return "stop", "recovery_failed_" + last.split("+")[0], None, state
    if (stagnation >= 2 or last.startswith("repeat")) and len(notes) < MAX_NOTES:
        return B_PLAN, "recover_" + last.split("+")[0], note_for(turn, last), state
    if stagnation >= 2:
        return "stop", "stagnation_" + last.split("+")[0], None, state
    return B_PLAN, "replan_" + last.split("+")[0], None, state


def note_for(turn, kind):
    steps = [(i, _calls(m)) for i, m in enumerate(turn) if _get(m, "role") == "assistant"]
    last_index, last_calls = steps[-1]
    if kind.startswith(("repeat", "same_result")) and last_calls:
        name, args = last_calls[-1]
        first = next((i for i, cs in steps if last_calls[-1] in cs), last_index)
        result = _short((_results(turn, first) or [""])[0])
        return (f"{NOTE} You already called {name}({args}) in this task and it returned: {result}. "
                "Calling it again returns the same result. Use that result to take the next step the request needs, "
                "or reply to the user if the request is already complete.")
    results = _results(turn, last_index)
    name = last_calls[-1][0] if last_calls else "the function"
    return (f"{NOTE} The last function calls did not make progress. Last result from {name}: "
            f"{_short(results[-1] if results else '')}. Check that function's parameters in the tool definitions and "
            "the current state before calling again, try a different function, or reply to the user if the request "
            "cannot be completed.")


class PACAHandler(DACHandler):
    """Igual ao `DACHandler` (mesmo servidor `<slm>:direct:kv`, mesmo stop), com o orçamento por passo da PACA."""

    def _add_next_turn_user_message_FC(self, inference_data, user_message):
        self._forced = []
        return super()._add_next_turn_user_message_FC(inference_data, user_message)

    def inference_multi_turn_FC(self, test_entry, *args, **kwargs):
        self._forced = []
        return super().inference_multi_turn_FC(test_entry, *args, **kwargs)

    def _query_FC(self, inference_data):
        parts = self.model_name.split(":")
        slm, suffix = parts[0], ":".join(parts[2:])
        budget, trigger, note, state = decide(inference_data["message"], self._forced)
        if note:
            inference_data["message"].append({"role": "user", "content": note})
        self._write(self.log_path, {"condition": self.condition, "slm": slm, "strategy": "direct",
                                    "budget": budget, "trigger": trigger, "note_chars": len(note or ""), **state})
        if budget == "stop":
            return self._stop(inference_data)
        self.extra_body = {**(type(self).extra_body or {}), "think_budget": budget}
        kwargs = {"messages": inference_data["message"], "model": f"{slm}:direct" + (f":{suffix}" if suffix else ""),
                  "temperature": self.temperature, "store": False}
        if inference_data["tools"]:
            kwargs["tools"] = inference_data["tools"]
        inference_data["inference_input_log"] = {"message": repr(inference_data["message"]),
                                                 "tools": inference_data["tools"]}
        response, latency = self.generate_with_backoff(**kwargs)
        device = (getattr(response, "model_extra", None) or {}).get("device", {})
        self._forced.append(bool(device.get("forced_close")))
        return response, latency


def self_check():
    def call(name, **args):
        return {"type": "function", "function": {"name": name, "arguments": json.dumps(args)}}

    def step(name, result, **args):
        return [{"role": "assistant", "tool_calls": [call(name, **args)]}, {"role": "tool", "content": result}]

    user = {"role": "user", "content": "list files in temp"}
    assert decide([user], [])[:2] == (B_PLAN, "plan")
    ok = [user] + step("ls", '{"current_directory_content": ["temp"]}', a=True)
    assert decide(ok, [False])[:2] == (B_CONT, "continue")
    err = ok + step("cd", '{"error": "cd: no such directory"}', folder="tmp")
    assert decide(err, [False, False])[:2] == (B_PLAN, "replan_error")
    err2 = err + step("cat", '{"error": "cat: no such file"}', file_name="x")
    budget, trigger, note, _ = decide(err2, [False] * 3)
    assert (budget, trigger) == (B_PLAN, "recover_error") and note.startswith(NOTE) and "cat" in note
    noted = err2 + [{"role": "user", "content": note}]
    assert len(_turn(noted)) == len(noted) - 1
    assert decide(noted + step("cd", '{"error": "x"}', folder="y"), [False] * 4)[:2] == ("stop", "recovery_failed_error")
    healed = noted + step("cd", '{"current_working_directory": "temp"}', folder="temp")
    assert decide(healed, [False] * 4)[:2] == (B_CONT, "continue")
    # Progresso depois da nota libera outra recuperação (até MAX_NOTES).
    rep = healed + step("cd", '{"current_working_directory": "temp"}', folder="temp")
    assert decide(rep, [False] * 5)[1] == "recover_repeat"
    # Repetição prende: nota já na primeira.
    rep1 = ok + step("ls", '{"current_directory_content": ["temp"]}', a=True)
    assert decide(rep1, [False, False])[1] == "recover_repeat"
    # Raciocínio forçado com progresso é progresso; sem progresso marca o passo.
    assert decide(ok, [True])[1] == "continue"
    assert decide(err, [False, True])[3]["kinds"][-1] == "error+forced"
    # Turno novo zera tudo.
    assert decide(rep1 + [{"role": "user", "content": "now post it"}], [])[:2] == (B_PLAN, "plan")


if __name__ == "__main__":
    self_check()
    print("ok")
