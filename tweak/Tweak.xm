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
#import <unistd.h>   // getpid()

#include <memory>
#include <mutex>
#include <string>

#include "CallGuardRules.hpp"

// ─────────────────────────── 全局状态 ───────────────────────────

// 候选目录必须与 SharedConfig.tweakDirectoryCandidates 顺序完全一致。
// SpringBoard 有完整权限，%ctor 里会尝试把它们建出来——这样即使 App 因为
// TrollStore 签名模板不带 no-sandbox 而建不了目录，这里也先建好了，
// App 只需要写文件即可。
static NSArray<NSString *> *CGDirectoryCandidates(void) {
    return @[
        @"/var/mobile/Library/CallGuard",
        @"/var/jb/var/mobile/Library/CallGuard",
        @"/var/mobile/Documents/CallGuard",
    ];
}

static NSString *gConfigPath = nil;
static NSString *gLogPath    = nil;

/// 找 App Group 容器目录。
///
/// 这是**主通道**：App 写自己的容器是沙盒内行为，一定成功；
/// SpringBoard 越狱后不受沙盒限制，能直接读任意容器。
/// 所以这条路不依赖 TrollStore 是否给 App 解除了沙盒。
///
/// 定位方式：遍历 /var/mobile/Containers/Shared/AppGroup，
/// 用 metadata plist 里的 MCMMetadataIdentifier 匹配 group id。
static NSString *CGAppGroupDir(void) {
    static NSString *cached = nil;
    if (cached) return cached;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *subs = [fm contentsOfDirectoryAtPath:base error:NULL];
    if (![subs isKindOfClass:[NSArray class]]) return nil;

    for (NSString *sub in subs) {
        NSString *dir = [base stringByAppendingPathComponent:sub];
        NSString *meta = [dir stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:meta];
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        if ([m[@"MCMMetadataIdentifier"] isEqualToString:@"group.com.k.callguard"]) {
            cached = dir;
            return cached;
        }
    }
    return nil;
}

/// 确定配置/日志路径：先容器，再固定路径
static void CGResolveDirectory(void) {
    if (gConfigPath) return;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. App Group 容器
    NSString *group = CGAppGroupDir();
    if (group) {
        gConfigPath = [group stringByAppendingPathComponent:@"tweak_rules.plist"];
        gLogPath    = [group stringByAppendingPathComponent:@"tweak_log.jsonl"];
        return;
    }

    // 2. 固定路径兜底（同时负责把目录建出来）
    for (NSString *dir in CGDirectoryCandidates()) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
            NSError *err = nil;
            if (![fm createDirectoryAtPath:dir
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:&err]) {
                continue;
            }
        }
        // 探针验证：能建目录不代表能写文件（属主 root + 755 就会失败）
        NSString *probe = [dir stringByAppendingPathComponent:@".cg_probe"];
        if ([@"ok" writeToFile:probe atomically:YES
                      encoding:NSUTF8StringEncoding error:NULL]) {
            [fm removeItemAtPath:probe error:NULL];
            gConfigPath = [dir stringByAppendingPathComponent:@"tweak_rules.plist"];
            gLogPath    = [dir stringByAppendingPathComponent:@"tweak_log.jsonl"];
            return;
        }
    }

    // 一个都写不了：记下首选路径，写日志时会静默失败，但不影响拦截
    NSString *first = CGDirectoryCandidates().firstObject;
    gConfigPath = [first stringByAppendingPathComponent:@"tweak_rules.plist"];
    gLogPath    = [first stringByAppendingPathComponent:@"tweak_log.jsonl"];
}

static std::unique_ptr<cg::RuleEngine> gEngine;
static std::mutex                      gEngineLock;
static time_t                          gConfigMTime = 0;
static BOOL                            gEnabled     = YES;

static NSMutableSet<NSString *>       *gHandled     = nil;
static NSLock                         *gHandledLock = nil;

// ─────────────────────────── 心跳 ───────────────────────────

// 由 CI 注入（-DCGBUILD_COMMIT=...），本地手编时回落到 dev。
#ifndef CGBUILD_COMMIT
#define CGBUILD_COMMIT "dev"
#endif
#ifndef CGBUILD_TIME
#define CGBUILD_TIME "unknown"
#endif

