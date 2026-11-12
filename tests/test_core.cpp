// C++ 规则引擎单元测试
// 与 tests/run_tests.py 的用例一一对应，确保两个实现行为一致。
//
// 本地无 C++ 编译器，此文件由 GitHub Actions 的 macOS runner 编译执行。

#include "../core/CallGuardRules.hpp"

#include <cstdio>
#include <string>
#include <vector>

using namespace cg;

static int g_pass = 0;
static int g_fail = 0;

static void check(const char* name, bool ok) {
    if (ok) {
        ++g_pass;
        std::printf("  ok   %s\n", name);
    } else {
        ++g_fail;
        std::printf("  FAIL %s\n", name);
    }
}

static void checkStr(const char* name, const std::string& got, const std::string& expect) {
    if (got == expect) {
        ++g_pass;
        std::printf("  ok   %s\n", name);
    } else {
        ++g_fail;
        std::printf("  FAIL %s\n       got=%s\n       exp=%s\n", name, got.c_str(), expect.c_str());
    }
}

static void checkInt(const char* name, long got, long expect) {
    if (got == expect) {
        ++g_pass;
        std::printf("  ok   %s\n", name);
    } else {
        ++g_fail;
        std::printf("  FAIL %s\n       got=%ld\n       exp=%ld\n", name, got, expect);
    }
}

