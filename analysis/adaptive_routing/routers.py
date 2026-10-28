"""Roteadores leves: heurística, regressão logística e árvore rasa. Sem sklearn."""

from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from features import FEATURE_NAMES, FeatureVector, extract_features
from oracle import TaskRow


@dataclass
class RouteDecision:
    strategy: str
    decision_ms: float
    reason: str
    scores: dict[str, float] | None = None


class Router:
    name: str = "base"
    candidates: list[str]

    def choose(self, prompt: str, features: FeatureVector | None = None) -> RouteDecision:
        raise NotImplementedError

    def dump(self) -> dict[str, Any]:
        return {"name": self.name, "candidates": self.candidates}


class FixedRouter(Router):
    def __init__(self, strategy: str, candidates: list[str] | None = None):
        self.name = f"fixed:{strategy}"
        self.strategy = strategy
        self.candidates = candidates or [strategy]

    def choose(self, prompt: str, features: FeatureVector | None = None) -> RouteDecision:
        t0 = time.perf_counter()
        _ = features or extract_features(prompt)
        return RouteDecision(self.strategy, (time.perf_counter() - t0) * 1000, "fixed")


class HeuristicRouter(Router):
    """Regras baratas. Perfil `qwen`: sequential→plan_act. Demais modelos: preferem direct."""

    def __init__(
        self,
        candidates: list[str] | None = None,
        default: str = "direct",
        profile: str = "qwen",
    ):
        self.name = "heuristic"
        self.candidates = candidates or ["direct", "plan_act"]
        self.default = default if default in self.candidates else self.candidates[0]
        self.profile = profile

    def choose(self, prompt: str, features: FeatureVector | None = None) -> RouteDecision:
        t0 = time.perf_counter()
        f = features or extract_features(prompt)
        d = f.as_dict()
        plan = "plan_act" if "plan_act" in self.candidates else self.candidates[-1]
        direct = "direct" if "direct" in self.candidates else self.candidates[0]

        if self.profile != "qwen":
            # Apple/Gemma: plan_act quase nunca melhora sucesso e aumenta latência.
            choice, reason = direct, f"profile_{self.profile}_prefer_direct"
        elif d["seq_cue_count"] >= 1 or d["contact_name_hits"] >= 1:
            choice, reason = plan, "sequential_or_contact"
        elif d["ambig_cue_count"] >= 1:
            choice, reason = direct, "ambiguous_prefer_direct"
        elif d["tool_cue_count"] >= 2 and d["word_count"] >= 20:
            choice, reason = plan, "long_multi_tool"
        elif d["char_len"] <= 80 and d["tool_cue_count"] <= 1:
            choice, reason = direct, "short_single"
        else:
            choice, reason = self.default, "default"
        if choice not in self.candidates:
            choice = self.default
        return RouteDecision(choice, (time.perf_counter() - t0) * 1000, reason)


class LogisticRouter(Router):
    """Regressão logística binária (classe positiva = candidates[1])."""

    def __init__(
        self,
        weights: list[float],
        bias: float,
        candidates: list[str],
        mean: list[float] | None = None,
        std: list[float] | None = None,
        threshold: float = 0.5,
    ):
        assert len(candidates) == 2
        self.name = "logistic"
        self.weights = weights
        self.bias = bias
        self.candidates = candidates
        self.mean = mean or [0.0] * len(weights)
        self.std = std or [1.0] * len(weights)
        self.threshold = threshold

    def choose(self, prompt: str, features: FeatureVector | None = None) -> RouteDecision:
        t0 = time.perf_counter()
        f = features or extract_features(prompt)
        x = [(v - m) / (s if s > 1e-9 else 1.0) for v, m, s in zip(f.values, self.mean, self.std)]
        z = self.bias + sum(w * xi for w, xi in zip(self.weights, x))
        prob = 1.0 / (1.0 + math.exp(-max(min(z, 30), -30)))
        choice = self.candidates[1] if prob >= self.threshold else self.candidates[0]
        return RouteDecision(
            choice,
            (time.perf_counter() - t0) * 1000,
            f"p={prob:.3f}",
            {self.candidates[0]: 1 - prob, self.candidates[1]: prob},
        )

    def dump(self) -> dict[str, Any]:
        return {
            **super().dump(),
            "weights": self.weights,
            "bias": self.bias,
            "mean": self.mean,
            "std": self.std,
            "threshold": self.threshold,
            "feature_names": FEATURE_NAMES,
        }

    @classmethod
    def load(cls, path: Path) -> "LogisticRouter":
        data = json.loads(path.read_text())
        return cls(
            weights=data["weights"],
            bias=data["bias"],
            candidates=data["candidates"],
            mean=data.get("mean"),
            std=data.get("std"),
            threshold=data.get("threshold", 0.5),
        )


