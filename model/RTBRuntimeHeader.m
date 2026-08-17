//
//  RTBTypeParser.m
//  runtime_cli
//
//  Created by Nicolas Seriot on 02/04/15.
//
//

#import "RTBRuntimeHeader.h"
#import "RTBMethod.h"
#import "RTBClass.h"

#import "RTBTypeDecoder.h"

OBJC_EXPORT const char *_protocol_getMethodTypeEncoding(Protocol *, SEL, BOOL isRequiredMethod, BOOL isInstanceMethod) __OSX_AVAILABLE_STARTING(__MAC_10_8, __IPHONE_6_0);

@implementation RTBRuntimeHeader

+ (NSString *)decodedTypeForEncodedString:(NSString *)s {
    return [RTBTypeDecoder decodeType:s flat:YES];
}

+ (NSArray *)componentsOfPropertyAttributes:(NSString *)attributes {
    
    // like -componentsSeparatedByString:@"," but the commas inside {} () [] belong to the type encoding,
    // eg. C++ template names in T{pair<int, int>=ii},V_pair
    
    NSMutableArray *ma = [NSMutableArray array];
    
    NSUInteger depth = 0;
    NSUInteger start = 0;
    NSUInteger length = [attributes length];
    
    for(NSUInteger i = 0; i < length; i++) {
        unichar c = [attributes characterAtIndex:i];
        if(c == '{' || c == '(' || c == '[') {
            depth++;
        } else if(c == '}' || c == ')' || c == ']') {
            if(depth > 0) depth--;
        } else if(c == ',' && depth == 0) {
            [ma addObject:[attributes substringWithRange:NSMakeRange(start, i - start)]];
            start = i + 1;
        }
    }
    
    [ma addObject:[attributes substringFromIndex:start]];
    
    return ma;
}

+ (BOOL)isOptionalPropertyWithAttributes:(NSString *)attributes {
    for(NSString *attribute in [self componentsOfPropertyAttributes:attributes]) {
        if([attribute isEqualToString:@"?"]) return YES;
    }
    return NO;
}

+ (NSString *)descriptionForPropertyWithName:(NSString *)name attributes:(NSString *)attributes displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    return [self descriptionForPropertyWithName:name attributes:attributes isClassProperty:NO displayPropertiesDefaultValues:displayPropertiesDefaultValues];
}

+ (NSString *)descriptionForPropertyWithName:(NSString *)name attributes:(NSString *)attributes isClassProperty:(BOOL)isClassProperty displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    
    // https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtPropertyIntrospection.html
    // and clang's ASTContext::getObjCEncodingForPropertyDecl()
    
    NSString *getter = nil;
    NSString *setter = nil;
    NSString *type = nil;
    NSString *atomicity = nil;
    NSString *memory = nil;
    NSString *rw = nil;
    NSMutableArray *comments = [NSMutableArray array];
    
    NSArray *attributesComponents = [self componentsOfPropertyAttributes:attributes];
    for(NSString *attribute in attributesComponents) {
        if([attribute length] == 0) continue;
        unichar c = [attribute characterAtIndex:0];
        NSString *tail = [attribute substringFromIndex:1];
        if (c == 'R') rw = @"readonly";
        else if (c == 'C') memory = @"copy";
        else if (c == '&') memory = @"retain"; // strong
        else if (c == 'W') memory = @"weak";
        else if (c == 'G') getter = tail; // custom getter
        else if (c == 'S') setter = tail; // custome setter
        else if (c == 't' || c == 'T') type = [RTBTypeDecoder decodeType:tail flat:YES]; // 't' specifies the type using old-style encoding
        else if (c == 'D') {} // The property is dynamic (@dynamic)
        else if (c == 'P') {} // The property is eligible for garbage collection
        else if (c == 'N') atomicity = @"nonatomic"; // memory - The property is non-atomic (nonatomic)
        else if (c == 'V') {} // The name of the backing instance variable, eg. V_name
        else if (c == '?') {} // The property was declared in an @optional section of a protocol
        else [comments addObject:[NSString stringWithFormat:@"/* unknown property attribute: %@ */", attribute]];
    }
    
    if(type == nil) {
        type = [RTBTypeDecoder decodeType:@"" flat:YES]; // no type encoding at all
    }
    
    if(displayPropertiesDefaultValues) {
        if(!atomicity) atomicity = @"atomic";
        if(!rw) rw = @"readwrite";
    }
    
    NSMutableString *ms = [NSMutableString stringWithString:@"@property "];
    
    NSMutableArray *attributesArray = [NSMutableArray array];
    if(isClassProperty) [attributesArray addObject:@"class"];
    if(getter)    [attributesArray addObject:[NSString stringWithFormat:@"getter=%@", getter]];
    if(setter)    [attributesArray addObject:[NSString stringWithFormat:@"setter=%@", setter]];
    if(atomicity) [attributesArray addObject:atomicity];
    if(rw)        [attributesArray addObject:rw];
    if(memory)    [attributesArray addObject:memory];
    
    if([attributesArray count] > 0) {
        NSString *attributesDescription = [NSString stringWithFormat:@"(%@)", [attributesArray componentsJoinedByString:@", "]];
        [ms appendString:attributesDescription];
        [ms appendFormat:@" "];
    }
    
    [ms appendString:type];
    
    if([type hasSuffix:@"*"] == NO) {
        [ms appendString:@" "];
    }
    
    [ms appendFormat:@"%@;", name];
    
    if([comments count] > 0)
        [ms appendFormat:@" %@", [comments componentsJoinedByString:@" "]];
    
    return ms;
}

