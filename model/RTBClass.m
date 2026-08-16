/*
 
 ClassStub.m created by eepstein on Sat 16-Mar-2002
 
 Author: Ezra Epstein (eepstein@prajna.com)
 
 Copyright (c) 2002 by Prajna IT Consulting.
 http://www.prajna.com
 
 ========================================================================
 
 THIS PROGRAM AND THIS CODE COME WITH ABSOLUTELY NO WARRANTY.
 THIS CODE HAS BEEN PROVIDED "AS IS" AND THE RESPONSIBILITY
 FOR ITS OPERATIONS IS 100% YOURS.
 
 ========================================================================
 This file is part of RuntimeBrowser.
 
 RuntimeBrowser is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 RuntimeBrowser is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with RuntimeBrowser (in a file called "COPYING.txt"); if not,
 write to the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
 Boston, MA  02111-1307  USA
 
 */

#import "RTBClass.h"
#import "RTBRuntimeHeader.h"
#import "RTBMethod.h"
#import "dlfcn.h"

#if USE_NEW_DECODER
#import "RTBTypeDecoder2.h"
@compatibility_alias RTBTypeDecoder RTBTypeDecoder2;
#else
#import "RTBTypeDecoder.h"
#endif

#if (! TARGET_OS_IPHONE)
#import <objc/objc-runtime.h>
#else
#import <objc/runtime.h>
#import <objc/message.h>
#endif

@interface RTBClass()
@property (nonatomic, retain) NSString *classObjectName;
@property (nonatomic, retain) NSMutableArray *subclassesStubs;
@property (nonatomic, retain) NSString *imagePath;
@property (nonatomic) BOOL shouldSortSubclasses;
@property (nonatomic) BOOL subclassesAreSorted;
@property (nonatomic, retain) NSSet *cachedMethodsNamePartsLowercase;
@property (nonatomic, retain) NSString *cachedSwiftDemangledName;
@property (nonatomic, retain) NSDictionary *cachedSwiftFieldsByName;
@property (nonatomic, retain) NSArray *cachedSortedSwiftMembers;
- (RTBClass *)initWithClass:(Class)klass;
@end

@implementation RTBClass

@synthesize classObjectName;
@synthesize imagePath;
@synthesize subclassesStubs;

+ (RTBClass *)classStubWithClass:(Class)klass {
    return [[RTBClass alloc] initWithClass:klass];
}

+ (void)thisClassIsPartOfTheRuntimeBrowser {
    /*" So the user knows when browsing this class in the RuntimeBrowser.
     We put this method last so it shows up first. "*/
}

- (BOOL)writeAtPath:(NSString *)path {
    
    NSURL *pathURL = [NSURL fileURLWithPath:path];
    
    Class klass = NSClassFromString(classObjectName);
    BOOL displayPropertiesDefaultValues = [[NSUserDefaults standardUserDefaults] boolForKey:@"RTBDisplayPropertiesDefaultValues"];
    NSString *header = [RTBRuntimeHeader headerForClass:klass displayPropertiesDefaultValues:displayPropertiesDefaultValues];
    
    NSError *error = nil;
    BOOL success = [header writeToURL:pathURL atomically:NO encoding:NSUTF8StringEncoding error:&error];
    if(success == NO) {
        NSLog(@"-- %@", error);
    }
    
    return success;
}

- (NSMutableSet *)iVarNames {
    Class klass = NSClassFromString(classObjectName);
    
    NSMutableSet *ms = [NSMutableSet set];
    
    unsigned int ivarListCount;
    Ivar *ivarList = class_copyIvarList(klass, &ivarListCount);
    
    if (ivarList != NULL && (ivarListCount>0)) {
        NSUInteger i;
        for (i = 0; i < ivarListCount; ++i ) {
            Ivar rtIvar = ivarList[i];
            const char* ivarName = ivar_getName(rtIvar);
            if(ivarName) [ms addObject:[[NSString stringWithCString:ivarName encoding:NSUTF8StringEncoding] lowercaseString]];
        }
    }
    
    free(ivarList);
    
    return ms;
}

+ (NSSet *)methodsNamePartsLowercaseForClass:(Class)klass {
    NSMutableSet *ms = [NSMutableSet set];
    
    unsigned int methodListCount;
    Method *methodList = class_copyMethodList(klass, &methodListCount);
    
    NSUInteger i;
    for (i = 0; i < methodListCount; i++) {
        Method currMethod = (methodList[i]);
        NSString *mName = [NSString stringWithCString:sel_getName(method_getName(currMethod)) encoding:NSASCIIStringEncoding];
        NSString *mNameLowercase = [mName lowercaseString];
        NSArray *mNameLowercaseParts = [mNameLowercase componentsSeparatedByString:@":"];
        [ms addObjectsFromArray:mNameLowercaseParts];
    }
    
    free(methodList);
    
    return ms;
}

