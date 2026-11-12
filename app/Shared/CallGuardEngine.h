//
//  CallGuardEngine.h
//  C++ 规则引擎的 Objective-C 封装，供 Swift 调用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CGRuleType) {
    CGRuleTypeExact  = 0,
    CGRuleTypePrefix = 1,
    CGRuleTypeRange  = 2,
    CGRuleTypeRegex  = 3,
};

typedef NS_ENUM(NSInteger, CGAction) {
    CGActionAllow   = 0,
    CGActionMark    = 1,
    CGActionSilence = 2,
    CGActionBlock   = 3,
};

@interface CGRule : NSObject
@property (nonatomic, assign) NSInteger ruleId;
@property (nonatomic, assign) CGRuleType type;
@property (nonatomic, assign) CGAction action;
@property (nonatomic, copy)   NSString *value;
@property (nonatomic, copy)   NSString *label;
@property (nonatomic, assign) BOOL enabled;
@end

@interface CGMatchResult : NSObject
@property (nonatomic, assign) BOOL matched;
@property (nonatomic, assign) CGAction action;
@property (nonatomic, assign) NSInteger ruleId;
@property (nonatomic, copy)   NSString *label;
@property (nonatomic, copy)   NSString *reason;
@end

@interface CGEngine : NSObject

// 必须显式指定 NS_SWIFT_NAME：`addRule:` 的 "Rule" 与参数类型 CGRule 的
// 名词部分相同，Swift 的 ObjC 导入规则会把它推断成 `add(_:)`，
// 导致调用端写 addRule(_:) 直接编译报错。
- (void)addRule:(CGRule *)rule NS_SWIFT_NAME(addRule(_:));
- (void)addWhitelist:(NSString *)number NS_SWIFT_NAME(addWhitelist(_:));
- (void)addWhitelistPrefix:(NSString *)prefix NS_SWIFT_NAME(addWhitelistPrefix(_:));
- (void)finalizeEngine NS_SWIFT_NAME(finalizeEngine());

- (CGMatchResult *)evaluate:(NSString *)number NS_SWIFT_NAME(evaluate(_:));

@property (nonatomic, readonly) NSInteger ruleCount;

/// 号码归一化为 E.164 无 '+' 形式
+ (NSString *)normalize:(NSString *)number NS_SWIFT_NAME(normalize(_:));

@end

NS_ASSUME_NONNULL_END