// hook 自检结果，由 CGProbeHooks() 填充，写进心跳供 App 展示。
static int gHookedCount = 0;
static int gHookedTotal = 0;

/// 写心跳文件，让 App 知道 Tweak 已经在 SpringBoard 里跑起来了。
///
/// 放在 App Group 容器里，App 直接读，不需要任何额外权限。
/// 这比"配置文件存在"可靠得多 —— 配置存在只能说明 App 导出成功，
/// 跟 Tweak 有没有被 SpringBoard 加载完全是两件事。
///
/// hooked/hookTotal 的意义：
/// Logos 的 %hook 遇到"类存在但方法不存在"时**不报错、不崩溃、静默失效**。
/// 只靠 L1 绿点会骗人（Tweak 加载了，但一条 hook 都没挂上）。
/// 把实际挂载数写出来，App 才能显示「已运行 · 挂载 1/2 hook」并飘红。
static void CGWriteReadyMarker(size_t ruleCount) {
    CGResolveDirectory();
    if (!gLogPath) return;

    NSString *dir    = [gLogPath stringByDeletingLastPathComponent];
    NSString *marker = [dir stringByAppendingPathComponent:@"tweak_ready.json"];

    NSDictionary *info = @{
        @"version":    @"1.0.0",
        @"commit":     @CGBUILD_COMMIT,
        @"buildTime":  @CGBUILD_TIME,
        @"startedAt":  @([[NSDate date] timeIntervalSince1970]),
        @"pid":        @(getpid()),
        @"ruleCount":  @(ruleCount),
        @"hooked":     @(gHookedCount),
        @"hookTotal":  @(gHookedTotal),
        @"configPath": gConfigPath ?: @"",
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:info options:0 error:NULL];
    if (d) [d writeToFile:marker atomically:YES];
}

// ─────────────────────────── 配置加载 ───────────────────────────

static void CGLoadConfig(BOOL force) {
    CGResolveDirectory();
    struct stat st;
    if (stat(gConfigPath.UTF8String, &st) != 0) {
        // 配置还没出现。可能是 App 后装的（容器这时才存在），
        // 重新解析一次通道，让 Tweak 不用 respring 也能自愈。
        gConfigPath = nil;
        CGResolveDirectory();
        if (stat(gConfigPath.UTF8String, &st) != 0) return;
    }
    if (!force && st.st_mtime == gConfigMTime) return;
    gConfigMTime = st.st_mtime;

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:gConfigPath];
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
//
// 【安全约束】静音必须可恢复。
//
// 旧实现直接把 Ringtone 音量写 0 就不管了 —— 用户只要命中一次 silence 规则，
// 之后**所有正常来电都不响**，而且 App 里没有恢复入口，只能去系统设置手动拉音量条。
// 这属于不可逆的实际损害，比"没有静音功能"糟糕得多。
//
// 现在的契约：
//   1. 先读当前 Ringtone 音量并存档；
//   2. 读不到（签名不符 / 返回异常）→ **不静音**，只记日志。宁可不禁音，也不毁铃声；
//   3. 通话结束（TUCallCenter 无 incomingCall 且无 currentCall）时写回存档值；
//   4. 每次处理新来电前做一次遗留检查，防止通知漏收导致音量卡在 0。

static float gSavedRingVolume = -1.0f;   // < 0 表示没有待恢复的存档
static NSLock *gRingVolumeLock = nil;

static id CGSharedAVSystemController(void) {
    Class cls = NSClassFromString(@"AVSystemController");
    if (!cls || ![cls respondsToSelector:@selector(sharedAVSystemController)]) return nil;
    return [cls performSelector:@selector(sharedAVSystemController)];
}

