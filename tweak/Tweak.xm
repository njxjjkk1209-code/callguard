//
//  Tweak.xm
//  CallGuard 越狱插件 —— Hook SpringBoard 来电界面，实时拦截。
//
//  为什么需要这一层：
//    CallDirectory 只能做精确号码匹配，号段 / 正则 / 前缀全部做不到。
//    170/171/162/165/167 这类虚拟运营商号段，只有在这里才能整段拦掉。
//
//  工作方式：
//    来电界面创建时拿 TUCall → 取 remoteHandle.value → 跑 C++ 规则引擎
//    → 命中 Block 就调 TUCallCenter 挂断，命中 Silence 就把铃声音量压到 0
//
//  数据通道：
//    SpringBoard 读不到 App 沙盒，走固定路径 /var/mobile/Library/CallGuard/
//    tweak_rules.plist 由 App 导出，每次来电检查 mtime，变了就重载。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <sys/stat.h>

#include <memory>
#include <mutex>
#include <string>

#include "CallGuardRules.hpp"

// ─────────────────────────── 全局状态 ───────────────────────────

static NSString *const kConfigPath = @"/var/mobile/Library/CallGuard/tweak_rules.plist";
static NSString *const kLogPath    = @"/var/mobile/Library/CallGuard/tweak_log.jsonl";

static std::unique_ptr<cg::RuleEngine> gEngine;
static std::mutex                      gEngineLock;
static time_t                          gConfigMTime = 0;
static BOOL                            gEnabled     = YES;

static NSMutableSet<NSString *>       *gHandled     = nil;
static NSLock                         *gHandledLock = nil;

// ─────────────────────────── 配置加载 ───────────────────────────

static void CGLoadConfig(BOOL force) {
    struct stat st;
    if (stat(kConfigPath.UTF8String, &st) != 0) return;
    if (!force && st.st_mtime == gConfigMTime) return;
    gConfigMTime = st.st_mtime;

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (![dict isKindOfClass:[NSDictionary class]]) return;

    gEnabled = [dict[@"enabled"] boolValue];

    auto eng = std::make_unique<cg::RuleEngine>();

    NSArray *rules = dict[@"rules"];
    if ([rules isKindOfClass:[NSArray class]]) {
        for (NSDictionary *d in rules) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;

            cg::Rule r;
            r.id      = [d[@"id"] intValue];
            r.type    = static_cast<cg::RuleType>([d[@"type"] intValue]);
            r.action  = static_cast<cg::Action>([d[@"action"] intValue]);
            r.value   = [d[@"value"] isKindOfClass:[NSString class]]
                        ? std::string([d[@"value"] UTF8String]) : std::string();
            r.label   = [d[@"label"] isKindOfClass:[NSString class]]
                        ? std::string([d[@"label"] UTF8String]) : std::string();
            r.enabled = [d[@"enabled"] boolValue];
            eng->addRule(r);
        }
    }

    NSArray *wl = dict[@"whitelist"];
    if ([wl isKindOfClass:[NSArray class]]) {
        for (id s in wl) {
            if ([s isKindOfClass:[NSString class]]) {
                eng->addWhitelist(std::string([s UTF8String]));
            }
        }
    }

    NSArray *wlp = dict[@"whitelistPrefix"];
    if ([wlp isKindOfClass:[NSArray class]]) {
        for (id s in wlp) {
            if ([s isKindOfClass:[NSString class]]) {
                eng->addWhitelistPrefix(std::string([s UTF8String]));
            }
        }
    }

    eng->finalize();

    {
        std::lock_guard<std::mutex> lock(gEngineLock);
        gEngine = std::move(eng);
    }

    NSLog(@"[CallGuard] 配置已加载：%zu 条规则，enabled=%d",
          gEngine ? gEngine->ruleCount() : 0, gEnabled);
}

// ─────────────────────────── 规则评估 ───────────────────────────

static cg::MatchResult CGEvaluate(NSString *number) {
    cg::MatchResult out;
    if (![number isKindOfClass:[NSString class]] || number.length == 0) return out;

    std::lock_guard<std::mutex> lock(gEngineLock);
    if (!gEngine) return out;
    return gEngine->evaluate(std::string(number.UTF8String));
}

