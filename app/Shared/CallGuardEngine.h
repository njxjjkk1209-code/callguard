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

- (void)addRule:(CGRule *)rule;
- (void)addWhitelist:(NSString *)number;
- (void)addWhitelistPrefix:(NSString *)prefix;
- (void)finalizeEngine;

- (CGMatchResult *)evaluate:(NSString *)number;

@property (nonatomic, readonly) NSInteger ruleCount;

/// 号码归一化为 E.164 无 '+' 形式
+ (NSString *)normalize:(NSString *)number;

@end

NS_ASSUME_NONNULL_END