- (NSSet *)methodsNamePartsLowercase {
    
    if(_cachedMethodsNamePartsLowercase == nil) {
        
        Class class = NSClassFromString(classObjectName);
        Class metaClass = objc_getMetaClass(class_getName(class));
        
        NSMutableSet *ms = [NSMutableSet set];
        
        [ms addObjectsFromArray:[[[self class] methodsNamePartsLowercaseForClass:class] allObjects]];
        [ms addObjectsFromArray:[[[self class] methodsNamePartsLowercaseForClass:metaClass] allObjects]];
        
        [ms removeObject:@""];
        
        self.cachedMethodsNamePartsLowercase = ms;
    }
    
    return _cachedMethodsNamePartsLowercase;
}

- (NSMutableSet *)protocolsNames {
    
    Class class = NSClassFromString(classObjectName);
    if(class == nil) {
        NSLog(@"-- no class named %@", classObjectName);
        return nil;
    }
    
    NSMutableSet *ms = [NSMutableSet set];
    
    unsigned int protocolListCount = 0;
    __unsafe_unretained Protocol **protocolList = class_copyProtocolList(class, &protocolListCount);
    if (protocolList != NULL && (protocolListCount > 0)) {
        NSUInteger i;
        for(i = 0; i < protocolListCount; i++) {
            Protocol *p = protocolList[i];
            const char* protocolName = protocol_getName(p);
            if(protocolName) [ms addObject:[NSString stringWithCString:protocolName encoding:NSUTF8StringEncoding]];
        }
    }
    free(protocolList);
    
    return ms;
}

- (NSArray *)sortedProtocolsNames {
    NSArray *a = [[self protocolsNames] allObjects];
    
    return [a sortedArrayUsingSelector:@selector(compare:)];
}

- (NSSet *)iVarDecodedTypes {
    
    Class class = NSClassFromString(classObjectName);
    if(class == nil) {
        NSLog(@"-- no class named %@", classObjectName);
        return nil;
    }
    
    NSMutableSet *encodedTypesSet = [NSMutableSet set]; // use this to avoid decoding types that were already decoded
    NSMutableSet *decodedTypesSet = [NSMutableSet set];
    
    for(NSDictionary *swiftField in [[self swiftFieldsByName] allValues]) {
        [decodedTypesSet addObject:swiftField[@"type"]];
    }
    
    unsigned int ivarListCount;
    Ivar *ivarList = class_copyIvarList(class, &ivarListCount);
    
    for (unsigned int i = 0; i < ivarListCount; ++i ) {
        Ivar ivar = ivarList[i];
        
        const char *encodedTypeC = ivar_getTypeEncoding(ivar);
        if(encodedTypeC == NULL || encodedTypeC[0] == '\0') continue; // Swift-only types are not encoded
        
        NSString *encodedType = [NSString stringWithCString:encodedTypeC encoding:NSUTF8StringEncoding];
        if(encodedType == nil) continue;
        
        if([encodedTypesSet containsObject:encodedType]) continue;
        
        NSString *decodedType = [RTBTypeDecoder decodeType:encodedType flat:NO];
        [decodedTypesSet addObject:decodedType];
        
        [encodedTypesSet addObject:encodedType];
    }
    free(ivarList);
    
    return decodedTypesSet;
}

- (NSMutableSet *)protocolsNamesLowercase {
    NSSet *tokens = [self protocolsNames];
    NSMutableSet *lowercaseTokens = [NSMutableSet set];
    for(NSString *token in tokens) {
        [lowercaseTokens addObject:[token lowercaseString]];
    }
    return lowercaseTokens;
}

- (NSMutableSet *)protocolsNamesWithSuperclassesProtocols:(BOOL)includeSuperclassesProtocols {
    
    Class class = NSClassFromString(classObjectName);
    NSAssert(class, @"no class named %@", classObjectName);
    
    NSMutableSet *ms = [self protocolsNames];
    
    if (includeSuperclassesProtocols) {
        Class c;
        for(c = class; class_getSuperclass(c) != c; c = class_getSuperclass(c)) {
            RTBClass *superCS = [RTBClass classStubWithClass:c];
            NSMutableSet *ms2 = [superCS protocolsNames];
            [ms unionSet:ms2];
        }
    }
    
    return ms;
}

- (RTBClass *)initWithClass:(Class)klass {
    self = [super init];
    
    NSString *className = NSStringFromClass(klass);
    
    [self setClassObjectName:className];
    
    const char* imageNameC = class_getImageName(klass);
    
    NSString *image = nil;
    if(imageNameC) {
        image = [NSString stringWithCString:imageNameC encoding:NSUTF8StringEncoding];
    } else {
        NSLog(@"-- [ERROR] cannot find image for class %@", className);
        //image = [[NSBundle bundleForClass:klass] bundlePath];
    }
    
    self.imagePath = image;
    
    self.subclassesStubs = [NSMutableArray array];
    _subclassesAreSorted = NO;
    _shouldSortSubclasses = YES;
    return self;
}

