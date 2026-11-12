"""
规则模拟器 —— 加载 seed_rules.json，对输入的号码跑一遍规则引擎，看判定结果。

用法：
    python tools/simulate.py 17012345678 95588 13800138000
    python tools/simulate.py            # 跑内置样例
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

from ref_engine import Action, Rule, RuleEngine, RuleType  # noqa: E402

ACTION_MAP = {
    "mark": Action.MARK,
    "block": Action.BLOCK,
    "silence": Action.SILENCE,
    "allow": Action.ALLOW,
}
TYPE_MAP = {
    "exact": RuleType.EXACT,
    "prefix": RuleType.PREFIX,
    "range": RuleType.RANGE,
    "regex": RuleType.REGEX,
}
ACTION_CN = {
    Action.ALLOW: "放行",
    Action.MARK: "仅标记",
    Action.SILENCE: "静音",
    Action.BLOCK: "拦截",
}


def load_engine() -> RuleEngine:
    data = json.loads((ROOT / "data" / "seed_rules.json").read_text(encoding="utf-8"))
    e = RuleEngine()
    for r in data["rules"]:
        e.add_rule(Rule(r["id"], TYPE_MAP[r["type"]], ACTION_MAP[r["action"]],
                        r["value"], r["label"]))
    for w in data.get("whitelist_templates", []):
        if w["type"] == "prefix":
            e.add_whitelist_prefix(w["value"])
        else:
            e.add_whitelist(w["value"])
    e.finalize()
    return e


def main() -> None:
    samples = sys.argv[1:] or [
        "17012345678", "17112345678", "16212345678", "16512345678",
        "95123456", "95588", "4001234567", "1010123456",
        "13800138000", "10086", "01012345678",
    ]

    e = load_engine()
    print(f"规则 {e.rule_count()} 条，Trie 节点 {e.trie_nodes()} 个\n")
    print(f"{'号码':<16}{'判定':<8}{'来源':<12}{'标签'}")
    print("-" * 56)
    for s in samples:
        r = e.evaluate(s)
        if not r.matched:
            print(f"{s:<16}{'放行':<8}{'未命中':<12}")
            continue
        print(f"{s:<16}{ACTION_CN.get(r.action, '?'):<8}{r.reason:<12}{r.label}")


if __name__ == "__main__":
    main()