class DecisionTreeRouter(Router):
    """Árvore rasa (profundidade ≤ 3) treinada por ganho de Gini."""

    def __init__(self, tree: dict[str, Any], candidates: list[str]):
        self.name = "decision_tree"
        self.tree = tree
        self.candidates = candidates

    def choose(self, prompt: str, features: FeatureVector | None = None) -> RouteDecision:
        t0 = time.perf_counter()
        f = features or extract_features(prompt)
        node = self.tree
        path = []
        while "leaf" not in node:
            idx = node["feature"]
            thr = node["threshold"]
            val = f.values[idx]
            go_left = val <= thr
            path.append(f"{FEATURE_NAMES[idx]}<={thr:.3g}:{go_left}")
            node = node["left"] if go_left else node["right"]
        choice = self.candidates[node["leaf"]]
        return RouteDecision(choice, (time.perf_counter() - t0) * 1000, " / ".join(path) or "leaf")

    def dump(self) -> dict[str, Any]:
        return {**super().dump(), "tree": self.tree, "feature_names": FEATURE_NAMES}


def _labels_from_oracle(tasks: list[TaskRow], candidates: list[str]) -> list[int]:
    return [0 if t.oracle_choice(candidates) == candidates[0] else 1 for t in tasks]


def cost_labels(tasks: list[TaskRow], candidates: list[str]) -> tuple[list[int], list[float]]:
    """Rótulo = política a escolher; peso = custo de errar.

    only_* (uma política acerta): peso alto — perder sucesso é o erro caro.
    both: rótulo = mais rápida; peso 1 — só latência.
    neither: rótulo = direct (candidates[0]); peso baixo — fallback conservador.
    """
    a, b = candidates
    y: list[int] = []
    w: list[float] = []
    for t in tasks:
        sa, sb = t.policies[a].success, t.policies[b].success
        if sa and not sb:
            y.append(0)
            w.append(8.0)
        elif sb and not sa:
            y.append(1)
            w.append(8.0)
        elif sa and sb:
            faster = 0 if t.policies[a].latency_ms <= t.policies[b].latency_ms else 1
            y.append(faster)
            w.append(1.0)
        else:
            y.append(0)
            w.append(0.25)
    return y, w


def _matrix(tasks: list[TaskRow]) -> list[list[float]]:
    return [list(extract_features(t.prompt).values) for t in tasks]


def _standardize(x: list[list[float]]) -> tuple[list[list[float]], list[float], list[float]]:
    cols = list(zip(*x))
    mean = [sum(c) / len(c) for c in cols]
    std = []
    for c, m in zip(cols, mean):
        var = sum((v - m) ** 2 for v in c) / max(len(c), 1)
        std.append(math.sqrt(var) if var > 0 else 1.0)
    scaled = [[(v - m) / s for v, m, s in zip(row, mean, std)] for row in x]
    return scaled, mean, std


def train_logistic(
    train: list[TaskRow],
    val: list[TaskRow],
    candidates: list[str],
    lr: float = 0.2,
    epochs: int = 400,
    cost_sensitive: bool = False,
    success_slack: float = 0.05,
) -> LogisticRouter:
    assert len(candidates) == 2
    x_raw = _matrix(train)
    if cost_sensitive:
        y, sample_w = cost_labels(train, candidates)
    else:
        y = _labels_from_oracle(train, candidates)
        sample_w = [1.0] * len(y)
    x, mean, std = _standardize(x_raw)
    n_feat = len(x[0])
    w = [0.0] * n_feat
    b = 0.0
    mass = sum(sample_w) or 1.0
    for _ in range(epochs):
        dw = [0.0] * n_feat
        db = 0.0
        for row, yi, wi in zip(x, y, sample_w):
            z = b + sum(wj * xj for wj, xj in zip(w, row))
            p = 1.0 / (1.0 + math.exp(-max(min(z, 30), -30)))
            err = (p - yi) * wi
            for j in range(n_feat):
                dw[j] += err * row[j]
            db += err
        for j in range(n_feat):
            w[j] -= lr * (dw[j] / mass + 1e-3 * w[j])
        b -= lr * db / mass

    # Limiar em val: sucesso primeiro (piso vs melhor fixed), depois latência.
    # cost_sensitive: limiar ≥0.5 para só ir a plan_act com evidência.
    best_thr, best_key = 0.5, None
    router = LogisticRouter(w, b, candidates, mean, std, 0.5)
    start = 10 if cost_sensitive else 1
    for thr_i in range(start, 20):
        thr = thr_i / 20
        router.threshold = thr
        key = _val_objective(val, router, candidates, success_slack=success_slack)
        if best_key is None or key < best_key:
            best_key = key
            best_thr = thr
    router.threshold = best_thr
    return router