int main() {
    // ── 1. 归一化 ──
    std::printf("[1] 号码归一化\n");
    checkStr("normalize(13800138000)", normalizeNumber("13800138000"), "8613800138000");
    checkStr("normalize(+86 138-0013-8000)", normalizeNumber("+86 138-0013-8000"), "8613800138000");
    checkStr("normalize(8613800138000)", normalizeNumber("8613800138000"), "8613800138000");
    checkStr("normalize(008613800138000)", normalizeNumber("008613800138000"), "8613800138000");
    checkStr("normalize(010-12345678)", normalizeNumber("010-12345678"), "861012345678");
    checkStr("normalize(spaces)", normalizeNumber("  138 0013 8000  "), "8613800138000");
    checkStr("normalize(empty)", normalizeNumber(""), "");
    checkStr("normalize(abc)", normalizeNumber("abc"), "");

    // ── 2. 精确匹配 ──
    std::printf("\n[2] 精确匹配\n");
    {
        RuleEngine e;
        e.addRule(Rule{1, RuleType::Exact, Action::Block, "13800138000", "骚扰电话", true});
        e.addRule(Rule{2, RuleType::Exact, Action::Block, "13900139000", "催收", true});
        e.finalize();

        auto r = e.evaluate("13800138000");
        check("命中精确号码", r.matched && r.action == Action::Block && r.reason == "exact");
        check("带 +86 也命中", e.evaluate("+8613800138000").matched);
        check("未收录号码不命中", !e.evaluate("13700137000").matched);
    }

    // ── 3. 最长前缀 ──
    std::printf("\n[3] 前缀（最长匹配）\n");
    {
        RuleEngine e;
        e.addRule(Rule{10, RuleType::Prefix, Action::Mark,  "170",  "虚拟运营商", true});
        e.addRule(Rule{11, RuleType::Prefix, Action::Block, "1700", "虚拟运营商-1700", true});
        e.addRule(Rule{12, RuleType::Prefix, Action::Mark,  "95",   "95 外呼", true});
        e.finalize();

        auto r1 = e.evaluate("17001234567");
        checkInt("1700 命中更长规则", r1.ruleId, 11);
        check("1700 动作为 Block", r1.action == Action::Block);

        auto r2 = e.evaluate("17091234567");
        checkInt("1709 命中较短规则", r2.ruleId, 10);

        checkInt("95 段命中", e.evaluate("95123456").ruleId, 12);
        check("普通手机号不命中", !e.evaluate("13800138000").matched);
    }

    // ── 4. 白名单 ──
    std::printf("\n[4] 白名单优先级\n");
    {
        RuleEngine e;
        e.addRule(Rule{20, RuleType::Prefix, Action::Block, "170", "虚拟运营商", true});
        e.addRule(Rule{21, RuleType::Exact,  Action::Block, "17001234567", "已举报", true});
        e.addWhitelist("17001234567");
        e.finalize();

        auto r = e.evaluate("17001234567");
        check("白名单压过精确规则", r.action == Action::Allow && r.reason == "whitelist");
        check("白名单外仍被拦", e.evaluate("17009999999").action == Action::Block);
    }

    // 白名单前缀（银行 / 运营商整段放行）
    {
        RuleEngine e;
        e.addRule(Rule{22, RuleType::Prefix, Action::Mark, "95", "95 企业外呼", true});
        e.addWhitelistPrefix("955");
        e.finalize();

        check("95588 命中白名单前缀", e.evaluate("95588").action == Action::Allow);
        check("95588 不落入 95 黑名单", e.evaluate("95588").reason == "whitelist");
        check("95188 仍被标记", e.evaluate("95188").action == Action::Mark);
    }

    // ── 5. 区间 ──
    std::printf("\n[5] 号码区间\n");
    {
        RuleEngine e;
        e.addRule(Rule{30, RuleType::Range, Action::Block,
                       "13100000000-13100000999", "号段区间", true});
        e.finalize();

        check("区间左边界", e.evaluate("13100000000").matched);
        check("区间右边界", e.evaluate("13100000999").matched);
        check("区间中间值", e.evaluate("13100000500").matched);
        check("区间外（右+1）", !e.evaluate("13100001000").matched);
        check("区间外（左-1）", !e.evaluate("13199999999").matched);
    }

    // ── 6. 正则 ──
    std::printf("\n[6] 正则\n");
    {
        RuleEngine e;
        e.addRule(Rule{40, RuleType::Regex, Action::Mark, "86(170|171)\\d{8}", "虚拟号段正则", true});
        e.finalize();

        check("正则命中 170", e.evaluate("17012345678").matched);
        check("正则命中 171", e.evaluate("17112345678").matched);
        check("正则不命中 172", !e.evaluate("17212345678").matched);

        RuleEngine e2;
        e2.addRule(Rule{41, RuleType::Regex, Action::Block, "86(170", "坏正则", true});
        e2.finalize();
        check("非法正则被跳过", !e2.evaluate("17012345678").matched);
    }

    // ── 7. 禁用规则 ──
    std::printf("\n[7] 禁用规则\n");
    {
        RuleEngine e;
        e.addRule(Rule{50, RuleType::Exact, Action::Block, "13800138000", "已停用", false});
        e.finalize();

        check("禁用规则不生效", !e.evaluate("13800138000").matched);
        checkInt("禁用规则不计数", (long)e.ruleCount(), 0);
    }

    // ── 8. 匹配顺序 ──
    std::printf("\n[8] 匹配顺序：精确 > 前缀 > 正则\n");
    {
        RuleEngine e;
        e.addRule(Rule{60, RuleType::Regex,  Action::Mark,    "86\\d{11}", "全量正则", true});
        e.addRule(Rule{61, RuleType::Prefix, Action::Silence, "13",        "13 段", true});
        e.addRule(Rule{62, RuleType::Exact,  Action::Block,   "13800138000", "精确黑名单", true});
        e.finalize();

        auto r1 = e.evaluate("13800138000");
        checkInt("精确优先于前缀", r1.ruleId, 62);
        check("精确 reason", r1.reason == "exact");

        auto r2 = e.evaluate("13100131000");
        checkInt("前缀优先于正则", r2.ruleId, 61);
        check("前缀 reason", r2.reason == "prefix");

        auto r3 = e.evaluate("19900199000");
        checkInt("落到正则", r3.ruleId, 60);
        check("正则 reason", r3.reason == "regex");
    }

    // ── 9. 边界 ──
    std::printf("\n[9] 边界\n");
    {
        RuleEngine e;
        e.addRule(Rule{70, RuleType::Exact, Action::Block, "1", "单字符", true});
        e.finalize();

        (void)e.evaluate("1");
        check("极短号码不崩", true);
        check("空输入不崩", !e.evaluate("").matched);
        check("纯符号不崩", !e.evaluate("+++---").matched);
        check("超长输入不崩", !e.evaluate(std::string(200, '1')).matched);
    }

    // ── 10. 规模压测 ──
    std::printf("\n[10] 规模（10 万前缀规则）\n");
    {
        RuleEngine e;
        for (int i = 0; i < 100000; ++i) {
            // 生成 8613xxxxxxx 形式的前缀
            char buf[16];
            std::snprintf(buf, sizeof(buf), "8613%07d", i);
            e.addRule(Rule{i, RuleType::Prefix, Action::Mark, buf, "压测", true});
        }
        e.finalize();
        checkInt("规则数", (long)e.ruleCount(), 100000);
        check("Trie 节点已构建", e.trieNodes() > 100000);
        check("命中压测规则", e.evaluate("86130000001").matched);
        check("未命中压测规则", !e.evaluate("86999999999").matched);
    }

    std::printf("\n============================================\n");
    std::printf("  通过 %d / %d\n", g_pass, g_pass + g_fail);
    if (g_fail) std::printf("  失败 %d\n", g_fail);
    std::printf("============================================\n");

    return g_fail ? 1 : 0;
}