- (NSArray *)subclassesStubs {
    if (_subclassesAreSorted == NO && _shouldSortSubclasses) {
        [subclassesStubs sortUsingSelector:@selector(compare:)];
        _subclassesAreSorted = YES;
    }
    return (NSArray *)subclassesStubs;
}

- (void)addSubclassStub:(RTBClass *)classStub {
    [subclassesStubs addObject:classStub];
    _subclassesAreSorted = NO;
}

- (NSString *)description {
    return classObjectName;
}

- (NSComparisonResult)compare:(RTBClass *)otherCS {
    return [[self displayName] compare:[otherCS displayName]];
}

- (BOOL)containsSearchString:(NSString *)searchString {
    
    NSString *ss = [searchString lowercaseString];
    
    if([[classObjectName lowercaseString] rangeOfString:ss].location != NSNotFound) {
        return YES;
    }
    
    if([[[self swiftDemangledName] lowercaseString] rangeOfString:ss].location != NSNotFound) {
        return YES;
    }
    
    for(NSString *s in [self iVarNames]) {
        if([[s lowercaseString] rangeOfString:ss].location != NSNotFound) {
            return YES;
        }
    }
    
    for(NSString *s in [self methodsNamePartsLowercase]) {
        if([s rangeOfString:ss].location != NSNotFound) {
            return YES;
        }
    }
    
    for(NSString *s in [self protocolsNamesLowercase]) {
        if([s rangeOfString:ss].location != NSNotFound) {
            return YES;
        }
    }
    
    for(NSString *s in [self iVarDecodedTypes]) {
        if([[s lowercaseString] rangeOfString:ss].location != NSNotFound) {
            return YES;
        }
    }
    
    return NO;
}

- (NSArray *)sortedIvarDictionaries {
    
    Class class = NSClassFromString(classObjectName);
    NSAssert(class, @"no class named %@", classObjectName);
    
    unsigned int ivarListCount;
    Ivar *ivarList = class_copyIvarList(class, &ivarListCount);
    
    NSMutableArray *ivarDictionaries = [NSMutableArray array];
    
    for (unsigned int i = 0; i < ivarListCount; ++i ) {
        Ivar ivar = ivarList[i];
        
        // Swift-only types are not encoded, the type encoding is NULL
        const char *encodedTypeC = ivar_getTypeEncoding(ivar);
        NSString *encodedType = encodedTypeC ? [NSString stringWithCString:encodedTypeC encoding:NSUTF8StringEncoding] : nil;
        
        // the compiler may generate ivar entries with NULL ivar_name (e.g. for anonymous bit fields).
        const char *nameC = ivar_getName(ivar);
        NSString *name = nameC ? [NSString stringWithCString:nameC encoding:NSUTF8StringEncoding] : nil;
        
        // full declaration, including the modifiers, eg. int _foo[10], int (*_callback)(), unsigned int _flags : 3
        NSString *declaration = [RTBTypeDecoder ivarDeclarationForEncodedType:encodedType name:name];
        NSString *comment = @"";
        
        // Swift-only types are not encoded (NULL or empty encoding) but the Swift runtime knows them, eg. Swift.Optional<Swift.String>
        NSDictionary *swiftField = ([encodedType length] == 0 && name) ? [self swiftFieldsByName][name] : nil;
        if(swiftField) {
            declaration = [NSString stringWithFormat:@"%@ %@", swiftField[@"type"], name];
            NSMutableArray *comments = [NSMutableArray array];
            if([swiftField[@"isVar"] boolValue] == NO) [comments addObject:@"let"];
            if([swiftField[@"isStrong"] boolValue] == NO) [comments addObject:@"weak or unowned"];
            if([comments count] > 0) comment = [NSString stringWithFormat:@" // %@", [comments componentsJoinedByString:@", "]];
        }
        
        NSString *s = [NSString stringWithFormat:@"    %@;%@", declaration, comment];
        
        [ivarDictionaries addObject:@{@"name":(name ? name : @""), @"description":s}];
        
    }
    free(ivarList);
    
    [ivarDictionaries sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        return [obj1[@"name"] compare:obj2[@"name"]];
    }];
    
    return ivarDictionaries;
}

- (NSDictionary *)dyldInfo {
    
    Class aClass = NSClassFromString(classObjectName);
    
    Dl_info info;
    int rc = dladdr((__bridge const void *)aClass, &info);
    
    if (!rc)  {
        return nil;
    }
    
    //    printf("-- function %s\n", info.dli_sname);
    //    printf("-- program %s\n", info.dli_fname);
    //    printf("-- fbase %p\n", info.dli_fbase);
    //    printf("-- saddr %p\n", info.dli_saddr);
    
    NSString *filePath = info.dli_fname ? [NSString stringWithFormat:@"%s", info.dli_fname] : nil;
    NSString *symbolName = info.dli_sname ? [NSString stringWithFormat:@"%s", info.dli_sname] : nil;
    
    NSUInteger startIndex = [symbolName rangeOfString:@"("].location;
    NSUInteger stopIndex = [symbolName rangeOfString:@")"].location;
    
    NSString *categoryName = nil;
    
    if(startIndex != NSNotFound && stopIndex != NSNotFound && startIndex < stopIndex) {
        categoryName = [symbolName substringWithRange:NSMakeRange(startIndex+1, (stopIndex - startIndex)-1)];
    }
    
    NSMutableDictionary *md = [NSMutableDictionary dictionaryWithCapacity:2];
    if(filePath) md[@"filePath"] = filePath;
    if(symbolName) md[@"symbolName"] = symbolName;
    if(categoryName) md[@"categoryName"] = categoryName;
    return md;
}

