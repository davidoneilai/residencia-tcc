from strategies import CLOSE, budget_complete, early_exit_complete

CALL = '<tool_call>{"name": "add", "arguments": {"a": 2, "b": 3}}</tool_call>'


class Scripted:
    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls = []

    def complete(self, prompt, max_tokens=512, stop=None, logprobs=False):
        self.calls.append({"prompt": prompt, "max_tokens": max_tokens, "stop": stop, "logprobs": logprobs})
        text, out, stop_hit, conf = self.replies.pop(0)
        calls = [{"name": "add", "arguments": {}}] if "<tool_call>" in text else []
        return {"text": text, "tool_calls": calls, "prompt_tokens": 0, "output_tokens": out,
                "inference_ms": 1.0, "stop": stop_hit, "confidence": conf}


b = Scripted(("pensa", 64, None, None), (CALL, 30, None, None))
out = budget_complete(b, "P", 64, 512)
assert b.calls[0] == {"prompt": "P<think>\n", "max_tokens": 64, "stop": ["</think>"], "logprobs": False}
assert b.calls[1]["prompt"] == "P<think>\npensa" + CLOSE and b.calls[1]["max_tokens"] == 448
assert out["text"] == "<think>\npensa" + CLOSE + CALL and out["tool_calls"]

b = Scripted(("a", 10, None, None), (CALL, 5, None, None))
budget_complete(b, "P<think>\n", 64, 512)
assert b.calls[0]["prompt"] == "P<think>\n"

b = Scripted(("a ", 20, "Wait", None), (CALL, 30, None, 0.99))
out = early_exit_complete(b, "P", 512)
assert len(b.calls) == 2 and b.calls[1]["prompt"] == "P<think>\na " + CLOSE and b.calls[1]["logprobs"]
assert out["text"] == "<think>\na " + CLOSE + CALL

b = Scripted(("a ", 20, "Wait", None), (CALL, 30, None, 0.5), (", b", 40, "</think>", None), (CALL, 30, None, None))
out = early_exit_complete(b, "P", 512)
assert b.calls[2]["prompt"] == "P<think>\na Wait" and b.calls[2]["max_tokens"] == 492
assert b.calls[3]["prompt"] == "P<think>\na Wait, b" + CLOSE and b.calls[3]["max_tokens"] == 452
assert out["text"] == "<think>\na Wait, b" + CLOSE + CALL

from fmb_energy import energy_j, power_samples, stamp  # noqa: E402

log = """*** Sampled system activity (Thu Oct  8 09:00:01 2026 -0300) (1000.00ms elapsed) ***
Combined Power (CPU + GPU + ANE): 2000 mW
*** Sampled system activity (Thu Oct  8 09:00:02 2026 -0300) (1000.00ms elapsed) ***
Combined Power (CPU + GPU + ANE): 4000 mW
"""
samples = power_samples(log)
assert [w for _, _, w in samples] == [2.0, 4.0]
start, end = stamp("2026-10-08T12:00:00.5Z"), stamp("2026-10-08T12:00:01.5Z")
assert abs(energy_j(samples, start, end) - 3.0) < 1e-9

print("ok")
