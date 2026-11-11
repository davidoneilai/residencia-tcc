"""Aceitação da cabeça MTP do Qwen3.5-2B nos passos reais do TEST, no Mac (teacher forcing). Sem iPhone.

    <venv mlx-lm>/bin/python -I analysis/runtime/mtp_check.py <modelo MLX> <mtp.safetensors> <decode-anatomy.json> \\
        <serve-requests.jsonl> <serve-log.jsonl> <início UTC> <fim UTC> <saída.json> [máx. passos]

Para cada passo (o mesmo casamento requisição/resposta de `decode_anatomy.py`), monta prompt (template do modelo com
as ferramentas) + a saída que o modelo gerou, roda o alvo uma vez e, em cada posição t da saída, dá à cabeça MTP o
estado oculto de t (depois da norma final, como no `mlx-swift-lm`) e o embedding do token t+1; ela prevê o token t+2. A aceitação de um
rascunho de 1 token (verificação com T = 2, de graça no iPhone) é a fração de acertos, por região (raciocínio,
texto, chamada). Também mede o acerto do próprio alvo (top-1 = token gerado), que tem de dar ~100% em greedy.

Arquitetura (`mlx-swift-lm` `Qwen35MTPPredictor`): concat(norm_e(emb(x[t+1])), norm_h(h[t])) → fc → 1 camada de
atenção completa do Qwen3.5 → norma → lm_head do alvo (embeddings atados). As normas RMS do checkpoint HF vêm como
desvio (w − 1); somamos 1, como o `sanitize` do `mlx-lm` faz no alvo.
"""
import json
import sys
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
from mlx_lm import load
from mlx_lm.models.base import create_attention_mask, create_ssm_mask
from mlx_lm.models.qwen3_5 import DecoderLayer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from decode_anatomy import call_xml, pairs  # noqa: E402


class MTP(nn.Module):
    def __init__(self, args):
        super().__init__()
        self.fc = nn.Linear(args.hidden_size * 2, args.hidden_size, bias=False)
        self.layers = [DecoderLayer(args, layer_idx=args.full_attention_interval - 1)]  # atenção completa
        self.norm = nn.RMSNorm(args.hidden_size, eps=args.rms_norm_eps)
        self.pre_fc_norm_embedding = nn.RMSNorm(args.hidden_size, eps=args.rms_norm_eps)
        self.pre_fc_norm_hidden = nn.RMSNorm(args.hidden_size, eps=args.rms_norm_eps)

    def __call__(self, embeds, hidden):
        x = self.fc(mx.concatenate([self.pre_fc_norm_embedding(embeds), self.pre_fc_norm_hidden(hidden)], axis=-1))
        mask = create_attention_mask(x, None)
        for layer in self.layers:
            x = layer(x, mask=mask, cache=None)
        return self.norm(x)


def load_mtp(path, args):
    mtp = MTP(args)
    weights = {k.removeprefix("mtp."): v for k, v in mx.load(path).items()}
    # Os 7 tensores 1-D do checkpoint são normas (inclusive `pre_fc_norm_embedding/hidden`, que não terminam em
    # `norm.weight`); todas vêm como desvio.
    weights = {k: (v + 1.0 if v.ndim == 1 else v) for k, v in weights.items()}
    mtp.load_weights(list(weights.items()), strict=True)
    mx.eval(mtp.parameters())
    return mtp


def for_template(messages):
    """Formato OpenAI → template HF: argumentos das chamadas como dicionário, não texto JSON."""
    out = []
    for m in messages:
        m = dict(m)
        if m.get("tool_calls"):
            calls = []
            for c in m["tool_calls"]:
                f = dict(c.get("function", c))
                if isinstance(f.get("arguments"), str):
                    f["arguments"] = json.loads(f["arguments"] or "{}")
                calls.append({**c, "function": f})
            m["tool_calls"] = calls
        out.append(m)
    return out


def text_model(model):
    return model.language_model if hasattr(model, "language_model") else model


def hidden_pre_norm(tm, tokens):
    inner = tm.model
    h = inner.embed_tokens(tokens)
    cache = [None] * len(inner.layers)
    fa_mask = create_attention_mask(h, None)
    ssm_mask = create_ssm_mask(h, None)
    for layer in inner.layers:
        h = layer(h, mask=ssm_mask if layer.is_linear else fa_mask, cache=None)
    return h