- (NSArray *)sortedMethodsIsClassMethod:(BOOL)isClassMethod {
    
    Class aClass = NSClassFromString(classObjectName);
    NSAssert(aClass, @"no class named %@", classObjectName);
    
    Class class = aClass;
    
    if(isClassMethod) {
        class = objc_getMetaClass(class_getName(aClass));
    }
    
    NSMutableArray *ma = [NSMutableArray array];
    
    unsigned int methodListCount = 0;
    Method *methodList = class_copyMethodList(class, &methodListCount);
    
    for (NSUInteger i = 0; i < methodListCount; i++) {
        Method method = methodList[i];
        
        RTBMethod *m = [RTBMethod methodObjectWithMethod:method isClassMethod:isClassMethod];
        
        [ma addObject:m];
    }
    
    free(methodList);
    
    [ma sortUsingSelector:@selector(compare:)];
    
    return ma;
}

- (NSArray *)sortedMethodsGroupsOfGroupsByImageAndThenCategory {
    
    Class aClass = NSClassFromString(classObjectName);
    NSAssert(aClass, @"no class named %@", classObjectName);
    
    NSDictionary *d = [self dyldInfo];
    
    NSString *classFilePath = d[@"filePath"];
    
    NSMutableDictionary *groupsByImage = [NSMutableDictionary dictionary];

    const char *runtimeBrowserPathC = class_getImageName([self class]);
    NSString *runtimeBrowserPath = runtimeBrowserPathC ? [NSString stringWithCString:runtimeBrowserPathC encoding:NSUTF8StringEncoding] : nil;

    for(NSNumber *n in @[@(1), @(0)]) { // for class and metaClass
        
        BOOL isClassMethod = [n boolValue];
        
        Class inspectedClass = aClass;
        
        if(isClassMethod) {
            inspectedClass = objc_getMetaClass(class_getName(aClass));
            assert(inspectedClass);
            assert(class_isMetaClass(inspectedClass));
            if(inspectedClass == nil) continue;
        }
        
        unsigned int methodListCount = 0;
        Method *methodList = class_copyMethodList(inspectedClass, &methodListCount);
        
        for (NSUInteger i = 0; i < methodListCount; i++) {
            Method method = methodList[i];
            
            RTBMethod *m = [RTBMethod methodObjectWithMethod:method isClassMethod:isClassMethod];
            
            NSString *filePath = [m filePath];
            NSString *categoryName = [m categoryName];
            
            // optionally ignore categories defindes in RuntimeBrowser
            if([[NSUserDefaults standardUserDefaults] boolForKey:@"RTBShowOCRuntimeClasses"] == NO) {
                if([filePath isEqualToString:runtimeBrowserPath]) continue;
            };
            
            if(filePath == nil) filePath = @""; // dladdr() may fail, eg. for some Swift classes
            if(categoryName == nil) categoryName = @"";
            
            if(groupsByImage[filePath] == nil) {
                groupsByImage[filePath] = [NSMutableDictionary dictionary];
            }
            
            if(groupsByImage[filePath][categoryName] == nil) {
                groupsByImage[filePath][categoryName] = [NSMutableArray array];
            }
            
            [groupsByImage[filePath][categoryName] addObject:m];
        }
        
        free(methodList);
    }
    
    NSMutableArray *groupsOfGroupsByImageAndThenCategory = [NSMutableArray array];
    
    NSMutableArray *sortedImages = [[[groupsByImage allKeys] sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    
    // start with methods from the same image as the class
    // (the class image is listed even without methods, so that the header can tell when methods come from other images)
    if(classFilePath) {
        [sortedImages removeObject:classFilePath];
        [sortedImages insertObject:classFilePath atIndex:0];
    }
    
    for(NSString *filePath in sortedImages) {
        NSDictionary *groupsByImageForCurrentFilePath = groupsByImage[filePath];
        NSArray *groupsByImageSortedKeys = [[groupsByImageForCurrentFilePath allKeys] sortedArrayUsingSelector:@selector(compare:)];
        
        NSMutableArray *methodsByCategory = [NSMutableArray array];
        
        for(NSString *categoryName in groupsByImageSortedKeys) {
            NSArray *methodsInCategory = groupsByImageForCurrentFilePath[categoryName];
            NSArray *sortedMethodsInCategory = [methodsInCategory sortedArrayUsingSelector:@selector(compare:)];
            
            [methodsByCategory addObject:@{@"categoryName":categoryName, @"methods":sortedMethodsInCategory}];
        }
        
        [groupsOfGroupsByImageAndThenCategory addObject:@{@"filePath":filePath, @"methodsByCategories":methodsByCategory}];
    }
    
    return groupsOfGroupsByImageAndThenCategory;
}

- (NSArray *)sortedPropertiesDictionariesForClass:(Class)inspectedClass isClassProperties:(BOOL)isClassProperties displayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    
    NSMutableSet *ms = [NSMutableSet set];
    
    unsigned int propertiesCount = 0;
    objc_property_t *propertyList = class_copyPropertyList(inspectedClass, &propertiesCount);
    
    for (unsigned int i = 0; i < propertiesCount; i++) {
        objc_property_t property = propertyList[i];
        
        const char *nameC = property_getName(property);
        const char *attributesC = property_getAttributes(property);
        
        NSString *name = nameC ? [NSString stringWithCString:nameC encoding:NSUTF8StringEncoding] : @"";
        NSString *attributes = attributesC ? [NSString stringWithCString:attributesC encoding:NSUTF8StringEncoding] : @"";
        
        NSString *description = [RTBRuntimeHeader descriptionForPropertyWithName:name
                                                                      attributes:attributes
                                                                 isClassProperty:isClassProperties
                                                  displayPropertiesDefaultValues:displayPropertiesDefaultValues];
        
        NSDictionary *d = @{@"name":name, @"description":description};
        
        [ms addObject:d];
    }
    
    free(propertyList);
    
    NSMutableArray *ma = [[ms allObjects] mutableCopy];
    
    [ma sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        return [obj1[@"name"] compare:obj2[@"name"]];
    }];
    
    return ma;
}

