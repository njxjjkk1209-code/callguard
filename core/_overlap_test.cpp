
#include <cstdio>
#include "CallGuardRules.hpp"
int main(){
    cg::RuleEngine e;
    cg::Rule a; a.id=1; a.type=cg::RuleType::Range; a.action=cg::Action::Mark; a.value="17000000000-17999999999"; a.enabled=true;
    cg::Rule b; b.id=2; b.type=cg::RuleType::Range; b.action=cg::Action::Block; b.value="17050000000-17050000999"; b.enabled=true;
    e.addRule(a); e.addRule(b); e.finalize();
    auto r1=e.evaluate("17060000000");
    auto r2=e.evaluate("17050000050");
    printf("外层区间命中: matched=%d ruleId=%d (期望 1)
", r1.matched, r1.ruleId);
    printf("内层区间命中: matched=%d ruleId=%d (期望 2)
", r2.matched, r2.ruleId);
    return 0;
}
