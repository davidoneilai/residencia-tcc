CLOSE = "\n</think>\n\n"


def _open(prompt):
    return prompt if prompt.rstrip().endswith("<think>") else prompt + "<think>\n"


def _answer(prompt, head, thought, final):
    # Devolve ao benchmark o raciocínio usado mais a resposta, como o direct devolveria.
    return {**final, "text": head[len(prompt):] + thought + CLOSE + final["text"]}


def budget_complete(backend, prompt, budget, max_tokens):
    """Budget forcing do s1: pensa até `budget` tokens, fecha </think> e responde."""
    head = _open(prompt)
    think = backend.complete(head, max_tokens=budget, stop=["</think>"])
    final = backend.complete(
        head + think["text"] + CLOSE, max_tokens=max(max_tokens - think["output_tokens"], 1))
    return _answer(prompt, head, think["text"], final)


def early_exit_complete(backend, prompt, max_tokens, marker="Wait", threshold=0.95):
    """DEER: em cada transição do raciocínio testa uma resposta e sai se a confiança passar do limiar."""
    head = _open(prompt)
    thought = ""
    used = 0
    while used < max_tokens:
        step = backend.complete(head + thought, max_tokens=max_tokens - used, stop=["</think>", marker])
        thought += step["text"]
        used += step["output_tokens"]
        if step["stop"] != marker:
            break
        trial = backend.complete(head + thought + CLOSE, max_tokens=max(max_tokens - used, 1), logprobs=True)
        if trial["tool_calls"] and trial["confidence"] > threshold:
            return _answer(prompt, head, thought, trial)
        thought += marker
    final = backend.complete(head + thought + CLOSE, max_tokens=max(max_tokens - used, 1))
    return _answer(prompt, head, thought, final)


class DirectStrategy:
    name = "direct"

    def __init__(self, backend, max_tokens):
        self.backend = backend
        self.max_tokens = max_tokens

    def run_turn(self, messages, tools=None):
        return self.backend.generate(messages, tools=tools, max_tokens=self.max_tokens)


class PlanActStrategy:
    name = "plan_act"

    def __init__(self, backend, max_tokens, max_plan_tokens=128):
        self.backend = backend
        self.max_tokens = max_tokens
        self.max_plan_tokens = max_plan_tokens

    def run_turn(self, messages, tools=None):
        plan = self.backend.generate(
            messages + [{
                "role": "user",
                "content": "Escreva um plano curto, no máximo 5 linhas, para responder. Não chame ferramentas ainda.",
            }],
            tools=None,
            max_tokens=self.max_plan_tokens,
        )
        return self.backend.generate(
            messages + [{"role": "assistant", "content": plan["text"]}],
            tools=tools,
            max_tokens=self.max_tokens,
        )