- (NSArray *)sortedPropertiesDictionariesWithDisplayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    
    Class aClass = NSClassFromString(classObjectName);
    NSAssert(aClass, @"no class named %@", classObjectName);
    
    return [self sortedPropertiesDictionariesForClass:aClass isClassProperties:NO displayPropertiesDefaultValues:displayPropertiesDefaultValues];
}

- (NSArray *)sortedClassPropertiesDictionariesWithDisplayPropertiesDefaultValues:(BOOL)displayPropertiesDefaultValues {
    
    Class aClass = NSClassFromString(classObjectName);
    NSAssert(aClass, @"no class named %@", classObjectName);
    
    // class properties are stored in the metaclass
    Class metaClass = object_getClass(aClass);
    if(metaClass == nil) return @[];
    
    return [self sortedPropertiesDictionariesForClass:metaClass isClassProperties:YES displayPropertiesDefaultValues:displayPropertiesDefaultValues];
}

#pragma mark Swift

/*
 Swift classes are visible in the Objective-C runtime, but only their @objc members are.
 The Swift runtime (libswiftCore.dylib) can tell us more. We don't link against it, we resolve
 the entry points we need with dlsym(). They are SWIFT_CC(swift) functions, which for these
 signatures (pointers, integers, a two-words struct returned in registers) is compatible with
 the C calling convention on arm64 and x86_64.
 */

typedef struct {
    const char *data;
    uintptr_t length;
} RTBSwiftTypeNamePair;

// Swift 5.5 and later fill in this struct, older runtimes take separate outName and outFreeFunc parameters,
// passing &out and &out.freeFunc is compatible with both.
typedef struct {
    const char *name;
    void (*freeFunc)(const char *);
    bool isStrong;
    bool isVar;
    uint8_t padding[6];
} RTBSwiftFieldReflectionMetadata;

static char *(*rtb_swift_demangle)(const char *mangledName, size_t mangledNameLength, char *outputBuffer, size_t *outputBufferSize, uint32_t flags);
static RTBSwiftTypeNamePair (*rtb_swift_getTypeName)(const void *type, bool qualified);
static intptr_t (*rtb_swift_reflectionMirror_recursiveCount)(const void *type);
static const void *(*rtb_swift_reflectionMirror_recursiveChildMetadata)(const void *type, intptr_t index, RTBSwiftFieldReflectionMetadata *outMetadata, void (**outFreeFunc)(const char *));

static void rtb_loadSwiftRuntime(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = RTLD_DEFAULT;
        if(dlsym(handle, "swift_demangle") == NULL) {
            handle = dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_LAZY); // macOS 10.14.4+, iOS 12.2+
            if(handle == NULL) return;
        }
        rtb_swift_demangle = dlsym(handle, "swift_demangle");
        rtb_swift_getTypeName = dlsym(handle, "swift_getTypeName");
        rtb_swift_reflectionMirror_recursiveCount = dlsym(handle, "swift_reflectionMirror_recursiveCount"); // Swift 5.2+
        rtb_swift_reflectionMirror_recursiveChildMetadata = dlsym(handle, "swift_reflectionMirror_recursiveChildMetadata");
    });
}