+ (NSString *)descriptionForMethodName:(NSString *)methodName
                            returnType:(NSString *)returnType
                         argumentTypes:(NSArray *)argumentsTypes
                      newlineAfterArgs:(BOOL)newlineAfterArgs
                         isClassMethod:(BOOL)isClassMethod {

    NSString *signAndReturnTypeString = [NSString stringWithFormat:@"%c (%@)", (isClassMethod ? '+' : '-'), returnType];
    
    NSArray *methodNameParts = [methodName componentsSeparatedByString:@":"];
    if([[methodNameParts lastObject] length] == 0) {
        methodNameParts = [methodNameParts subarrayWithRange:NSMakeRange(0, [methodNameParts count]-1)];
    }
    NSAssert([methodNameParts count] > 0, @"");
    
    NSMutableArray *ma = [NSMutableArray array];
    
    __block NSMutableString *ms = [NSMutableString string];
    
    [ms appendString:signAndReturnTypeString];
    
    // the selector tells how many arguments there are, the type encoding may miss some of them,
    // eg. -[X vector:] with a simd argument is encoded as v32@0:816 because clang does not encode vector types
    BOOL hasArgs = [methodName rangeOfString:@":"].location != NSNotFound;
    
    __block NSUInteger paddingIndex = 0;

    NSUInteger numberOfArgTypes = [argumentsTypes count] > 2 ? [argumentsTypes count] - 2 : 0; // self, _cmd, ...
    
    BOOL hasBadNumberOfArgTypes = (hasArgs && ([methodNameParts count] != numberOfArgTypes));
    
    [methodNameParts enumerateObjectsUsingBlock:^(NSString *part, NSUInteger i, BOOL *stop) {
        
        [ms appendString:part];
        
        if(hasArgs) {
            NSString *argType = hasBadNumberOfArgTypes ? @"void *" : argumentsTypes[i+2];
            if([argType hasPrefix:@"<"] && [argType hasSuffix:@"> *"]) { // eg. "<MyProtocol> *" -> "id <MyProtocol>"
                argType = [NSString stringWithFormat:@"id %@", [argType substringToIndex:[argType length] - 2]];
            }
            NSString *s = [NSString stringWithFormat:@":(%@)arg%@", argType, @(i+1)];
            
            if(paddingIndex == 0) {
                paddingIndex = [ms length];
            }
            
            paddingIndex = MAX(paddingIndex, [part length]);
            
            [ms appendString:s];
            
            BOOL isLastPart = i == [methodNameParts count] - 1;
            
            if(isLastPart) {
                [ms appendString:@";"];
                if(hasBadNumberOfArgTypes) { // happens on iOS 8.3 in SceneKit.framework -[SCNCameraControlEventHandler rotateWithVector:mode:]
                    NSArray *subArgumentTypes = numberOfArgTypes > 0 ? [argumentsTypes subarrayWithRange:NSMakeRange(2, numberOfArgTypes)] : @[];
                    [ms appendFormat:@" // needs %@ arg types, found %@: %@",
                     @([methodNameParts count]),
                     @([subArgumentTypes count]),
                     [subArgumentTypes componentsJoinedByString:@", "]];
                }
            } else {
                [ms appendString:@" "];
            }
        }
        
        [ma addObject:ms];
        ms = [NSMutableString string];
    }];
    
    if([[ma lastObject] hasSuffix:@";"] == NO && hasBadNumberOfArgTypes == NO) {
        [[ma lastObject] appendString:@";"];
        if(hasArgs == NO && numberOfArgTypes > 0) { // should not happen, but let's not hide it
            NSArray *subArgumentTypes = [argumentsTypes subarrayWithRange:NSMakeRange(2, numberOfArgTypes)];
            [[ma lastObject] appendFormat:@" // needs 0 arg types, found %@: %@", @(numberOfArgTypes), [subArgumentTypes componentsJoinedByString:@", "]];
        }
    }
    
    NSString *joinerString = @"";
    
    if(newlineAfterArgs) {
        NSMutableArray *ma2 = [NSMutableArray array];
        
        [ma enumerateObjectsUsingBlock:^(NSString *s, NSUInteger idx, BOOL *stop) {
            NSString *part = methodNameParts[idx];
            if(idx == 0) {
                part = [part stringByAppendingString:signAndReturnTypeString];
            }
            NSMutableString *_ms = [NSMutableString string];
            NSInteger padSize = paddingIndex - [part length];
            if(padSize < 0) padSize = 0;
            for(int i = 0; i < padSize; i++) [_ms appendString:@" "];
            NSString *s2 = [_ms stringByAppendingString:s];
            
            [ma2 addObject:s2];
            
        }];
        
        ma = ma2;
        
        joinerString = @"\n";
    }
    
    NSString *s = [ma componentsJoinedByString:joinerString];
    
    if(hasBadNumberOfArgTypes) {
        NSLog(@"-- %@", s);
    }
    
    return s;
}

