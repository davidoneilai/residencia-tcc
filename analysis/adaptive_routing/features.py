"""Features de baixo custo disponíveis antes da execução. Sem rótulos, respostas ou avaliador."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass

# Catálogo de ferramentas (conhecido no app). Nomes e sinônimos do prompt — não usa expected answers.
TOOL_CUES: dict[str, tuple[str, ...]] = {
    "ligar": ("ligue", "ligar", "disque", "chamada", "call ", " phone"),
    "ligarFaceTime": ("facetime", "face time"),
    "enviarEmail": ("e-mail", "email", "mail to", "envie um e-mail", "mande um e-mail"),
    "enviarMensagem": ("mensagem", "mensagens", "sms", "text ", "mande no"),
    "criarEvento": ("evento", "calendário", "calendario", "calendar", "marque "),
    "criarLembrete": ("lembrete", "remind", "lembra"),
    "abrirRota": ("rota", "mapas", "maps", "directions", "navega"),
    "abrirSafari": ("safari", "abra http", "open http", "página", "pagina", "website"),
    "buscarContato": ("contato", "contact", "busque", "procure", "look up", "find "),
}

CONTACT_NAMES = ("ana", "bruno", "carla", "diego", "elena", "felipe", "gina", "hugo")
SEQ_CUES = (
    "depois", "em seguida", "então", "entao", "then ", "after ", "and then",
    "use o número", "use the number", "com o número", "with the number",
    "busque o contato", "look up", "find the contact",
)
MULTI_CUES = (" e ", " and ", " também", " also ", ",", ";")
AMBIG_CUES = (
    "ou ", " or ", "talvez", "maybe", "não sei", "not sure", "ambígu", "ambigu",
    "prefiro", "se puder", "if you can", "não faça nada", "do nothing", "aguarde",
)


FEATURE_NAMES = [
    "char_len",
    "word_count",
    "digit_count",
    "has_phone",
    "has_email",
    "has_url",
    "is_english",
    "contact_name_hits",
    "tool_cue_count",
    "seq_cue_count",
    "multi_cue_count",
    "ambig_cue_count",
    "conjunction_count",
    "avg_word_len",
    "question_marks",
    "negation_count",
]


@dataclass(frozen=True)
class FeatureVector:
    values: tuple[float, ...]
    names: tuple[str, ...] = tuple(FEATURE_NAMES)

    def as_dict(self) -> dict[str, float]:
        return dict(zip(self.names, self.values))


_PHONE = re.compile(r"\+\d{8,}|\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b")
_EMAIL = re.compile(r"[\w.+-]+@[\w.-]+\.\w+")
_URL = re.compile(r"https?://|www\.", re.I)


def extract_features(prompt: str) -> FeatureVector:
    text = prompt or ""
    lower = text.lower()
    words = re.findall(r"\w+", lower, flags=re.UNICODE)
    tool_hits = sum(1 for cues in TOOL_CUES.values() if any(c in lower for c in cues))
    values = (
        float(len(text)),
        float(len(words)),
        float(sum(ch.isdigit() for ch in text)),
        1.0 if _PHONE.search(text) else 0.0,
        1.0 if _EMAIL.search(text) else 0.0,
        1.0 if _URL.search(text) else 0.0,
        1.0 if _looks_english(lower, words) else 0.0,
        float(sum(1 for name in CONTACT_NAMES if re.search(rf"\b{name}\b", lower))),
        float(tool_hits),
        float(sum(1 for c in SEQ_CUES if c in lower)),
        float(sum(1 for c in MULTI_CUES if c in lower)),
        float(sum(1 for c in AMBIG_CUES if c in lower)),
        float(lower.count(" e ") + lower.count(" and ") + lower.count(",")),
        float(sum(len(w) for w in words) / len(words)) if words else 0.0,
        float(text.count("?")),
        float(sum(1 for c in ("não ", "nao ", " do not", " don't", "dont ", "never ") if c in lower)),
    )
    return FeatureVector(values=values)


def feature_matrix(prompts: list[str]) -> list[FeatureVector]:
    return [extract_features(p) for p in prompts]


def measure_overhead_ms(prompt: str, repeats: int = 200) -> float:
    extract_features(prompt)  # warm
    t0 = time.perf_counter()
    for _ in range(repeats):
        extract_features(prompt)
    return (time.perf_counter() - t0) * 1000 / repeats


def template_family(task_id: str, category: str | None = None) -> str:
    """Agrupa variantes do mesmo molde (IDs consecutivos do AppleDataset). Sem labels."""
    m = re.match(r"apple_(single|multi|seq|amb)_(\d+)$", task_id or "")
    if not m:
        return f"other:{task_id}"
    kind, num = m.group(1), int(m.group(2))
    # single/multi: 5 variantes por ferramenta; seq: blocos de 5; amb: blocos de 5
    bucket = (num - 1) // 5
    return f"apple_{kind}_b{bucket}"


def _looks_english(lower: str, words: list[str]) -> bool:
    pt = sum(1 for w in ("para", "uma", "com", "daqui", "lembrete", "envie", "crie", "abra") if w in words)
    en = sum(1 for w in ("the", "to", "and", "please", "create", "send", "call", "remind") if w in words)
    if en > pt:
        return True
    if pt > en:
        return False
    return bool(re.search(r"\b(the|please|create|send|call)\b", lower))
