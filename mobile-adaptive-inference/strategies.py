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