// ─────────────────────────── 号码提取 ───────────────────────────

static NSString *CGNumberFromCall(id call) {
    if (!call) return nil;

    @try {
        // TUCall.remoteHandle → TUHandle.value
        id handle = [call valueForKey:@"remoteHandle"];
        if (handle && [handle respondsToSelector:@selector(value)]) {
            id v = [handle performSelector:@selector(value)];
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                return v;
            }
        }

        // 备用：部分场景 remoteHandle 为空，退回 destinationID
        for (NSString *key in @[@"destinationID", @"callerId"]) {
            id v = nil;
            @try { v = [call valueForKey:key]; } @catch (NSException *e) { continue; }
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) {
                return v;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 取号码失败: %@", e.reason);
    }

    return nil;
}

// ─────────────────────────── 安全调用 ───────────────────────────
//
// 私有 API 的参数类型不确定（NSInteger / int / BOOL 混用），
// 直接 performSelector 传 NSNumber 会错位甚至崩溃。
// 这里按方法签名里的真实类型逐个塞参数。

static BOOL CGInvoke(id target, SEL sel, NSArray *args) {
    if (!target || ![target respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:target];
    [inv setSelector:sel];

    NSUInteger idx = 2;
    for (id arg in args) {
        if (idx >= sig.numberOfArguments) break;
        const char *type = [sig getArgumentTypeAtIndex:idx];

        switch (type[0]) {
            case '@': {
                id a = arg;
                [inv setArgument:&a atIndex:idx];
                break;
            }
            case 'q': case 'Q': {
                long long v = [arg longLongValue];
                [inv setArgument:&v atIndex:idx];
                break;
            }
            case 'i': case 'I': {
                int v = [arg intValue];
                [inv setArgument:&v atIndex:idx];
                break;
            }
            case 'c': case 'C': {
                char v = (char)[arg charValue];
                [inv setArgument:&v atIndex:idx];
                break;
            }
            case 'f': case 'd': {
                double v = [arg doubleValue];
                [inv setArgument:&v atIndex:idx];
                break;
            }
            default:
                break;
        }
        idx++;
    }

    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 调用 %@ 失败: %@", NSStringFromSelector(sel), e.reason);
        return NO;
    }
}

// ─────────────────────────── 挂断 ───────────────────────────

static void CGHangUp(id call) {
    if (!call) return;

    // 1. TUCallCenter -disconnectCall:withReason:  （首选，社区验证过的路径）
    Class centerCls = NSClassFromString(@"TUCallCenter");
    if (centerCls && [centerCls respondsToSelector:@selector(sharedInstance)]) {
        id center = [centerCls performSelector:@selector(sharedInstance)];
        if (CGInvoke(center, @selector(disconnectCall:withReason:), @[call, @(1)])) {
            NSLog(@"[CallGuard] 已挂断（TUCallCenter）");
            return;
        }
    }

    // 2. TUCall -disconnectWithReason:
    if (CGInvoke(call, @selector(disconnectWithReason:), @[@(1)])) {
        NSLog(@"[CallGuard] 已挂断（TUCall）");
        return;
    }

    // 3. TUCall -disconnect
    if (CGInvoke(call, @selector(disconnect), @[])) {
        NSLog(@"[CallGuard] 已挂断（disconnect）");
        return;
    }

    NSLog(@"[CallGuard] 挂断失败：没有可用 API");
}

// ─────────────────────────── 静音 ───────────────────────────

static void CGSilenceRing(void) {
    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls || ![cls respondsToSelector:@selector(sharedAVSystemController)]) {
        NSLog(@"[CallGuard] 静音失败：AVSystemController 不可用");
        return;
    }

    id ctrl = [cls performSelector:@selector(sharedAVSystemController)];
    SEL sel = @selector(setVolumeTo:forCategory:);
    NSMethodSignature *sig = [ctrl methodSignatureForSelector:sel];
    if (!sig) {
        NSLog(@"[CallGuard] 静音失败：setVolumeTo:forCategory: 不存在");
        return;
    }

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ctrl];
    [inv setSelector:sel];

    float volume = 0.0f;
    [inv setArgument:&volume atIndex:2];

    id category = @"Ringtone";
    [inv setArgument:&category atIndex:3];

    @try {
        [inv invoke];
        NSLog(@"[CallGuard] 已静音");
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 静音失败: %@", e.reason);
    }
}

