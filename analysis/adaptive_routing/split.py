"""Split treino/val/teste por família de template — evita vazamento entre variantes."""

from __future__ import annotations

import hashlib
from collections import defaultdict
from dataclasses import dataclass

from oracle import TaskRow


@dataclass
class Split:
    train: list[TaskRow]
    val: list[TaskRow]
    test: list[TaskRow]

    def assert_no_family_leak(self) -> None:
        sets = [
            ("train", {t.family for t in self.train}),
            ("val", {t.family for t in self.val}),
            ("test", {t.family for t in self.test}),
        ]
        for i in range(len(sets)):
            for j in range(i + 1, len(sets)):
                overlap = sets[i][1] & sets[j][1]
                if overlap:
                    raise AssertionError(f"vazamento {sets[i][0]}/{sets[j][0]}: {sorted(overlap)}")


def _family_key(family: str, seed: str) -> int:
    digest = hashlib.sha256(f"{seed}:{family}".encode()).hexdigest()
    return int(digest[:8], 16)


def _category_of_family(family: str, tasks: list[TaskRow]) -> str:
    for t in tasks:
        if t.family == family:
            return t.category
    return "unknown"


def split_by_family(
    tasks: list[TaskRow],
    seed: str = "adaptive-routing-736194",
    train_ratio: float = 0.5,
    val_ratio: float = 0.25,
) -> Split:
    """Atribui famílias inteiras a um split, estratificando por categoria.

    Dentro de cada categoria, famílias são ordenadas pelo hash(seed, family) e
    distribuídas em round-robin train/val/test com quotas ~50/25/25.
    """
    by_family: dict[str, list[TaskRow]] = defaultdict(list)
    for t in tasks:
        by_family[t.family].append(t)

    by_cat_families: dict[str, list[str]] = defaultdict(list)
    for fam, rows in by_family.items():
        by_cat_families[rows[0].category].append(fam)

    train: list[TaskRow] = []
    val: list[TaskRow] = []
    test: list[TaskRow] = []

    for cat in sorted(by_cat_families):
        families = sorted(by_cat_families[cat], key=lambda f: (_family_key(f, seed), f))
        n = len(families)
        if n == 1:
            # Família única na categoria: vai para train (não dá para testar sem vazamento).
            train.extend(by_family[families[0]])
            continue
        if n == 2:
            train.extend(by_family[families[0]])
            test.extend(by_family[families[1]])
            continue
        # n >= 3: pelo menos 1 família em cada split.
        n_test = max(1, int(round(n * (1 - train_ratio - val_ratio))))
        n_val = max(1, int(round(n * val_ratio)))
        n_train = n - n_val - n_test
        if n_train < 1:
            n_train = 1
            # Emprestado do maior entre val/test.
            if n_val >= n_test and n_val > 1:
                n_val -= 1
            elif n_test > 1:
                n_test -= 1
            else:
                n_val = max(1, n - n_train - 1)
                n_test = n - n_train - n_val
        assert n_train >= 1 and n_val >= 1 and n_test >= 1
        assert n_train + n_val + n_test == n
        for fam in families[:n_train]:
            train.extend(by_family[fam])
        for fam in families[n_train : n_train + n_val]:
            val.extend(by_family[fam])
        for fam in families[n_train + n_val :]:
            test.extend(by_family[fam])

    if not test:
        raise AssertionError("split sem teste — categorias com poucas famílias")

    split = Split(train=train, val=val, test=test)
    split.assert_no_family_leak()
    return split


def leave_one_family_out(tasks: list[TaskRow]) -> list[tuple[str, list[TaskRow], list[TaskRow]]]:
    """Folds: cada família uma vez no teste; resto no train (val=vazio)."""
    by_family: dict[str, list[TaskRow]] = defaultdict(list)
    for t in tasks:
        by_family[t.family].append(t)
    folds = []
    for held in sorted(by_family):
        test = by_family[held]
        train = [t for fam, rows in by_family.items() if fam != held for t in rows]
        folds.append((held, train, test))
    return folds


def self_check() -> None:
    rows = []
    for cat, prefix, nfam, per in [
        ("single_tool", "apple_single", 3, 5),
        ("multi_tool", "apple_multi", 3, 5),
        ("sequential", "apple_seq", 4, 5),
        ("ambiguous", "apple_amb", 2, 5),
    ]:
        for b in range(nfam):
            for i in range(per):
                idx = b * per + i + 1
                rows.append(
                    TaskRow(
                        f"{prefix}_{idx:03d}",
                        "m",
                        cat,
                        "p",
                        f"{prefix}_b{b}",
                        {},
                    )
                )
    s = split_by_family(rows, seed="check")
    assert len(s.train) + len(s.val) + len(s.test) == len(rows)
    s.assert_no_family_leak()
    # Cada split deve ter ≥1 categoria sequential se possível
    assert any(t.category == "sequential" for t in s.test)
    assert any(t.category == "sequential" for t in s.train)