static BOOL rtb_classHasSwiftMetadata(Class klass) {
    // The Objective-C class object of a Swift class is the beginning of its Swift metadata.
    // Bit 1 of objc_class.bits, the fifth word after isa, superclass and the two words of the cache,
    // tells the class was compiled with the stable Swift ABI (Swift 5), bit 0 with the pre-stable ABI.
#if __LP64__
    if(klass == Nil) return NO;
    uintptr_t bits = ((uintptr_t *)(__bridge void *)klass)[4];
    return (bits & 0x2) != 0;
#else
    return NO;
#endif
}

static BOOL rtb_classIsSwiftLegacy(Class klass) {
    if(klass == Nil) return NO;
    uintptr_t bits = ((uintptr_t *)(__bridge void *)klass)[4];
    return (bits & 0x1) != 0;
}

static NSString *rtb_swiftTypeName(const void *metadata) {
    if(metadata == NULL || rtb_swift_getTypeName == NULL) return nil;
    RTBSwiftTypeNamePair pair = rtb_swift_getTypeName(metadata, true);
    if(pair.data == NULL) return nil;
    return [[NSString alloc] initWithBytes:pair.data length:pair.length encoding:NSUTF8StringEncoding];
}

- (BOOL)isSwiftClass {
    Class klass = NSClassFromString(classObjectName);
    if(rtb_classHasSwiftMetadata(klass) || rtb_classIsSwiftLegacy(klass)) return YES;
    // Swift classes are registered with mangled names such as _TtC10Foundation13__NSSwiftData,
    // or Module.ClassName since Swift 4. Objective-C class names cannot contain dots.
    return [classObjectName hasPrefix:@"_Tt"] || [classObjectName rangeOfString:@"."].location != NSNotFound;
}

- (NSString *)swiftDemangledName {
    
    if([self isSwiftClass] == NO) return nil;
    
    if(_cachedSwiftDemangledName) return _cachedSwiftDemangledName;
    
    rtb_loadSwiftRuntime();
    
    NSString *name = nil;
    
    Class klass = NSClassFromString(classObjectName);
    if(rtb_classHasSwiftMetadata(klass)) {
        name = rtb_swiftTypeName((__bridge const void *)klass); // also works for classes with an @objc(Name) name
    }
    
    if(name == nil && rtb_swift_demangle != NULL) {
        const char *mangledName = [classObjectName UTF8String];
        char *demangledName = rtb_swift_demangle(mangledName, strlen(mangledName), NULL, NULL, 0);
        if(demangledName) { // NULL if not a mangled name, eg. Module.ClassName
            name = [NSString stringWithCString:demangledName encoding:NSUTF8StringEncoding];
            free(demangledName);
        }
    }
    
    self.cachedSwiftDemangledName = name;
    
    return name;
}

- (NSString *)displayName {
    // the mangled names are unreadable, eg. _TtGCs13ManagedBufferVC10Foundation10_LocaleICU5StateVSo16os_unfair_lock_s_$
    if([classObjectName hasPrefix:@"_Tt"]) {
        NSString *demangledName = [self swiftDemangledName];
        if([demangledName length] > 0) return demangledName;
    }
    return classObjectName;
}

- (NSDictionary *)swiftFieldsByName {
    /*"
     The stored properties declared by this class (not by its superclasses), as read from the Swift metadata:
     name -> @{@"type": qualified Swift type name, @"isVar": bool, @"isStrong": bool}
     Empty for non-Swift classes and when the Swift runtime is too old.
     "*/
    
    if(_cachedSwiftFieldsByName) return _cachedSwiftFieldsByName;
    
    NSMutableDictionary *md = [NSMutableDictionary dictionary];
    self.cachedSwiftFieldsByName = md;
    
    Class klass = NSClassFromString(classObjectName);
    if(rtb_classHasSwiftMetadata(klass) == NO) return md;
    
    rtb_loadSwiftRuntime();
    if(rtb_swift_reflectionMirror_recursiveCount == NULL || rtb_swift_reflectionMirror_recursiveChildMetadata == NULL) return md;
    
    const void *metadata = (__bridge const void *)klass;
    
    // the count includes the fields of the Swift superclasses, which come first
    intptr_t count = rtb_swift_reflectionMirror_recursiveCount(metadata);
    Class superclass = class_getSuperclass(klass);
    intptr_t superclassCount = rtb_classHasSwiftMetadata(superclass) ? rtb_swift_reflectionMirror_recursiveCount((__bridge const void *)superclass) : 0;
    
    for(intptr_t i = superclassCount; i < count; i++) {
        RTBSwiftFieldReflectionMetadata fieldMetadata = {0};
        const void *fieldType = rtb_swift_reflectionMirror_recursiveChildMetadata(metadata, i, &fieldMetadata, &fieldMetadata.freeFunc);
        
        if(fieldMetadata.name) {
            NSString *name = [NSString stringWithCString:fieldMetadata.name encoding:NSUTF8StringEncoding];
            NSString *type = rtb_swiftTypeName(fieldType);
            if(name && md[name] == nil) {
                md[name] = @{@"type": (type ? type : @"?"), @"isVar": @(fieldMetadata.isVar), @"isStrong": @(fieldMetadata.isStrong)};
            }
            if(fieldMetadata.freeFunc) fieldMetadata.freeFunc(fieldMetadata.name);
        }
    }
    
    return md;
}