+ (NSString *)descriptionForProtocol:(Protocol *)protocol selector:(SEL)selector isRequiredMethod:(BOOL)isRequiredMethod isInstanceMethod:(BOOL)isInstanceMethod {
    
    // the extended type encoding has class names and block signatures, eg. v24@0:8@"NSString"16@?<v@?@"NSError">24
    const char *descriptionString = _protocol_getMethodTypeEncoding(protocol, selector, isRequiredMethod, isInstanceMethod);
    
    if(descriptionString == NULL) {
        // no extended type encoding, eg. protocols built at runtime, fall back to the plain encoding
        struct objc_method_description methodDescription = protocol_getMethodDescription(protocol, selector, isRequiredMethod, isInstanceMethod);
        descriptionString = methodDescription.types;
    }
    
    NSArray *types = nil;
    if(descriptionString != NULL) {
        NSString *typesEncodedString = [NSString stringWithCString:descriptionString encoding:NSUTF8StringEncoding];
        types = [RTBTypeDecoder decodeTypes:typesEncodedString flat:YES];
    }
    
    NSString *returnType = [types count] > 0 ? [types objectAtIndex:0] : [RTBTypeDecoder decodeType:@"" flat:YES];
    NSArray *argumentTypes = [types count] > 1 ? [types subarrayWithRange:NSMakeRange(1, [types count]-1)] : @[];
    NSString *methodName = NSStringFromSelector(selector);
    
    return [self descriptionForMethodName:methodName
                               returnType:returnType
                            argumentTypes:argumentTypes
                         newlineAfterArgs:NO
                            isClassMethod:(isInstanceMethod == NO)];
}

// one line per dictionary, then a blank line
+ (void)appendDescriptionsOfDictionaries:(NSArray *)dictionaries toHeader:(NSMutableString *)header {
    for(NSDictionary *d in dictionaries) {
        [header appendFormat:@"%@\n", d[@"description"]];
    }
    if([dictionaries count] > 0) {
        [header appendString:@"\n"];
    }
}