/// 读当前 Ringtone 音量。成功返回 YES 并写入 out。
///
/// 私有方法 `- (BOOL)getVolume:(float *)arg1 forCategory:(NSString *)arg2`
/// 的签名在不同系统版本上不统一（有的返回 BOOL，有的直接返回 float），
/// 所以这里按 methodReturnType 分支处理，并对结果做 0~1 合法性校验。
/// 校验不过就当作读取失败 —— 拿垃圾值去"恢复"比不恢复更糟。
static BOOL CGReadRingVolume(float *out) {
    id ctrl = CGSharedAVSystemController();
    if (!ctrl) return NO;

    SEL sel = @selector(getVolume:forCategory:);
    if (![ctrl respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [ctrl methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 4) return NO;

    float buf = 0.0f;
    float *bufPtr = &buf;
    NSString *category = @"Ringtone";

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ctrl];
    [inv setSelector:sel];
    [inv setArgument:&bufPtr atIndex:2];    // float* 输出参数：传指针的地址
    [inv setArgument:&category atIndex:3];

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 读铃声音量失败: %@", e.reason);
        return NO;
    }

    const char *rt = sig.methodReturnType;
    if (rt && (rt[0] == 'f' || rt[0] == 'd')) {
        // 直接返回 float 的变体
        float ret = 0.0f;
        [inv getReturnValue:&ret];
        if (ret > 0.001f && ret <= 1.0f) { *out = ret; return YES; }
    } else {
        // 返回 BOOL、音量走输出参数的变体
        BOOL ok = NO;
        [inv getReturnValue:&ok];
        if (ok && buf >= 0.0f && buf <= 1.0f) { *out = buf; return YES; }
    }

    // 兜底：输出参数有效就用它（有些版本返回值恒为 NO 但参数填对了）
    if (buf > 0.001f && buf <= 1.0f) { *out = buf; return YES; }
    return NO;
}

static BOOL CGSetRingVolume(float volume) {
    id ctrl = CGSharedAVSystemController();
    if (!ctrl) return NO;

    SEL sel = @selector(setVolumeTo:forCategory:);
    if (![ctrl respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [ctrl methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments < 4) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ctrl];
    [inv setSelector:sel];

    float v = volume;
    [inv setArgument:&v atIndex:2];
    NSString *category = @"Ringtone";
    [inv setArgument:&category atIndex:3];

    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        NSLog(@"[CallGuard] 写铃声音量失败: %@", e.reason);
        return NO;
    }
}

/// 当前是否还有活跃通话（来电响铃中或通话中）。
/// 两者都没有才允许恢复铃声音量。
static BOOL CGHasActiveCall(void) {
    Class cls = NSClassFromString(@"TUCallCenter");
    if (!cls || ![cls respondsToSelector:@selector(sharedInstance)]) return NO;

    id center = [cls performSelector:@selector(sharedInstance)];
    if (!center) return NO;

    for (NSString *key in @[@"incomingCall", @"currentCall", @"frontmostCall"]) {
        id v = nil;
        @try { v = [center valueForKey:key]; } @catch (NSException *e) { continue; }
        if (v && v != [NSNull null]) return YES;
    }
    return NO;
}

/// 恢复存档的铃声音量。可重复调用，没有存档时是空操作。
static void CGRestoreRingVolume(void) {
    if (!gRingVolumeLock) gRingVolumeLock = [NSLock new];
    [gRingVolumeLock lock];
    float saved = gSavedRingVolume;
    gSavedRingVolume = -1.0f;
    [gRingVolumeLock unlock];

    if (saved < 0) return;

    if (CGSetRingVolume(saved)) {
        NSLog(@"[CallGuard] 铃声已恢复至 %.2f", saved);
    } else {
        NSLog(@"[CallGuard] 铃声恢复失败，原值 %.2f", saved);
    }
}

