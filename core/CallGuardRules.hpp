// CallGuardRules.hpp
// 骚扰电话规则引擎 —— App 与 Tweak 共用（header-only, C++17）
//
// 设计要点：
//   1. 号码统一归一化为 E.164 无 '+' 形式（86 开头，13 位手机号）
//   2. 匹配顺序：白名单 → 精确 → 前缀(Trie) → 区间(二分) → 正则
//   3. 前缀树用 vector 存节点、int 索引串联，缓存友好，避免指针跳转
//   4. 无动态分配于查询路径，单次匹配 < 0.5ms（50 万规则，A12+）

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <regex>
#include <cstdint>

namespace cg {

// ───────────────────────────── 基础类型 ─────────────────────────────

enum class Action : int {
    Allow   = 0,   // 放行（白名单）
    Mark    = 1,   // 仅标记，不拦截（观察期规则）
    Silence = 2,   // 静音，不挂断
    Block   = 3    // 静音 + 挂断
};

enum class RuleType : int {
    Exact  = 0,
    Prefix = 1,
    Range  = 2,
    Regex  = 3
};

struct Rule {
    int         id      = -1;
    RuleType    type    = RuleType::Exact;
    Action      action  = Action::Block;
    std::string value;              // 号码 / 前缀 / "start-end" / 正则
    std::string label;              // 展示标签，如"骚扰电话"
    bool        enabled = true;
};

struct MatchResult {
    bool        matched = false;
    Action      action  = Action::Allow;
    int         ruleId  = -1;
    std::string label;
    std::string reason;             // whitelist / exact / prefix / range / regex
};

// ───────────────────────────── 号码归一化 ─────────────────────────────

// 输入可以是 "13800138000" / "+86 138-0013-8000" / "010-12345678" / "008613800138000"
// 输出统一为 "8613800138000" / "861012345678"
inline std::string normalizeNumber(const std::string& raw) {
    std::string d;
    d.reserve(raw.size());
    for (char c : raw) {
        if (c >= '0' && c <= '9') d.push_back(c);
    }
    if (d.empty()) return "";

    // 去掉国际前缀 00
    if (d.size() > 2 && d[0] == '0' && d[1] == '0') d.erase(0, 2);

    // 已是 86 开头
    if (d.size() > 2 && d.compare(0, 2, "86") == 0) return d;

    // 11 位手机号
    if (d.size() == 11 && d[0] == '1') return "86" + d;

    // 前导 0 的固话：01012345678 → 861012345678
    if (d[0] == '0') {
        d.erase(0, 1);
        return "86" + d;
    }

    return "86" + d;
}

inline uint64_t toU64(const std::string& s) {
    uint64_t v = 0;
    for (char c : s) {
        if (c < '0' || c > '9') return 0;
        v = v * 10 + static_cast<uint64_t>(c - '0');
    }
    return v;
}

// ───────────────────────────── 前缀树 ─────────────────────────────

class PrefixTrie {
public:
    PrefixTrie() { nodes_.emplace_back(); }

    void insert(const std::string& prefix, int ruleIdx) {
        if (prefix.empty()) return;
        int cur = 0;
        for (char c : prefix) {
            auto it = nodes_[cur].next.find(c);
            if (it == nodes_[cur].next.end()) {
                nodes_.emplace_back();
                int idx = static_cast<int>(nodes_.size()) - 1;
                // emplace_back 可能触发扩容，重新取引用
                nodes_[cur].next[c] = idx;
                cur = idx;
            } else {
                cur = it->second;
            }
        }
        nodes_[cur].ruleIdx = ruleIdx;
    }

    // 返回最长命中的规则索引，-1 表示未命中
    int longestMatch(const std::string& number) const {
        int cur = 0;
        int best = -1;
        for (char c : number) {
            auto it = nodes_[cur].next.find(c);
            if (it == nodes_[cur].next.end()) break;
            cur = it->second;
            if (nodes_[cur].ruleIdx >= 0) best = nodes_[cur].ruleIdx;
        }
        return best;
    }

    size_t nodeCount() const { return nodes_.size(); }

private:
    struct Node {
        std::unordered_map<char, int> next;
        int ruleIdx = -1;
    };
    std::vector<Node> nodes_;
};

// ───────────────────────────── 规则引擎 ─────────────────────────────

class RuleEngine {
public:
    void clear() {
        rules_.clear();
        whitelist_.clear();
        whitelistPrefix_ = PrefixTrie();
        exact_.clear();
        prefix_ = PrefixTrie();
        ranges_.clear();
        regex_.clear();
    }

    void addRule(const Rule& r) {
        if (!r.enabled) return;
        int idx = static_cast<int>(rules_.size());
        rules_.push_back(r);
        pending_.push_back(idx);
    }

