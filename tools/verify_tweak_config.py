"""
验证 App 导出格式 ↔ Tweak 解析格式的一致性。

Tweak 的 CGLoadConfig() 用 NSDictionary 读 tweak_rules.plist，
字段名和类型必须和这里完全一致，否则规则静默失效（不报错）。

这个脚本做三件事：
  1. 按 RuleStore.exportTweakConfig() 的逻辑生成 plist
  2. 按 Tweak.xm 的 CGLoadConfig() 逻辑解析回来
  3. 用同一套规则跑号码，确认结果符合预期

用法：python tools/verify_tweak_config.py
"""

import json
import plistlib
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

from ref_engine import Action, Rule, RuleEngine, RuleType  # noqa: E402

ACTION_MAP = {"mark": 1, "block": 3, "silence": 2, "allow": 0}
TYPE_MAP = {"exact": 0, "prefix": 1, "range": 2, "regex": 3}
ACTION_CN = {0: "放行", 1: "仅标记", 2: "静音", 3: "拦截"}


def build_plist_like_app() -> dict:
    """对应 RuleStore.exportTweakConfig()"""
    data = json.loads((ROOT / "data" / "seed_rules.json").read_text(encoding="utf-8"))

    rules = []
    for r in data["rules"]:
        rules.append({
            "id": r["id"],
            "type": TYPE_MAP[r["type"]],
            "action": ACTION_MAP[r["action"]],
            "value": r["value"],
            "label": r["label"],
            "enabled": True,
        })

    whitelist, whitelist_prefix = [], []
    for w in data.get("whitelist_templates", []):
        (whitelist_prefix if w["type"] == "prefix" else whitelist).append(w["value"])

    return {
        "enabled": True,
        "version": 1,
        "rules": rules,
        "whitelist": whitelist,
        "whitelistPrefix": whitelist_prefix,
    }


def load_like_tweak(path: Path) -> RuleEngine:
    """对应 Tweak.xm 的 CGLoadConfig()"""
    with open(path, "rb") as f:
        d = plistlib.load(f)

    engine = RuleEngine()

    for item in d.get("rules", []):
        engine.add_rule(Rule(
            id=item["id"],
            type=RuleType(item["type"]),
            action=Action(item["action"]),
            value=item["value"],
            label=item.get("label", ""),
            enabled=bool(item.get("enabled", True)),
        ))

    for n in d.get("whitelist", []):
        engine.add_whitelist(n)
    for n in d.get("whitelistPrefix", []):
        engine.add_whitelist_prefix(n)

    engine.finalize()
    return engine


def main() -> int:
    doc = build_plist_like_app()

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "tweak_rules.plist"
        with open(path, "wb") as f:
            plistlib.dump(doc, f, fmt=plistlib.FMT_XML)

        size = path.stat().st_size
        print(f"生成 {path.name}：{size} 字节，{len(doc['rules'])} 条规则\n")

        engine = load_like_tweak(path)

    print(f"Tweak 侧解析：{engine.rule_count()} 条规则，"
          f"Trie {engine.trie_nodes()} 节点\n")

    samples = [
        ("17012345678", "仅标记", "虚拟运营商号段"),
        ("17112345678", "仅标记", "虚拟运营商号段"),
        ("95123456",    "仅标记", "95 企业外呼"),
        ("95588",       "放行",   "银行客服白名单前缀"),
        ("10086",       "放行",   "运营商白名单"),
        ("13800138000", "放行",   "普通手机号未命中"),
    ]

    ok = 0
    fail = 0
    print(f"{'号码':<16}{'实际':<8}{'期望':<8}{'说明'}")
    print("-" * 56)

    for number, expect_cn, note in samples:
        r = engine.evaluate(number)
        actual_cn = ACTION_CN.get(int(r.action), "?") if r.matched else "放行"
        passed = actual_cn == expect_cn
        ok += passed
        fail += not passed
        mark = "OK  " if passed else "FAIL"
        print(f"{mark}{number:<12}{actual_cn:<8}{expect_cn:<8}{note}")

    print("-" * 56)
    print(f"通过 {ok} / {ok + fail}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
