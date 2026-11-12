"""
CallGuardRules.hpp 的等价 Python 参考实现。

用途：在没有 C++ 编译器的 Windows 环境下，先验证规则引擎的算法逻辑
（归一化、最长前缀匹配、白名单优先级、区间二分、正则），
确保 C++ 版本翻译过去时不会出现逻辑错误。

算法必须与 C++ 版本逐行对应，任何修改都要两边同步。
"""

from __future__ import annotations

import re
from bisect import bisect_right
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Optional


class Action(IntEnum):
    ALLOW = 0
    MARK = 1
    SILENCE = 2
    BLOCK = 3


class RuleType(IntEnum):
    EXACT = 0
    PREFIX = 1
    RANGE = 2
    REGEX = 3


@dataclass
class Rule:
    id: int
    type: RuleType
    action: Action
    value: str
    label: str = ""
    enabled: bool = True


@dataclass
class MatchResult:
    matched: bool = False
    action: Action = Action.ALLOW
    rule_id: int = -1
    label: str = ""
    reason: str = ""


def normalize_number(raw: str) -> str:
    """对应 C++ normalizeNumber()"""
    d = "".join(ch for ch in raw if ch.isdigit())
    if not d:
        return ""
    if len(d) > 2 and d[0] == "0" and d[1] == "0":
        d = d[2:]
    if len(d) > 2 and d.startswith("86"):
        return d
    if len(d) == 11 and d[0] == "1":
        return "86" + d
    if d[0] == "0":
        return "86" + d[1:]
    return "86" + d


def to_u64(s: str) -> int:
    if not s.isdigit():
        return 0
    return int(s)


class PrefixTrie:
    """对应 C++ PrefixTrie，节点用 dict 列表存储"""

    def __init__(self) -> None:
        # 每个节点: {"next": {char: idx}, "rule": int}
        self.nodes: list[dict] = [{"next": {}, "rule": -1}]

    def insert(self, prefix: str, rule_idx: int) -> None:
        if not prefix:
            return
        cur = 0
        for ch in prefix:
            nxt = self.nodes[cur]["next"]
            if ch not in nxt:
                self.nodes.append({"next": {}, "rule": -1})
                nxt[ch] = len(self.nodes) - 1
            cur = nxt[ch]
        self.nodes[cur]["rule"] = rule_idx

    def longest_match(self, number: str) -> int:
        cur = 0
        best = -1
        for ch in number:
            nxt = self.nodes[cur]["next"]
            if ch not in nxt:
                break
            cur = nxt[ch]
            if self.nodes[cur]["rule"] >= 0:
                best = self.nodes[cur]["rule"]
        return best

    def node_count(self) -> int:
        return len(self.nodes)


@dataclass
class _RangeEntry:
    start: int
    end: int
    rule_idx: int


class RuleEngine:
    def __init__(self) -> None:
        self.clear()

    def clear(self) -> None:
        self.rules: list[Rule] = []
        self.pending: list[int] = []
        self.whitelist: set[int] = set()
        self.whitelist_prefix = PrefixTrie()
        self.exact: dict[int, int] = {}
        self.prefix = PrefixTrie()
        self.ranges: list[_RangeEntry] = []
        self.regex: list[tuple[re.Pattern, int]] = []

    def add_rule(self, r: Rule) -> None:
        if not r.enabled:
            return
        idx = len(self.rules)
        self.rules.append(r)
        self.pending.append(idx)

    def add_whitelist(self, number: str) -> None:
        n = normalize_number(number)
        if n:
            self.whitelist.add(to_u64(n))

    def add_whitelist_prefix(self, prefix: str) -> None:
        n = normalize_number(prefix)
        if n:
            self.whitelist_prefix.insert(n, 0)

    def finalize(self) -> None:
        self.exact.clear()
        self.ranges.clear()
        self.regex.clear()
        self.prefix = PrefixTrie()

        for idx in self.pending:
            r = self.rules[idx]
            if r.type == RuleType.EXACT:
                n = normalize_number(r.value)
                if n:
                    self.exact[to_u64(n)] = idx
            elif r.type == RuleType.PREFIX:
                n = normalize_number(r.value)
                if n:
                    self.prefix.insert(n, idx)
            elif r.type == RuleType.RANGE:
                if "-" not in r.value:
                    continue
                a, b = r.value.split("-", 1)
                na, nb = normalize_number(a), normalize_number(b)
                if not na or not nb:
                    continue
                lo, hi = to_u64(na), to_u64(nb)
                if lo > hi:
                    lo, hi = hi, lo
                self.ranges.append(_RangeEntry(lo, hi, idx))
            elif r.type == RuleType.REGEX:
                try:
                    self.regex.append((re.compile(r.value), idx))
                except re.error:
                    pass

        self.ranges.sort(key=lambda x: x.start)
        self.pending.clear()

    def evaluate(self, raw_number: str) -> MatchResult:
        res = MatchResult()
        num = normalize_number(raw_number)
        if not num:
            return res
        v = to_u64(num)

        # 1. 白名单（精确 + 前缀）
        if v in self.whitelist or self.whitelist_prefix.longest_match(num) >= 0:
            return MatchResult(True, Action.ALLOW, -1, "", "whitelist")

        # 2. 精确
        if v in self.exact:
            return self._make(self.exact[v], "exact")

        # 3. 前缀（最长匹配）
        pid = self.prefix.longest_match(num)
        if pid >= 0:
            return self._make(pid, "prefix")

        # 4. 区间（二分）
        if self.ranges:
            starts = [r.start for r in self.ranges]
            pos = bisect_right(starts, v) - 1
            if pos >= 0:
                rr = self.ranges[pos]
                if rr.start <= v <= rr.end:
                    return self._make(rr.rule_idx, "range")

        # 5. 正则
        for pat, idx in self.regex:
            if pat.fullmatch(num):
                return self._make(idx, "regex")

        return res

    def _make(self, idx: int, reason: str) -> MatchResult:
        r = self.rules[idx]
        return MatchResult(True, r.action, r.id, r.label, reason)

    def rule_count(self) -> int:
        return len(self.rules)

    def trie_nodes(self) -> int:
        return self.prefix.node_count()