+ (NSString *)swiftDeclarationForDemangledSymbol:(NSString *)symbol typeName:(NSString *)typeName {
    /*"
     Turns a demangled function symbol into a Swift declaration, or returns nil if the symbol is not a member of typeName:
       Foo.__allocating_init(x: Swift.Int) -> Foo   ->  init(x: Swift.Int)
       Foo.bar(Swift.Int) -> Swift.String            ->  func bar(Swift.Int) -> Swift.String
       static Foo.baz() -> ()                        ->  static func baz() -> ()
       Foo.name.getter : Swift.String                ->  var name: Swift.String { get }
       Foo.__deallocating_deinit                     ->  deinit
     "*/
    NSString *s = symbol;
    NSString *prefix = @"";
    
    if([s hasPrefix:@"merged "]) s = [s substringFromIndex:[@"merged " length]]; // identical code folding
    
    if([s hasPrefix:@"static "]) {
        prefix = @"static ";
        s = [s substringFromIndex:[@"static " length]];
    }
    
    NSString *memberPrefix = [typeName stringByAppendingString:@"."];
    if([s hasPrefix:memberPrefix] == NO) return nil; // not a member of this class, eg. type metadata or a folded function of another class
    s = [s substringFromIndex:[memberPrefix length]];
    
    // private members carry a file discriminator, eg. (childActivationPoint in _2F6327E72581B7F866C81F7546545BE8)(implicit: Swift.Bool)
    if([s hasPrefix:@"("]) {
        NSRange inRange = [s rangeOfString:@" in _"];
        NSRange closingRange = [s rangeOfString:@")"];
        if(inRange.location != NSNotFound && closingRange.location != NSNotFound && inRange.location < closingRange.location) {
            NSString *name = [s substringWithRange:NSMakeRange(1, inRange.location - 1)];
            s = [name stringByAppendingString:[s substringFromIndex:closingRange.location + 1]];
            prefix = [prefix stringByAppendingString:@"private "];
        }
    }
    
    if([s hasPrefix:@"__allocating_init("] || [s hasPrefix:@"init("]) {
        NSRange arrowRange = [s rangeOfString:@" -> " options:NSBackwardsSearch];
        if(arrowRange.location != NSNotFound) s = [s substringToIndex:arrowRange.location];
        if([s hasPrefix:@"__allocating_init("]) s = [s substringFromIndex:[@"__allocating_" length]];
        return [prefix stringByAppendingString:s];
    }
    
    if([s isEqualToString:@"__deallocating_deinit"] || [s isEqualToString:@"deinit"]) {
        return @"deinit";
    }
    
    for(NSString *accessor in @[@".getter : ", @".setter : ", @".modify : ", @".read : "]) {
        NSRange r = [s rangeOfString:accessor];
        if(r.location != NSNotFound) {
            NSString *name = [s substringToIndex:r.location];
            NSString *type = [s substringFromIndex:r.location + [accessor length]];
            BOOL isSetter = [accessor isEqualToString:@".setter : "] || [accessor isEqualToString:@".modify : "];
            NSString *keyword = [name hasPrefix:@"subscript"] ? @"" : @"var ";
            return [NSString stringWithFormat:@"%@%@%@: %@ { %@ }", prefix, keyword, name, type, isSetter ? @"get set" : @"get"];
        }
    }
    
    if([s rangeOfString:@"("].location == NSNotFound) return nil; // not a function
    
    return [NSString stringWithFormat:@"%@func %@", prefix, s];
}

