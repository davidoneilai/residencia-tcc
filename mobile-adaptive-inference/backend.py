import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from openai import OpenAI

from metrics import Episode

CURRENT = Episode()
REQUEST_LOG = []


class Backend:
    def generate(self, messages, tools=None, max_tokens=512):
        raise NotImplementedError


def _tool_calls(message):
    calls = []
    for call in message.tool_calls or []:
        raw = call.function.arguments or "{}"
        try:
            args = json.loads(raw)
        except json.JSONDecodeError:
            args = {"_raw": raw}
        if not isinstance(args, dict):
            args = {"_value": args}
        calls.append({"name": call.function.name, "arguments": args})
    return calls


class VLLMBackend(Backend):
    def __init__(self, base_url, model, temperature=0):
        self.model = model
        self.temperature = temperature
        self.client = OpenAI(base_url=base_url, api_key="EMPTY")

    def generate(self, messages, tools=None, max_tokens=512):
        kwargs = {
            "model": self.model,
            "messages": messages,
            "temperature": self.temperature,
            "max_tokens": max_tokens,
        }
        if tools:
            kwargs["tools"] = tools
        t0 = time.perf_counter()
        response = self.client.chat.completions.create(**kwargs)
        elapsed_ms = (time.perf_counter() - t0) * 1000
        choice = response.choices[0].message
        usage = response.usage
        return {
            "text": choice.content or "",
            "tool_calls": _tool_calls(choice),
            "prompt_tokens": usage.prompt_tokens if usage else 0,
            "output_tokens": usage.completion_tokens if usage else 0,
            "inference_ms": elapsed_ms,
        }

    def complete(self, prompt, max_tokens=512):
        t0 = time.perf_counter()
        response = self.client.completions.create(
            model=self.model,
            prompt=prompt,
            temperature=self.temperature,
            max_tokens=max_tokens,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000
        usage = response.usage
        text = response.choices[0].text or ""
        return {
            "text": text,
            "tool_calls": _calls_in_text(text),
            "prompt_tokens": usage.prompt_tokens if usage else 0,
            "output_tokens": usage.completion_tokens if usage else 0,
            "inference_ms": elapsed_ms,
        }


def _calls_in_text(text):
    # O BFCL pede /v1/completions. A tool call vem no texto, não em message.tool_calls.
    calls = []
    for raw in re.findall(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", text, re.S):
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict) and item.get("name"):
            args = item.get("arguments") if isinstance(item.get("arguments"), dict) else {}
            calls.append({"name": item["name"], "arguments": args})
    if calls or ("<|tool_call>" not in text and "call:" not in text):
        return calls
    try:
        from vllm.tool_parsers.gemma4_utils import parse_tool_calls
    except Exception:
        return calls
    for item in parse_tool_calls(text):
        args = item.get("arguments") if isinstance(item.get("arguments"), dict) else {}
        calls.append({"name": item["name"], "arguments": args})
    return calls


def _record(result):
    CURRENT.add(result)
    return result


def _chat_response(result):
    tool_calls = [
        {
            "id": f"call_{i}",
            "type": "function",
            "function": {
                "name": call["name"],
                "arguments": json.dumps(call["arguments"], ensure_ascii=False),
            },
        }
        for i, call in enumerate(result["tool_calls"])
    ]
    message = {"role": "assistant", "content": result["text"]}
    if tool_calls:
        message["tool_calls"] = tool_calls
    return {
        "id": "chatcmpl-local",
        "object": "chat.completion",
        "choices": [{"index": 0, "message": message, "finish_reason": "stop"}],
        "usage": {
            "prompt_tokens": result["prompt_tokens"],
            "completion_tokens": result["output_tokens"],
            "total_tokens": result["prompt_tokens"] + result["output_tokens"],
        },
    }


def _completion_response(result):
    return {
        "id": "cmpl-local",
        "object": "text_completion",
        "choices": [{"index": 0, "text": result["text"], "finish_reason": "stop"}],
        "usage": {
            "prompt_tokens": result["prompt_tokens"],
            "completion_tokens": result["output_tokens"],
            "total_tokens": result["prompt_tokens"] + result["output_tokens"],
        },
    }


def serve_proxy(backend, host, port, strategy):
    watch_generate(backend)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            print("proxy", self.address_string(), fmt % args)

        def _send(self, code, payload):
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.split("?", 1)[0] != "/v1/models":
                self._send(404, {"error": "not found"})
                return
            self._send(200, {"object": "list", "data": [{"id": backend.model, "object": "model"}]})

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            body = json.loads(raw.decode() or "{}")
            CURRENT.reset()
            cap = strategy.max_tokens
            asked = body.get("max_tokens") or cap
            max_tokens = min(int(asked), cap)
            if path == "/v1/chat/completions":
                result = strategy.run_turn(body.get("messages") or [], body.get("tools"))
                payload = _chat_response(result)
            elif path == "/v1/completions":
                prompt = body.get("prompt") or ""
                if isinstance(prompt, list):
                    prompt = prompt[0]
                if strategy.name == "plan_act":
                    plan = backend.complete(
                        prompt + "\nEscreva um plano curto, no máximo 5 linhas, para responder. Não chame ferramentas ainda.",
                        max_tokens=strategy.max_plan_tokens,
                    )
                    result = backend.complete(prompt + "\n" + plan["text"], max_tokens=max_tokens)
                elif strategy.name == "nothink":
                    # Qwen3 pula o raciocínio quando o prompt já fecha um <think> vazio.
                    if not prompt.endswith("</think>\n\n"):
                        prompt += "<think>\n\n</think>\n\n"
                    result = backend.complete(prompt, max_tokens=max_tokens)
                else:
                    result = backend.complete(prompt, max_tokens=max_tokens)
                payload = _completion_response(result)
            else:
                self._send(404, {"error": "not found"})
                return
            REQUEST_LOG.append({
                "inference_ms": CURRENT.inference_ms,
                "prompt_tokens": CURRENT.prompt_tokens,
                "output_tokens": CURRENT.output_tokens,
                "model_calls": CURRENT.model_calls,
                "tool_calls": CURRENT.tool_calls,
            })
            self._send(200, payload)

    httpd = ThreadingHTTPServer((host, port), Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd


def watch_generate(backend):
    original = backend.generate
    complete = backend.complete

    def generate(*args, **kwargs):
        return _record(original(*args, **kwargs))

    def complete_watched(*args, **kwargs):
        return _record(complete(*args, **kwargs))

    backend.generate = generate
    backend.complete = complete_watched
    return backend
