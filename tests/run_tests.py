"""
规则引擎算法验证。

覆盖：归一化、精确匹配、最长前缀、白名单优先级、区间二分、正则、禁用规则、边界值。
运行：python tests/run_tests.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from ref_engine import (  # noqa: E402
    Action, Rule, RuleEngine, RuleType, normalize_number,
)

PASS = 0
FAIL = 0


def check(name: str, got, expect) -> None:
    global PASS, FAIL
    if got == expect:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}\n       got={got!r}\n       exp={expect!r}")


# ─────────────────────── 1. 号码归一化 ───────────────────────

print("[1] 号码归一化")

cases = [
    ("13800138000",        "8613800138000"),
    ("+86 138-0013-8000",  "8613800138000"),
    ("8613800138000",      "8613800138000"),
    ("008613800138000",    "8613800138000"),
    ("010-12345678",       "861012345678"),
    ("  138 0013 8000  ",  "8613800138000"),
    ("",                   ""),
    ("abc",                ""),
]
for raw, expect in cases:
    check(f"normalize({raw!r})", normalize_number(raw), expect)


# ─────────────────────── 2. 精确匹配 ───────────────────────

print("\n[2] 精确匹配")

e = RuleEngine()
e.add_rule(Rule(1, RuleType.EXACT, Action.BLOCK, "13800138000", "骚扰电话"))
e.add_rule(Rule(2, RuleType.EXACT, Action.BLOCK, "13900139000", "催收"))
e.finalize()

r = e.evaluate("13800138000")
check("命中精确号码", (r.matched, r.action, r.reason), (True, Action.BLOCK, "exact"))
check("带 +86 也命中", e.evaluate("+8613800138000").matched, True)
check("未收录号码不命中", e.evaluate("13700137000").matched, False)


# ─────────────────────── 3. 最长前缀匹配 ───────────────────────

print("\n[3] 前缀（最长匹配）")

e = RuleEngine()
e.add_rule(Rule(10, RuleType.PREFIX, Action.MARK,    "86170",  "虚拟运营商"))
e.add_rule(Rule(11, RuleType.PREFIX, Action.BLOCK,   "861700", "虚拟运营商-1700"))
e.add_rule(Rule(12, RuleType.PREFIX, Action.MARK,    "8695",   "95 外呼"))
e.finalize()

r = e.evaluate("17001234567")
check("命中更长的 1700", (r.rule_id, r.action), (11, Action.BLOCK))

r = e.evaluate("17091234567")
check("1709 命中较短的 170", (r.rule_id, r.action), (10, Action.MARK))

r = e.evaluate("95123456")
check("95 段命中", r.rule_id, 12)

check("普通手机号不命中", e.evaluate("13800138000").matched, False)


# ─────────────────────── 4. 白名单优先级 ───────────────────────

print("\n[4] 白名单优先级")

e = RuleEngine()
e.add_rule(Rule(20, RuleType.PREFIX, Action.BLOCK, "86170", "虚拟运营商"))
e.add_rule(Rule(21, RuleType.EXACT, Action.BLOCK, "8617001234567", "已举报"))
e.add_whitelist("17001234567")
e.finalize()

r = e.evaluate("17001234567")
check("白名单压过精确规则", (r.action, r.reason), (Action.ALLOW, "whitelist"))

r = e.evaluate("17009999999")
check("白名单外的仍被拦", r.action, Action.BLOCK)

# 白名单前缀（银行 / 运营商整段放行）
e2 = RuleEngine()
e2.add_rule(Rule(22, RuleType.PREFIX, Action.MARK, "8695", "95 企业外呼"))
e2.add_whitelist_prefix("955")
e2.finalize()

check("95588 命中白名单前缀", e2.evaluate("95588").action, Action.ALLOW)
check("95588 不落入 95 黑名单", e2.evaluate("95588").reason, "whitelist")
check("95188 仍被标记", e2.evaluate("95188").action, Action.MARK)


# ─────────────────────── 5. 区间 ───────────────────────

print("\n[5] 号码区间")

e = RuleEngine()
e.add_rule(Rule(30, RuleType.RANGE, Action.BLOCK, "8613100000000-8613100000999", "号段区间"))
e.finalize()

check("区间内左边界", e.evaluate("13100000000").matched, True)
check("区间内右边界", e.evaluate("13100000999").matched, True)
check("区间内中间值", e.evaluate("13100000500").matched, True)
check("区间外（右+1）", e.evaluate("13100001000").matched, False)
check("区间外（左-1）", e.evaluate("13199999999").matched, False)


# ─────────────────────── 6. 正则 ───────────────────────

print("\n[6] 正则")

e = RuleEngine()
e.add_rule(Rule(40, RuleType.REGEX, Action.MARK, r"86(170|171)\d{8}", "虚拟号段正则"))
e.finalize()

check("正则命中 170", e.evaluate("17012345678").matched, True)
check("正则命中 171", e.evaluate("17112345678").matched, True)
check("正则不命中 172", e.evaluate("17212345678").matched, False)

# 非法正则不应崩溃
e2 = RuleEngine()
e2.add_rule(Rule(41, RuleType.REGEX, Action.BLOCK, r"86(170", "坏正则"))
e2.finalize()
check("非法正则被跳过", e2.evaluate("17012345678").matched, False)


# ─────────────────────── 7. 禁用规则 ───────────────────────

print("\n[7] 禁用规则")

e = RuleEngine()
e.add_rule(Rule(50, RuleType.EXACT, Action.BLOCK, "13800138000", "已停用", enabled=False))
e.finalize()

check("禁用规则不生效", e.evaluate("13800138000").matched, False)
check("禁用规则不计数", e.rule_count(), 0)


# ─────────────────────── 8. 优先级顺序 ───────────────────────

print("\n[8] 匹配顺序：精确 > 前缀 > 区间 > 正则")

e = RuleEngine()
e.add_rule(Rule(60, RuleType.REGEX, Action.MARK,    r"86\d{11}", "全量正则"))
e.add_rule(Rule(61, RuleType.PREFIX, Action.SILENCE, "8613",    "13 段"))
e.add_rule(Rule(62, RuleType.EXACT, Action.BLOCK,   "13800138000", "精确黑名单"))
e.finalize()

r = e.evaluate("13800138000")
check("精确优先于前缀和正则", (r.rule_id, r.reason), (62, "exact"))

r = e.evaluate("13100131000")
check("前缀优先于正则", (r.rule_id, r.reason), (61, "prefix"))

r = e.evaluate("19900199000")
check("都没命中时落到正则", (r.rule_id, r.reason), (60, "regex"))


# ─────────────────────── 9. 边界 ───────────────────────

print("\n[9] 边界")

e = RuleEngine()
e.add_rule(Rule(70, RuleType.EXACT, Action.BLOCK, "1", "单字符"))
e.finalize()
check("极短号码不崩", e.evaluate("1").matched in (True, False), True)
check("空输入不崩", e.evaluate("").matched, False)
check("纯符号不崩", e.evaluate("+++---").matched, False)

# 超长输入
check("超长输入不崩", e.evaluate("1" * 200).matched in (True, False), True)


# ─────────────────────── 汇总 ───────────────────────

print("\n" + "=" * 44)
print(f"  通过 {PASS} / {PASS + FAIL}")
if FAIL:
    print(f"  失败 {FAIL}")
print("=" * 44)

sys.exit(1 if FAIL else 0)