- (NSArray *)sortedSwiftMembers {
    /*"
     The Swift members of this class that can be recovered from the exported symbols: the class vtable
     is scanned and the entries that resolve to a symbol are demangled. Internal members are usually
     stripped, and only the entries that differ from the superclass ones are considered.
     Returns Swift declarations, eg. "init(name: Swift.String)", "func run() -> ()", "var name: Swift.String { get set }"
     "*/
    
    if(_cachedSortedSwiftMembers) return _cachedSortedSwiftMembers;
    
    NSMutableArray *ma = [NSMutableArray array];
    self.cachedSortedSwiftMembers = ma;
    
    Class klass = NSClassFromString(classObjectName);
    if(rtb_classHasSwiftMetadata(klass) == NO) return ma;
    
    rtb_loadSwiftRuntime();
    if(rtb_swift_demangle == NULL) return ma;
    
    NSString *typeName = rtb_swiftTypeName((__bridge const void *)klass);
    if(typeName == nil) return ma;
    
    /*
     Swift class metadata, see TargetClassMetadata in the Swift runtime headers:
       isa, superclass, cache (2 words), bits           5 pointers, the Objective-C class object
       flags, instanceAddressPoint, instanceSize         3 x uint32
       instanceAlignMask, reserved                       2 x uint16
       classSize, classAddressPoint                      2 x uint32
       description, ivarDestroyer                        2 pointers
       members: the superclass ones first, then the generic arguments, the field offsets and the vtable of this class
     */
    const size_t pointerSize = sizeof(void *);
    const size_t classSizeOffset = 5 * pointerSize + 16;
    const size_t classAddressPointOffset = 5 * pointerSize + 20;
    const size_t membersOffset = 7 * pointerSize + 24;
    
    const uint8_t *metadata = (const uint8_t *)(__bridge const void *)klass;
    uint32_t classSize = *(const uint32_t *)(metadata + classSizeOffset);
    uint32_t classAddressPoint = *(const uint32_t *)(metadata + classAddressPointOffset);
    if(classSize <= classAddressPoint || classSize - classAddressPoint > 1024 * 1024) return ma; // does not look right
    size_t endOffset = classSize - classAddressPoint;
    
    Class superclass = class_getSuperclass(klass);
    const uint8_t *superMetadata = NULL;
    size_t superEndOffset = 0;
    if(rtb_classHasSwiftMetadata(superclass)) {
        superMetadata = (const uint8_t *)(__bridge const void *)superclass;
        uint32_t superClassSize = *(const uint32_t *)(superMetadata + classSizeOffset);
        uint32_t superClassAddressPoint = *(const uint32_t *)(superMetadata + classAddressPointOffset);
        if(superClassSize > superClassAddressPoint) superEndOffset = superClassSize - superClassAddressPoint;
    }
    
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *accessorsByName = [NSMutableDictionary dictionary]; // "var name: T { get }" and "var name: T { get set }" -> keep the setter one
    
    for(size_t offset = membersOffset; offset + pointerSize <= endOffset; offset += pointerSize) {
        uintptr_t value = *(const uintptr_t *)(metadata + offset);
        
        // inherited entries have the same value at the same offset in the superclass metadata
        if(superMetadata && offset + pointerSize <= superEndOffset && *(const uintptr_t *)(superMetadata + offset) == value) continue;
        if(value < 0x100000000) continue; // field offsets and other small integers
        
        Dl_info info;
        if(dladdr((const void *)value, &info) == 0 || info.dli_sname == NULL) continue;
        if(info.dli_saddr != (const void *)value) continue; // not exactly a symbol, eg. a stripped internal function
        if(strcmp(info.dli_sname, "swift_deletedMethodError") == 0) continue;
        
        char *demangled = rtb_swift_demangle(info.dli_sname, strlen(info.dli_sname), NULL, NULL, 0);
        if(demangled == NULL) continue;
        NSString *symbol = [NSString stringWithCString:demangled encoding:NSUTF8StringEncoding];
        free(demangled);
        
        NSString *declaration = [[self class] swiftDeclarationForDemangledSymbol:symbol typeName:typeName];
        if(declaration == nil) continue;
        
        NSRange getRange = [declaration rangeOfString:@" { get"];
        if(getRange.location != NSNotFound) {
            NSString *key = [declaration substringToIndex:getRange.location];
            if(accessorsByName[key] == nil || [declaration hasSuffix:@"{ get set }"]) accessorsByName[key] = declaration;
            continue;
        }
        
        if([seen containsObject:declaration]) continue;
        [seen addObject:declaration];
        [ma addObject:declaration];
    }
    
    [ma addObjectsFromArray:[accessorsByName allValues]];
    
    // static members, then initializers, deinit, then the rest in alphabetical order
    NSInteger (^rank)(NSString *) = ^NSInteger(NSString *d) {
        if([d hasPrefix:@"static "]) return 0;
        if([d hasPrefix:@"init"]) return 1;
        if([d isEqualToString:@"deinit"]) return 2;
        if([d hasPrefix:@"private "]) return 4;
        return 3;
    };
    [ma sortUsingComparator:^NSComparisonResult(NSString *d1, NSString *d2) {
        NSInteger r1 = rank(d1), r2 = rank(d2);
        if(r1 != r2) return r1 < r2 ? NSOrderedAscending : NSOrderedDescending;
        return [d1 compare:d2];
    }];
    
    return ma;
}

#pragma mark BrowserNode protocol

- (NSArray *)children {
    return [self subclassesStubs];
}

- (NSString *)nodeName {
    return [self displayName]; // the runtime name is classObjectName
}

- (NSString *)nodeInfo {
    return [NSString stringWithFormat:@"%@ (%lu)", [self nodeName], (unsigned long)[[self children] count]];
}

- (BOOL)canBeSavedAsHeader {
    return YES;
}

@end