def _val_objective(
    tasks: list[TaskRow],
    router: Router,
    candidates: list[str],
    success_slack: float = 0.05,
) -> tuple:
    """Menor tupla é melhor: latência sob piso de sucesso vs melhor fixed no mesmo set."""
    succ = 0
    lat = 0.0
    for t in tasks:
        d = router.choose(t.prompt)
        s = d.strategy if d.strategy in t.policies else candidates[0]
        succ += int(t.policies[s].success)
        lat += t.policies[s].latency_ms
    n = max(len(tasks), 1)
    sr = succ / n
    from oracle import best_fixed, fixed_policy_stats

    bf = best_fixed(tasks, candidates)
    floor = fixed_policy_stats(tasks, bf)["success_rate"] - success_slack
    penalty = 0 if sr >= floor else 1
    return (penalty, -sr, lat)


def _gini(labels: list[int]) -> float:
    if not labels:
        return 0.0
    n = len(labels)
    p1 = sum(labels) / n
    return 2 * p1 * (1 - p1)


def _best_split(x: list[list[float]], y: list[int]) -> tuple[int, float, float] | None:
    best = None
    n = len(y)
    base = _gini(y)
    for feat in range(len(x[0])):
        values = sorted(set(row[feat] for row in x))
        for i in range(len(values) - 1):
            thr = (values[i] + values[i + 1]) / 2
            left = [yi for row, yi in zip(x, y) if row[feat] <= thr]
            right = [yi for row, yi in zip(x, y) if row[feat] > thr]
            if not left or not right:
                continue
            gain = base - (len(left) / n) * _gini(left) - (len(right) / n) * _gini(right)
            if best is None or gain > best[0]:
                best = (gain, feat, thr)
    if best is None or best[0] <= 1e-12:
        return None
    return best[1], best[2], best[0]


def _weighted_leaf(y: list[int], weights: list[float] | None) -> int:
    if not y:
        return 0
    if not weights:
        return 1 if sum(y) * 2 >= len(y) else 0
    s1 = sum(w for yi, w in zip(y, weights) if yi == 1)
    s0 = sum(w for yi, w in zip(y, weights) if yi == 0)
    return 1 if s1 > s0 else 0  # empate → direct (classe 0)


def _build_tree(
    x: list[list[float]],
    y: list[int],
    depth: int,
    max_depth: int,
    weights: list[float] | None = None,
) -> dict[str, Any]:
    if depth >= max_depth or len(set(y)) <= 1 or len(y) < 4:
        return {"leaf": _weighted_leaf(y, weights)}
    split = _best_split(x, y)
    if split is None:
        return {"leaf": _weighted_leaf(y, weights)}
    feat, thr, _ = split
    left_idx = [i for i, row in enumerate(x) if row[feat] <= thr]
    right_idx = [i for i, row in enumerate(x) if row[feat] > thr]
    w_left = [weights[i] for i in left_idx] if weights else None
    w_right = [weights[i] for i in right_idx] if weights else None
    return {
        "feature": feat,
        "threshold": thr,
        "left": _build_tree([x[i] for i in left_idx], [y[i] for i in left_idx], depth + 1, max_depth, w_left),
        "right": _build_tree([x[i] for i in right_idx], [y[i] for i in right_idx], depth + 1, max_depth, w_right),
    }


def train_tree(
    train: list[TaskRow],
    candidates: list[str],
    max_depth: int = 3,
    cost_sensitive: bool = False,
) -> DecisionTreeRouter:
    x = _matrix(train)
    if cost_sensitive:
        y, weights = cost_labels(train, candidates)
    else:
        y = _labels_from_oracle(train, candidates)
        weights = None
    tree = _build_tree(x, y, 0, max_depth, weights)
    return DecisionTreeRouter(tree, candidates)


def pick_learned(
    train: list[TaskRow],
    val: list[TaskRow],
    candidates: list[str],
    cost_sensitive: bool = False,
    success_slack: float = 0.05,
) -> Router:
    logistic = train_logistic(
        train, val, candidates, cost_sensitive=cost_sensitive, success_slack=success_slack
    )
    tree = train_tree(train, candidates, cost_sensitive=cost_sensitive)
    scored = [
        (_val_objective(val, logistic, candidates, success_slack=success_slack), logistic),
        (_val_objective(val, tree, candidates, success_slack=success_slack), tree),
    ]
    scored.sort(key=lambda x: x[0])
    return scored[0][1]
