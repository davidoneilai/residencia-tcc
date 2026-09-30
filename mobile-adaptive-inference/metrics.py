import json
from pathlib import Path


class Episode:
    def __init__(self):
        self.inference_ms = 0.0
        self.prompt_tokens = 0
        self.output_tokens = 0
        self.model_calls = 0
        self.tool_calls = 0

    def add(self, result):
        self.inference_ms += result["inference_ms"]
        self.prompt_tokens += result["prompt_tokens"]
        self.output_tokens += result["output_tokens"]
        self.model_calls += 1
        self.tool_calls += len(result["tool_calls"])

    def reset(self):
        self.__init__()


def append_jsonl(path, row):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