// ─────────────────────────── 日志 ───────────────────────────

static void CGWriteLog(NSString *number, const cg::MatchResult &r) {
    if (![number isKindOfClass:[NSString class]]) return;

    NSDictionary *entry = @{
        @"number": number,
        @"action": @(static_cast<int>(r.action)),
        @"ruleId": @(r.ruleId),
        @"label":  r.label.empty()  ? @"" : [NSString stringWithUTF8String:r.label.c_str()],
        @"reason": r.reason.empty() ? @"" : [NSString stringWithUTF8String:r.reason.c_str()],
        @"ts":     @([[NSDate date] timeIntervalSince1970])
    };

    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
    if (!json) return;

    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) {
        [fm createFileAtPath:kLogPath contents:nil attributes:nil];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) return;

    @try {
        [fh seekToEndOfFile];
        [fh writeData:line];
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 写日志失败: %@", e.reason);
    } @finally {
        [fh closeFile];
    }
}

// ─────────────────────────── 主处理 ───────────────────────────

static void CGHandleCall(id call) {
    @autoreleasepool {
        if (!gEnabled || !call) return;

        NSString *number = CGNumberFromCall(call);
        if (!number.length) return;

        // 同一个来电会被 init 和 viewWillAppear 各触发一次，用 UUID 去重
        NSString *uuid = nil;
        @try { uuid = [call valueForKey:@"callUUID"]; } @catch (NSException *e) {}
        if (![uuid isKindOfClass:[NSString class]] || !uuid.length) uuid = number;

        [gHandledLock lock];
        BOOL seen = [gHandled containsObject:uuid];
        if (!seen) {
            [gHandled addObject:uuid];
            if (gHandled.count > 64) {
                [gHandled removeObject:[gHandled anyObject]];
            }
        }
        [gHandledLock unlock];

        if (seen) return;

        CGLoadConfig(NO);

        cg::MatchResult r = CGEvaluate(number);
        if (!r.matched) return;

        NSLog(@"[CallGuard] 命中 %@ → action=%d reason=%s",
              number, static_cast<int>(r.action), r.reason.c_str());

        switch (r.action) {
            case cg::Action::Allow:
            case cg::Action::Mark:
                CGWriteLog(number, r);
                break;
            case cg::Action::Silence:
                CGSilenceRing();
                CGWriteLog(number, r);
                break;
            case cg::Action::Block:
                CGHangUp(call);
                CGWriteLog(number, r);
                break;
        }
    }
}

// ─────────────────────────── Hook ───────────────────────────

// 锁屏来电（主路径）
%hook SBDashBoardIncomingCallViewController

- (instancetype)initWithCall:(id)call {
    id ret = %orig;
    CGHandleCall(call);
    return ret;
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    id call = nil;
    @try { call = [self valueForKey:@"call"]; } @catch (NSException *e) {}
    CGHandleCall(call);
}

%end

// 解锁状态下的来电横幅（不同系统版本类名有差异，类不存在时 %hook 不生效、不崩溃）
%hook SBIncomingCallAlertItem

- (instancetype)initWithCall:(id)call {
    id ret = %orig;
    CGHandleCall(call);
    return ret;
}

%end

// ─────────────────────────── 初始化 ───────────────────────────

%ctor {
    @autoreleasepool {
        gHandledLock = [NSLock new];
        gHandled     = [NSMutableSet new];

        CGLoadConfig(YES);

        size_t count = 0;
        {
            std::lock_guard<std::mutex> lock(gEngineLock);
            if (gEngine) count = gEngine->ruleCount();
        }

        NSLog(@"[CallGuard] Tweak 已加载，规则 %zu 条，enabled=%d", count, gEnabled);
    }
}