def main():
    model_dir, mtp_path, anatomy, reqs, log, start, end, out_path = sys.argv[1:9]
    limit = int(sys.argv[9]) if len(sys.argv) > 9 else None
    from datetime import datetime
    model, tok = load(model_dir)
    tm = text_model(model)
    mtp = load_mtp(mtp_path, tm.args)
    steps = pairs(reqs, log, datetime.fromisoformat(start), datetime.fromisoformat(end), "Qwen3.5-2B-4bit", True)
    rows = []
    for index, (req, resp) in enumerate(steps[:limit] if limit else steps):
        n_msgs = len(req["messages"])
        nxt = steps[index + 1][0]["messages"] if index + 1 < len(steps) else []
        assistant = nxt[n_msgs] if len(nxt) > n_msgs and nxt[:n_msgs] == req["messages"] else None
        if resp.get("tool_calls") and not (assistant and assistant.get("role") == "assistant"):
            continue
        raw = resp.get("raw_text") or ""
        think, sep, rest = raw.partition("</think>")
        if not sep:
            think, rest = "", raw
        call = call_xml((assistant or {}).get("tool_calls") or []) if resp.get("tool_calls") else ""
        prompt = tok.apply_chat_template(for_template(req["messages"]), tools=req.get("tools"), add_generation_prompt=True,
                                         enable_thinking=True, tokenize=True)
        parts = [tok.encode(p, add_special_tokens=False) for p in (think + sep, rest, call)]
        out = parts[0] + parts[1] + parts[2]
        region = ["think"] * len(parts[0]) + ["text"] * len(parts[1]) + ["call"] * len(parts[2])
        seq = mx.array([prompt + out])
        h = hidden_pre_norm(tm, seq)
        p = len(prompt)
        # Alvo: posição p-1+i prevê out[i]. Logits só na saída (vocabulário de 248k × 7k posições não cabe).
        logits = tm.model.embed_tokens.as_linear(tm.model.norm(h[:, p - 1:p - 1 + len(out)]))
        target_ok = (mx.argmax(logits[0], axis=-1) == mx.array(out)).tolist()
        # MTP em t = p-1+i usa h[t] e emb(out[i]) e prevê out[i+1].
        emb = tm.model.embed_tokens(seq)
        # O `mlx-swift-lm` passa à MTP o estado oculto do alvo depois da norma final (`model.norm(hidden)`).
        mh = mtp(emb[:, 1:], tm.model.norm(h)[:, :-1])  # posição t: emb de x[t+1] com h[t]
        pred = mx.argmax(tm.model.embed_tokens.as_linear(mh[:, p - 1:p - 1 + len(out) - 1])[0], axis=-1).tolist()
        mtp_ok = [int(pred[i] == out[i + 1]) for i in range(len(out) - 1)]
        mx.clear_cache()
        row = {"time": resp["time"], "prompt_tokens": p, "out_tokens": len(out), "target_top1": sum(target_ok),
               "mtp_ok": sum(mtp_ok)}
        for r in ("think", "text", "call"):
            idx = [i for i in range(len(out) - 1) if region[i + 1] == r]
            row[f"{r}_n"] = len(idx)
            row[f"{r}_ok"] = sum(mtp_ok[i] for i in idx)
        rows.append(row)
        print(index, {k: row[k] for k in ("prompt_tokens", "out_tokens", "target_top1", "mtp_ok")}, flush=True)
    tot = {k: sum(r[k] for r in rows) for k in rows[0] if k != "time"}
    summary = {"steps": len(rows), "target_top1_rate": round(tot["target_top1"] / tot["out_tokens"], 3),
               "mtp_accept_rate": round(tot["mtp_ok"] / (tot["out_tokens"] - len(rows)), 3),
               **{f"mtp_accept_{r}": round(tot[f"{r}_ok"] / max(tot[f"{r}_n"], 1), 3) for r in ("think", "text", "call")}}
    Path(out_path).write_text(json.dumps({"summary": summary, "rows": rows}, indent=1))
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
