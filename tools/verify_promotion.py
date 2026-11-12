"""
验证规则自动升级逻辑（Rule.promotable 的等价实现）。

升级条件：enabled && action == mark && hitCount >= minHits && 观察期满 days 天
这个判断如果错了，要么永远不升级（功能形同虚设），
要么把刚建的规则立刻转成拦截（直接误伤）。

用法：python tools/verify_promotion.py
"""

import sys
from dataclasses import dataclass
from datetime import datetime, timedelta

ACTION_ALLOW, ACTION_MARK, ACTION_SILENCE, ACTION_BLOCK = 0, 1, 2, 3


@dataclass
class Rule:
    action: int
    enabled: bool
    hit_count: int
    created_at: datetime

    def observed(self, days: int, now: datetime) -> bool:
        return (now - self.created_at) >= timedelta(days=days)

    def promotable(self, now: datetime, min_hits: int = 3, days: int = 7) -> bool:
        return (self.enabled
                and self.action == ACTION_MARK
                and self.hit_count >= min_hits
                and self.observed(days, now))


NOW = datetime(2026, 11, 12, 12, 0, 0)


def make(hit_count, days_ago, action=ACTION_MARK, enabled=True) -> Rule:
    return Rule(action=action, enabled=enabled, hit_count=hit_count,
                created_at=NOW - timedelta(days=days_ago))


CASES = [
    # (说明, 规则, 期望是否升级)
    ("刚创建 + 命中 5 次（观察期不够）",      make(5, 0),            False),
    ("1 天前 + 命中 5 次",                   make(5, 1),            False),
    ("6 天 23 小时前 + 命中 5 次",           make(5, 6.96),         False),
    ("正好 7 天 + 正好 3 次（边界）",        make(3, 7),            True),
    ("8 天前 + 命中 3 次",                   make(3, 8),            True),
    ("8 天前 + 命中 2 次（次数不够）",       make(2, 8),            False),
    ("8 天前 + 命中 1 次",                   make(1, 8),            False),
    ("8 天前 + 命中 0 次",                   make(0, 8),            False),
    ("8 天前 + 命中 3 次但已停用",           make(3, 8, enabled=False), False),
    ("8 天前 + 命中 3 次但已是拦截",         make(3, 8, action=ACTION_BLOCK), False),
    ("8 天前 + 命中 3 次但是白名单",         make(3, 8, action=ACTION_ALLOW), False),
    ("8 天前 + 命中 3 次但是静音",           make(3, 8, action=ACTION_SILENCE), False),
    ("30 天前 + 命中 100 次",                make(100, 30),         True),
]

ok = fail = 0
print(f"{'用例':<34}{'实际':<8}{'期望':<8}")
print("-" * 54)

for desc, rule, expect in CASES:
    got = rule.promotable(NOW)
    passed = got == expect
    ok += passed
    fail += not passed
    print(f"{'OK  ' if passed else 'FAIL'}{desc:<30}"
          f"{'升级' if got else '不升级':<8}{'升级' if expect else '不升级':<8}")

# 阈值可配置性
print("\n阈值覆盖：")
r = make(5, 10)
for hits, days, expect in [(3, 7, True), (10, 7, False), (5, 30, False), (5, 5, True)]:
    got = r.promotable(NOW, min_hits=hits, days=days)
    passed = got == expect
    ok += passed
    fail += not passed
    print(f"{'OK  ' if passed else 'FAIL'}minHits={hits}, days={days} -> "
          f"{'升级' if got else '不升级'}（期望 {'升级' if expect else '不升级'}）")

print("-" * 54)
print(f"通过 {ok} / {ok + fail}")
sys.exit(1 if fail else 0)
