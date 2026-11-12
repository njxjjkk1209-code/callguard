//
//  CallGuardEngine.mm
//  Objective-C++ 包装，把 C++ 规则引擎暴露给 Swift。
//

#import "CallGuardEngine.h"

#include "CallGuardRules.hpp"

#include <memory>
#include <string>

@implementation CGRule
@end

@implementation CGMatchResult
@end

@implementation CGEngine {
    std::unique_ptr<cg::RuleEngine> _engine;
}

- (instancetype)init {
    if ((self = [super init])) {
        _engine = std::make_unique<cg::RuleEngine>();
    }
    return self;
}

- (void)dealloc {
    _engine.reset();
}

- (void)addRule:(CGRule *)rule {
    if (!_engine || !rule) return;

    cg::Rule r;
    r.id      = static_cast<int>(rule.ruleId);
    r.type    = static_cast<cg::RuleType>(rule.type);
    r.action  = static_cast<cg::Action>(rule.action);
    r.value   = rule.value ? std::string(rule.value.UTF8String) : std::string();
    r.label   = rule.label ? std::string(rule.label.UTF8String) : std::string();
    r.enabled = rule.enabled;

    _engine->addRule(r);
}

- (void)addWhitelist:(NSString *)number {
    if (!_engine || !number) return;
    _engine->addWhitelist(std::string(number.UTF8String));
}

- (void)addWhitelistPrefix:(NSString *)prefix {
    if (!_engine || !prefix) return;
    _engine->addWhitelistPrefix(std::string(prefix.UTF8String));
}

- (void)finalizeEngine {
    if (_engine) _engine->finalize();
}

- (CGMatchResult *)evaluate:(NSString *)number {
    CGMatchResult *out = [CGMatchResult new];
    out.matched = NO;
    out.action  = CGActionAllow;
    out.ruleId  = -1;
    out.label   = @"";
    out.reason  = @"";

    if (!_engine || !number) return out;

    cg::MatchResult r = _engine->evaluate(std::string(number.UTF8String));

    out.matched = r.matched;
    out.action  = static_cast<CGAction>(r.action);
    out.ruleId  = r.ruleId;
    out.label   = r.label.empty() ? @"" : [NSString stringWithUTF8String:r.label.c_str()];
    out.reason  = r.reason.empty() ? @"" : [NSString stringWithUTF8String:r.reason.c_str()];
    return out;
}

- (NSInteger)ruleCount {
    return _engine ? static_cast<NSInteger>(_engine->ruleCount()) : 0;
}

+ (NSString *)normalize:(NSString *)number {
    if (!number) return @"";
    std::string n = cg::normalizeNumber(std::string(number.UTF8String));
    return n.empty() ? @"" : [NSString stringWithUTF8String:n.c_str()];
}

@end