/// 存档 + 静音。存档失败则整个动作放弃。
static void CGSilenceRingSafely(void) {
    if (!gRingVolumeLock) gRingVolumeLock = [NSLock new];

    // 已经有存档（连续来电）就不要覆盖，否则会把 0 存成"原值"
    [gRingVolumeLock lock];
    BOOL alreadySaved = (gSavedRingVolume >= 0);
    [gRingVolumeLock unlock];

    if (!alreadySaved) {
        float current = 0.0f;
        if (!CGReadRingVolume(&current)) {
            NSLog(@"[CallGuard] 静音已跳过：读不到当前铃声音量，为避免永久静音不执行");
            return;
        }
        [gRingVolumeLock lock];
        gSavedRingVolume = current;
        [gRingVolumeLock unlock];
        NSLog(@"[CallGuard] 铃声音量已存档 %.2f", current);
    }

    if (CGSetRingVolume(0.0f)) {
        NSLog(@"[CallGuard] 已静音");
    } else {
        NSLog(@"[CallGuard] 静音失败：写音量被拒");
        CGRestoreRingVolume();   // 没静成功，存档没有意义，清掉
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
    CGResolveDirectory();
    if (!gLogPath) return;
    if (![fm fileExistsAtPath:gLogPath]) {
        [fm createFileAtPath:gLogPath contents:nil attributes:nil];
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
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

        // 遗留检查：上一次静音后如果通知漏收，音量会卡在 0。
        // 这里在每次新来电时兜底恢复一次（此刻确实没有活跃通话才恢复）。
        if (gSavedRingVolume >= 0 && !CGHasActiveCall()) {
            CGRestoreRingVolume();
        }

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
                CGSilenceRingSafely();
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
    // Logos 对这个类只生成 @class 前向声明，直接 [self valueForKey:] 会报
    // "receiver type ... is a forward declaration"。转成 id 后任何消息都能发。
    id selfObj = (id)self;
    @try { call = [selfObj valueForKey:@"call"]; } @catch (NSException *e) {}
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

/// 自检：这两个 hook 到底挂上了几个。
///
/// class_getInstanceMethod 返回非 nil 才说明方法真实存在、%orig 链能走通。
/// 返回 nil = 类里压根没有这个方法 = Logos 静默失效（不崩、不报错、不生效）。
/// 只检查"类是否存在"是不够的 —— 方法缺失比类缺失常见得多。
static void CGProbeHooks(void) {
    int total = 0, ok = 0;

    total++;
    Class a = NSClassFromString(@"SBDashBoardIncomingCallViewController");
    if (a && class_getInstanceMethod(a, @selector(initWithCall:))) ok++;

    total++;
    Class b = NSClassFromString(@"SBIncomingCallAlertItem");
    if (b && class_getInstanceMethod(b, @selector(initWithCall:))) ok++;

    gHookedCount = ok;
    gHookedTotal = total;
    NSLog(@"[CallGuard] hook 自检：%d/%d 挂载", ok, total);
}

%ctor {
    @autoreleasepool {
        gHandledLock    = [NSLock new];
        gHandled        = [NSMutableSet new];
        gRingVolumeLock = [NSLock new];

        CGProbeHooks();
        CGLoadConfig(YES);

        size_t count = 0;
        {
            std::lock_guard<std::mutex> lock(gEngineLock);
            if (gEngine) count = gEngine->ruleCount();
        }

        // 写心跳文件：App 靠它判断 Tweak 到底装没装、加载了几条规则。
        // 只检查配置文件存在是不够的 —— 那只说明 App 导出成功，
        // 跟 Tweak 有没有被 SpringBoard 加载是两件事。
        CGWriteReadyMarker(count);

        // SpringBoard 早期 App Group 容器可能还没挂载完，CGAppGroupDir() 会返回 nil，
        // 心跳就落到固定路径 → App 读不到 → L1 假灰点。2 秒后重写一次兜底。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            size_t c = 0;
            {
                std::lock_guard<std::mutex> lock(gEngineLock);
                if (gEngine) c = gEngine->ruleCount();
            }
            CGWriteReadyMarker(c);
        });

        // 通话结束恢复铃声。
        // 必须挂通话状态，不能用界面消失 —— 界面消失 ≠ 通话结束，会误恢复。
        [[NSNotificationCenter defaultCenter]
            addObserverForName:@"TUCallCenterCallStatusChangedNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
            if (gSavedRingVolume < 0) return;
            if (!CGHasActiveCall()) CGRestoreRingVolume();
        }];

        NSLog(@"[CallGuard] Tweak 已加载，规则 %zu 条，enabled=%d，hook %d/%d",
              count, gEnabled, gHookedCount, gHookedTotal);
    }
}