+ (NSString *)headerForClass:(Class)aClass displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    if(aClass == nil) return nil;
    
    NSMutableString *header = [NSMutableString string];
    
    RTBClass *class = [RTBClass classStubWithClass:aClass];
    
    // top header
    const char *imageName = class_getImageName(aClass);
    [header appendFormat:@"/* Generated by RuntimeBrowser\n   Image: %s\n", imageName ? imageName : "(null)"];
    if([class isSwiftClass]) {
        // Swift classes show up in the Objective-C runtime with mangled names, eg. _TtC10Foundation13__NSSwiftData
        NSString *demangledName = [class swiftDemangledName];
        [header appendFormat:@"   Swift class: %@\n", demangledName ? demangledName : [class classObjectName]];
    }
    [header appendString:@" */\n\n"];
    
    // @interface NSString : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>
    
    // interface declaration
    [header appendFormat:@"@interface %s ", class_getName(aClass)];
    
    // inheritance
    Class superClass = class_getSuperclass(aClass);
    if (superClass)
        [header appendFormat: @": %s", class_getName(superClass)];
    
    // protocols
    NSArray *protocols = [class sortedProtocolsNames];
    if([protocols count] > 0) {
        
        if(superClass) {
            [header appendString:@" "];
        }
        
        NSString *protocolsString = [protocols componentsJoinedByString:@", "];
        [header appendFormat:@"<%@>", protocolsString];
    }
    
    // ivars
    NSArray *sortedIvarDictionaries = [class sortedIvarDictionaries];
    if([sortedIvarDictionaries count] > 0){
        [header appendString:@" {\n"];
        for(NSDictionary *d in sortedIvarDictionaries) {
            [header appendFormat:@"%@\n", d[@"description"]];
        }
        [header appendString:@"}\n\n"];
    } else {
        [header appendString:@"\n\n"];
    }

    // class properties first, eg. @property (class, readonly) NSUserDefaults *standardUserDefaults;
    [self appendDescriptionsOfDictionaries:[class sortedClassPropertiesDictionariesWithDisplayPropertiesDefaultValues:displayPropertiesDefaultValues] toHeader:header];
    [self appendDescriptionsOfDictionaries:[class sortedPropertiesDictionariesWithDisplayPropertiesDefaultValues:displayPropertiesDefaultValues] toHeader:header];
    
    // class and instance methods
    NSArray *sortedMethods = [class sortedMethodsGroupsOfGroupsByImageAndThenCategory];
    
    NSArray *imagePaths = [sortedMethods valueForKey:@"filePath"];
    NSSet *imagePathsSet = [NSSet setWithArray:imagePaths];
    BOOL hasMethodsFromMoreThanOneImage = [imagePathsSet count] > 1;
    
    __block BOOL hasOneOrMoreMethods = NO;
    
    __block BOOL hasMetMethodsInACategory = NO; // NSStream.h no methods in CoreFoundation, everything in Foundation
    
    [sortedMethods enumerateObjectsUsingBlock:^(NSDictionary *d, NSUInteger idx, BOOL *stop) {
        
        NSString *filePath = d[@"filePath"];
        
        if([d[@"methodsByCategories"] count] == 0) return;
        
        if(hasMetMethodsInACategory) [header appendString:@"\n"];
        hasMetMethodsInACategory = YES;

        hasOneOrMoreMethods = YES;

        if(hasMethodsFromMoreThanOneImage) {
            [header appendFormat:@"// Image: %@\n\n", filePath];
        }
        
        NSArray *allMethodsByCategories = d[@"methodsByCategories"];
        
        [allMethodsByCategories enumerateObjectsUsingBlock:^(NSDictionary *methodsByCategories, NSUInteger idx, BOOL *stop) {
            
            NSArray *methods = methodsByCategories[@"methods"];
            
            if(idx > 0) {
                [header appendString:@"\n"];
            }
            
            NSString *categoryName = methodsByCategories[@"categoryName"];
            
            if([categoryName length] > 0) [header appendFormat:@"// %@ (%@)\n\n", NSStringFromClass(aClass), categoryName];

            __block unichar previousSign = '\0';
            
            [methods enumerateObjectsUsingBlock:^(RTBMethod *m, NSUInteger idx, BOOL * _Nonnull stop) {
                NSString *headerDescription = [m headerDescriptionWithNewlineAfterArgs:NO];
                
                if([headerDescription length] == 0) {
                    [header appendFormat:@"/* MISSING HEADER DESCRIPTION FOR METHOD %@ */\n", NSStringFromSelector(m.selector)];
                    return;
                }
                
                assert([headerDescription length] > 0);
                unichar currentSign = [headerDescription characterAtIndex:0];
                if(previousSign != '\0' && currentSign != previousSign) {
                    [header appendString:@"\n"];
                }
                previousSign = currentSign;
                [header appendFormat:@"%@\n", headerDescription];
            }];
        }];
        
    }];
    
    if(hasOneOrMoreMethods) {
        [header appendString:@"\n"];
    }
    
    // Swift members, only the @objc ones are visible in the Objective-C runtime
    NSArray *swiftMembers = [class sortedSwiftMembers];
    if([swiftMembers count] > 0) {
        [header appendString:@"// Swift members, from the symbol table (stripped members are missing)\n\n"];
        for(NSString *member in swiftMembers) {
            [header appendFormat:@"%@\n", member];
        }
        [header appendString:@"\n"];
    }
    
    [header appendString:@"@end\n"];
    
    return header;
}

