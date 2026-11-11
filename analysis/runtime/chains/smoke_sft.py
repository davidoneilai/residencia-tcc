import json, sys, urllib.request
URL = "http://iPhone-de-David.local:8080/v1/chat/completions"
TOOLS = [{"type": "function", "function": {"name": "set_alarm", "description": "Set an alarm",
          "parameters": {"type": "object", "properties": {"time": {"type": "string", "description": "HH:MM 24h"},
                         "label": {"type": "string"}}, "required": ["time"]}}},
         {"type": "function", "function": {"name": "get_weather", "description": "Get current weather for a city",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
MSG = [{"role": "user", "content": "Wake me up at 6:45 tomorrow, label it gym, and tell me the weather in Lisbon."}]
for model in sys.argv[1:]:
    body = json.dumps({"model": model, "messages": MSG, "tools": TOOLS, "max_tokens": 1024}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    d = json.loads(urllib.request.urlopen(req, timeout=900).read())
    if "error" in d: print(model, "ERRO", d["error"]); continue
    m = d["choices"][0]["message"]; dev = d.get("device", {})
    calls = [(c["function"]["name"], json.loads(c["function"]["arguments"])) for c in m.get("tool_calls") or []]
    print(model, "| adapter:", dev.get("adapter"), "| %.1f s" % (dev.get("latency_ms", 0) / 1000), "| calls:", calls)
    print("   raw:", (dev.get("raw_text") or "")[-260:].replace("\n", " "))
