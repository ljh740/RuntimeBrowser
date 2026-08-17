//
//  RTBTypeParser.h
//  runtime_cli
//
//  Created by Nicolas Seriot on 02/04/15.
//
//

#import <Foundation/Foundation.h>
#import "RTBProtocol.h"

#if (! TARGET_OS_IPHONE)
#import <objc/objc-runtime.h>
#else
#import <objc/runtime.h>
#import <objc/message.h>
#endif

@interface RTBRuntimeHeader : NSObject

+ (NSString *)decodedTypeForEncodedString:(NSString *)s;

// instance property
+ (NSString *)descriptionForPropertyWithName:(NSString *)name
                                  attributes:(NSString *)attributes
              displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues;

// class properties are read from the metaclass, eg. @property (class, readonly) NSUserDefaults *standardUserDefaults;
+ (NSString *)descriptionForPropertyWithName:(NSString *)name
                                  attributes:(NSString *)attributes
                             isClassProperty:(BOOL)isClassProperty
              displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues;

// the attributes string split on commas, but not on the commas found inside C++ template names in type encodings, eg. T{pair<int, int>=ii},V_pair
+ (NSArray *)componentsOfPropertyAttributes:(NSString *)attributes;

// the '?' attribute marks the properties declared in an @optional section of a protocol
+ (BOOL)isOptionalPropertyWithAttributes:(NSString *)attributes;

+ (NSString *)headerForClass:(Class)aClass displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues;

+ (NSString *)headerForProtocol:(RTBProtocol *)protocol; // reads RTBDisplayPropertiesDefaultValues in user defaults
+ (NSString *)headerForProtocol:(RTBProtocol *)protocol displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues;

+ (NSString *)descriptionForMethodName:(NSString *)methodName
                            returnType:(NSString *)returnType
                         argumentTypes:(NSArray *)argumentsTypes
                      newlineAfterArgs:(BOOL)newlineAfterArgs
                         isClassMethod:(BOOL)isClassMethod;

+ (NSString *)descriptionForProtocol:(Protocol *)protocol
                            selector:(SEL)selector
                    isRequiredMethod:(BOOL)isRequiredMethod
                    isInstanceMethod:(BOOL)isInstanceMethod;

@end