+ (NSString *)headerForProtocol:(RTBProtocol *)protocol {
    BOOL displayPropertiesDefaultValues = [[NSUserDefaults standardUserDefaults] boolForKey:@"RTBDisplayPropertiesDefaultValues"];
    return [self headerForProtocol:protocol displayPropertiesDefaultValues:displayPropertiesDefaultValues];
}

+ (NSString *)headerForProtocol:(RTBProtocol *)protocol displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    
    NSMutableString *header = [NSMutableString string];
    
    [header appendString:@"/* Generated by RuntimeBrowser.\n */\n\n"];
    
    [header appendFormat:@"@protocol %@", [protocol protocolName]];
    
    // adopted protocols
    NSArray *adoptedProtocols = [protocol sortedAdoptedProtocolsNames];
    if([adoptedProtocols count]) {
        NSString *adoptedProtocolsString = [adoptedProtocols componentsJoinedByString:@", "];
        [header appendFormat:@" <%@>", adoptedProtocolsString];
    }
    [header appendString:@"\n\n"];
    
    NSArray *requiredClassProperties = [protocol sortedPropertiesRequired:YES instanceProperties:NO displayPropertiesDefaultValues:displayPropertiesDefaultValues];
    NSArray *requiredInstanceProperties = [protocol sortedPropertiesRequired:YES instanceProperties:YES displayPropertiesDefaultValues:displayPropertiesDefaultValues];
    NSArray *optionalClassProperties = [protocol sortedPropertiesRequired:NO instanceProperties:NO displayPropertiesDefaultValues:displayPropertiesDefaultValues];
    NSArray *optionalInstanceProperties = [protocol sortedPropertiesRequired:NO instanceProperties:YES displayPropertiesDefaultValues:displayPropertiesDefaultValues];
    
    NSArray *requiredClassMethods = [protocol sortedMethodsRequired:YES instanceMethods:NO];
    NSArray *requiredInstanceMethods = [protocol sortedMethodsRequired:YES instanceMethods:YES];
    NSArray *optionalClassMethods = [protocol sortedMethodsRequired:NO instanceMethods:NO];
    NSArray *optionalInstanceMethods = [protocol sortedMethodsRequired:NO instanceMethods:YES];
    
    if([requiredClassProperties count] + [requiredInstanceProperties count] + [requiredClassMethods count] + [requiredInstanceMethods count] > 0) {
        [header appendString:@"@required\n\n"];
    }
    
    [self appendDescriptionsOfDictionaries:requiredClassProperties toHeader:header];
    [self appendDescriptionsOfDictionaries:requiredInstanceProperties toHeader:header];
    [self appendDescriptionsOfDictionaries:requiredClassMethods toHeader:header];
    [self appendDescriptionsOfDictionaries:requiredInstanceMethods toHeader:header];
    
    if([optionalClassProperties count] + [optionalInstanceProperties count] + [optionalClassMethods count] + [optionalInstanceMethods count] > 0) {
        [header appendString:@"@optional\n\n"];
    }
    
    [self appendDescriptionsOfDictionaries:optionalClassProperties toHeader:header];
    [self appendDescriptionsOfDictionaries:optionalInstanceProperties toHeader:header];
    [self appendDescriptionsOfDictionaries:optionalClassMethods toHeader:header];
    [self appendDescriptionsOfDictionaries:optionalInstanceMethods toHeader:header];
    
    [header appendString:@"@end\n"];
    
    return header;
}

@end
