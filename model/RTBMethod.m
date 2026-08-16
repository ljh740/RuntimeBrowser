//
//  RTBMethod.m
//  OCRuntime
//
//  Created by Nicolas Seriot on 06/05/15.
//  Copyright (c) 2015 Nicolas Seriot. All rights reserved.
//

#import "RTBMethod.h"
#import "RTBRuntimeHeader.h"
#include "dlfcn.h"

#if USE_NEW_DECODER
#import "RTBTypeDecoder2.h"
@compatibility_alias RTBTypeDecoder RTBTypeDecoder2;
#else
#import "RTBTypeDecoder.h"
#endif

@interface RTBMethod ()
@property (nonatomic) Method method;
@property (nonatomic) BOOL isClassMethod;

@property (nonatomic, strong) NSNumber *cachedHasArguments;
@property (nonatomic, strong) NSArray *cachedTypesDecoded; // return type first, then self, _cmd and the arguments
@property (nonatomic, strong) NSDictionary *cachedDyldInfoDictionary;
@end

@implementation RTBMethod

+ (instancetype)methodObjectWithMethod:(Method)method isClassMethod:(BOOL)isClassMethod {
    RTBMethod *m = [[RTBMethod alloc] init];
    m.method = method;
    m.isClassMethod = isClassMethod;
    return m;
}

- (NSString *)description {
    NSString *superDescription = [super description];
    
    return [NSString stringWithFormat:@"%@ %@", superDescription, [self selectorString]];
}

- (Method)method {
    return _method;
}

- (NSDictionary *)dyldInfo {
    
    IMP imp = method_getImplementation(_method);

    Dl_info info;
    int rc = dladdr(imp, &info);
    
    if (!rc)  {
        return nil;
    }
    
//    printf("-- function %s\n", info.dli_sname);
//    printf("-- program %s\n", info.dli_fname);
//    printf("-- fbase %p\n", info.dli_fbase);
//    printf("-- saddr %p\n", info.dli_saddr);
    
    NSString *filePath = info.dli_fname ? [NSString stringWithFormat:@"%s", info.dli_fname] : @"";
    
#if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
    NSString *symbolName = @""; // info.dli_sname is unreliable on the device, most of time "<redacted>"
#else
    NSString *symbolName = info.dli_sname ? [NSString stringWithFormat:@"%s", info.dli_sname] : @"";
#endif
    
    NSString *categoryName = nil;
    
    NSUInteger startIndex = [symbolName rangeOfString:@"("].location;
    NSUInteger stopIndex = [symbolName rangeOfString:@")"].location;
    if(startIndex != NSNotFound && stopIndex != NSNotFound && startIndex < stopIndex) {
        categoryName = [symbolName substringWithRange:NSMakeRange(startIndex+1, (stopIndex - startIndex)-1)];
    }
    
    NSMutableDictionary *md = [NSMutableDictionary dictionaryWithCapacity:2];
    if(filePath) md[@"filePath"] = filePath;
    if(symbolName) md[@"symbolName"] = symbolName;
    if(categoryName) md[@"categoryName"] = categoryName;
    return md;
}

- (NSString *)categoryName {
    if(_cachedDyldInfoDictionary == nil) {
        self.cachedDyldInfoDictionary = [self dyldInfo];
    }
    return _cachedDyldInfoDictionary[@"categoryName"];
}

- (NSString *)symbolName {
    if(_cachedDyldInfoDictionary == nil) {
        self.cachedDyldInfoDictionary = [self dyldInfo];
    }
    return _cachedDyldInfoDictionary[@"symbolName"];
}

- (NSString *)filePath {
    if(_cachedDyldInfoDictionary == nil) {
        self.cachedDyldInfoDictionary = [self dyldInfo];
    }
    return _cachedDyldInfoDictionary[@"filePath"];
}

- (BOOL)hasArguments {
    if(_cachedHasArguments == nil) {
        self.cachedHasArguments = [NSNumber numberWithBool:[[self argumentsTypesDecoded] count] > 2]; // id, SEL, ...
    }
    return [_cachedHasArguments boolValue];
}

- (NSString *)returnTypeEncoded {
    // method_getReturnType() would truncate long encodings such as C++ templates
    char *returnTypeCString = method_copyReturnType(_method);
    if(returnTypeCString == NULL) return @"";
    NSString *s = [NSString stringWithCString:returnTypeCString encoding:NSUTF8StringEncoding];
    free(returnTypeCString);
    return s ? s : @"";
}

- (NSArray *)typesDecoded {
    
    if(_cachedTypesDecoded == nil) {
        /*
         We decode the whole type encoding ourselves instead of relying on method_getNumberOfArguments(),
         method_copyReturnType() and method_copyArgumentType(). The runtime functions do not understand
         the extended type encodings that Swift and recent compilers store in method lists, and they return
         garbage for the class names and block signatures, eg. v24@0:8@?<v@?@"NSError">16
         */
        const char *typeEncoding = method_getTypeEncoding(_method);
        NSString *s = typeEncoding ? [NSString stringWithCString:typeEncoding encoding:NSUTF8StringEncoding] : nil;
        
        NSArray *types = [RTBTypeDecoder decodeTypes:(s ? s : @"") flat:YES];
        if([types count] == 0) {
            types = @[[RTBTypeDecoder decodeType:@"" flat:YES]]; // no type encoding at all
        }
        
        self.cachedTypesDecoded = types;
    }
    
    return _cachedTypesDecoded;
}

- (NSString *)returnTypeDecoded {
    return [[self typesDecoded] firstObject];
}

- (NSArray *)argumentsTypesDecoded {
    // self and _cmd come first
    NSArray *types = [self typesDecoded];
    return [types subarrayWithRange:NSMakeRange(1, [types count] - 1)];
}

- (NSString *)headerDescriptionWithNewlineAfterArgs:(BOOL)newlineAfterArgs {
    NSString *returnType = [self returnTypeDecoded];
    NSString *methodName = NSStringFromSelector(method_getName(_method));
    
    NSArray *argumentTypes = [self argumentsTypesDecoded];
    
    return [RTBRuntimeHeader descriptionForMethodName:methodName
                                           returnType:returnType
                                        argumentTypes:argumentTypes
                                     newlineAfterArgs:newlineAfterArgs
                                        isClassMethod:_isClassMethod];
}

- (NSString *)selectorString {
    return NSStringFromSelector(method_getName(_method));
}

- (SEL)selector {
    return method_getName(_method);
}

- (NSComparisonResult)compare:(RTBMethod *)otherMethod {
    
    if(self.isClassMethod && otherMethod.isClassMethod == NO) return NSOrderedAscending;
    if(self.isClassMethod == NO && otherMethod.isClassMethod) return NSOrderedDescending;
    
    return [[self selectorString] compare:[otherMethod selectorString]];
}

@end