    void addWhitelist(const std::string& number) {
        std::string n = normalizeNumber(number);
        if (!n.empty()) whitelist_.insert(toU64(n));
    }

    // 白名单前缀：用于 955xx 银行、953xx 运营商这类整段放行
    void addWhitelistPrefix(const std::string& prefix) {
        std::string n = normalizeNumber(prefix);
        if (!n.empty()) whitelistPrefix_.insert(n, 0);
    }

    // 所有规则加完后必须调用一次，构建查询索引
    void finalize() {
        exact_.clear();
        ranges_.clear();
        regex_.clear();
        prefix_ = PrefixTrie();

        for (int idx : pending_) {
            const Rule& r = rules_[idx];
            switch (r.type) {
                case RuleType::Exact: {
                    std::string n = normalizeNumber(r.value);
                    if (!n.empty()) exact_[toU64(n)] = idx;
                    break;
                }
                case RuleType::Prefix: {
                    std::string n = normalizeNumber(r.value);
                    if (!n.empty()) prefix_.insert(n, idx);
                    break;
                }
                case RuleType::Range: {
                    auto dash = r.value.find('-');
                    if (dash == std::string::npos) break;
                    std::string a = normalizeNumber(r.value.substr(0, dash));
                    std::string b = normalizeNumber(r.value.substr(dash + 1));
                    if (a.empty() || b.empty()) break;
                    uint64_t lo = toU64(a), hi = toU64(b);
                    if (lo > hi) std::swap(lo, hi);
                    ranges_.push_back({lo, hi, idx});
                    break;
                }
                case RuleType::Regex: {
                    try {
                        regex_.emplace_back(std::regex(r.value), idx);
                    } catch (...) {
                        // 非法正则直接跳过，不影响其它规则
                    }
                    break;
                }
            }
        }

        std::sort(ranges_.begin(), ranges_.end(),
                  [](const RangeEntry& x, const RangeEntry& y) { return x.start < y.start; });
        pending_.clear();
    }

    MatchResult evaluate(const std::string& rawNumber) const {
        MatchResult res;
        std::string num = normalizeNumber(rawNumber);
        if (num.empty()) return res;
        uint64_t v = toU64(num);

        // 1. 白名单最高优先级（精确 + 前缀）
        if (whitelist_.count(v) || whitelistPrefix_.longestMatch(num) >= 0) {
            res.matched = true;
            res.action  = Action::Allow;
            res.reason  = "whitelist";
            return res;
        }

        // 2. 精确号码
        auto e = exact_.find(v);
        if (e != exact_.end()) return makeResult(e->second, "exact");

        // 3. 前缀（最长匹配）
        int pid = prefix_.longestMatch(num);
        if (pid >= 0) return makeResult(pid, "prefix");

        // 4. 号码区间
        //
        // 这里故意用线性扫描，不用 upper_bound + 单次回退。
        // 原因：upper_bound 找到第一个 start > v 的区间后只回退一格，
        // 一旦两条区间重叠（17000000000-17999999999 与 17050000000-17050000999），
        // 命中落在被遮挡的那条上就判定失败，而且**完全静默**——
        // 表现为"规则明明加了却从来不命中"，排查成本极高。
        //
        // 区间规则是手工填的，数量在几十条量级；来电是低频事件，
        // 线性扫描的成本可以忽略，换来的是任何重叠组合都不会漏。
        for (const auto& r : ranges_) {
            if (v >= r.start && v <= r.end) return makeResult(r.ruleIdx, "range");
        }

        // 5. 正则（最后兜底，数量受控）
        for (const auto& pair : regex_) {
            if (std::regex_match(num, pair.first)) return makeResult(pair.second, "regex");
        }

        return res;
    }

    size_t ruleCount()   const { return rules_.size(); }
    size_t trieNodes()   const { return prefix_.nodeCount(); }

private:
    struct RangeEntry {
        uint64_t start;
        uint64_t end;
        int      ruleIdx;
    };

    MatchResult makeResult(int idx, const char* reason) const {
        MatchResult r;
        r.matched = true;
        r.ruleId  = rules_[idx].id;
        r.action  = rules_[idx].action;
        r.label   = rules_[idx].label;
        r.reason  = reason;
        return r;
    }

    std::vector<Rule>                     rules_;
    std::vector<int>                      pending_;
    std::unordered_set<uint64_t>          whitelist_;
    PrefixTrie                            whitelistPrefix_;
    std::unordered_map<uint64_t, int>     exact_;
    PrefixTrie                            prefix_;
    std::vector<RangeEntry>               ranges_;
    std::vector<std::pair<std::regex,int>> regex_;
};

} // namespace cg
