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
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

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
static RTBSwiftTypeNamePair (*rtb_swift_getMangledTypeName)(const void *type);
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
        rtb_swift_getMangledTypeName = dlsym(handle, "swift_getMangledTypeName"); // Swift 5.3+
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

static NSString *rtb_stringByRemovingGenericArguments(NSString *typeName) {
    // Swift.ManagedBuffer<Foundation._LocaleICU.State, __C.os_unfair_lock_s> -> Swift.ManagedBuffer, Module.Outer<A>.Inner<B> -> Module.Outer.Inner
    NSMutableString *ms = [NSMutableString string];
    NSUInteger depth = 0;
    for(NSUInteger i = 0; i < [typeName length]; i++) {
        unichar c = [typeName characterAtIndex:i];
        if(c == '<') depth++;
        else if(c == '>') { if(depth > 0) depth--; }
        else if(depth == 0) [ms appendFormat:@"%C", c];
    }
    return ms;
}

static NSString *rtb_swiftMangledNominalTypeName(const void *metadata) {
    /*"
     The mangled name of the type without the generic arguments, eg. 7SwiftUI17AccessibilityNodeC.
     The symbols of the members of the type start with "$s" followed by this name.
     "*/
    if(metadata == NULL || rtb_swift_getMangledTypeName == NULL) return nil;
    RTBSwiftTypeNamePair pair = rtb_swift_getMangledTypeName(metadata);
    if(pair.data == NULL || pair.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithBytes:pair.data length:pair.length encoding:NSUTF8StringEncoding];
    if([s hasSuffix:@"G"]) {
        // the generic arguments follow the nominal type after a 'y', eg. s13ManagedBufferCySSSiG for Swift.ManagedBuffer<Swift.String, Swift.Int>
        // identifiers are length-prefixed and may contain a 'y', so we walk the tokens
        NSUInteger i = 0, length = pair.length;
        while(i < length) {
            char c = pair.data[i];
            if(c >= '0' && c <= '9') {
                NSUInteger identifierLength = 0;
                while(i < length && pair.data[i] >= '0' && pair.data[i] <= '9') identifierLength = identifierLength * 10 + (pair.data[i++] - '0');
                i += identifierLength;
            } else if(c == 'y') {
                break;
            } else {
                i++; // a context marker, eg. C, V, O, E, So, s
            }
        }
        if(i >= length) return nil;
        s = [[NSString alloc] initWithBytes:pair.data length:i encoding:NSUTF8StringEncoding];
    }
    return s;
}

#pragma mark Swift symbols

/*
 The names of the Swift symbols of an image, sorted, so that the members of a class can be found by prefix.
 The pointers point into the string table of the image, which stays mapped. Built once per image.
 */

typedef struct {
    const char **names;
    NSUInteger count;
} RTBSwiftSymbolIndex;

static int rtb_compareSymbolNames(const void *a, const void *b) {
    return strcmp(*(const char **)a, *(const char **)b);
}

static RTBSwiftSymbolIndex *rtb_swiftSymbolIndexForImage(const void *imageBase) {
    
    static NSMutableDictionary *indexesByImage = nil;
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        indexesByImage = [NSMutableDictionary dictionary];
        lock = [[NSLock alloc] init];
    });
    
    if(imageBase == NULL) return NULL;
    
    NSValue *key = [NSValue valueWithPointer:imageBase];
    
    [lock lock];
    NSValue *cached = indexesByImage[key];
    [lock unlock];
    if(cached) return (RTBSwiftSymbolIndex *)[cached pointerValue];
    
    RTBSwiftSymbolIndex *index = calloc(1, sizeof(RTBSwiftSymbolIndex));
    
#if __LP64__
    typedef struct mach_header_64 rtb_mach_header;
    typedef struct segment_command_64 rtb_segment_command;
    typedef struct nlist_64 rtb_nlist;
    const uint32_t rtb_lc_segment = LC_SEGMENT_64;
#else
    typedef struct mach_header rtb_mach_header;
    typedef struct segment_command rtb_segment_command;
    typedef struct nlist rtb_nlist;
    const uint32_t rtb_lc_segment = LC_SEGMENT;
#endif
    
    const rtb_mach_header *header = (const rtb_mach_header *)imageBase;
    const struct load_command *command = (const struct load_command *)(header + 1);
    const rtb_segment_command *textSegment = NULL;
    const rtb_segment_command *linkeditSegment = NULL;
    const struct symtab_command *symtabCommand = NULL;
    
    for(uint32_t i = 0; i < header->ncmds; i++) {
        if(command->cmd == rtb_lc_segment) {
            const rtb_segment_command *segment = (const rtb_segment_command *)command;
            if(strcmp(segment->segname, SEG_TEXT) == 0) textSegment = segment;
            else if(strcmp(segment->segname, SEG_LINKEDIT) == 0) linkeditSegment = segment;
        } else if(command->cmd == LC_SYMTAB) {
            symtabCommand = (const struct symtab_command *)command;
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    
    if(textSegment && linkeditSegment && symtabCommand && symtabCommand->nsyms > 0) {
        // the symbol table lives in __LINKEDIT, whose file offset differs from its address
        intptr_t slide = (intptr_t)header - (intptr_t)textSegment->vmaddr;
        const uint8_t *linkeditBase = (const uint8_t *)(linkeditSegment->vmaddr - linkeditSegment->fileoff + slide);
        const rtb_nlist *symbols = (const rtb_nlist *)(linkeditBase + symtabCommand->symoff);
        const char *strings = (const char *)(linkeditBase + symtabCommand->stroff);
        
        index->names = malloc(symtabCommand->nsyms * sizeof(const char *));
        for(uint32_t i = 0; i < symtabCommand->nsyms; i++) {
            if((symbols[i].n_type & N_TYPE) != N_SECT) continue; // defined in a section of this image
            if(symbols[i].n_un.n_strx == 0 || symbols[i].n_un.n_strx >= symtabCommand->strsize) continue;
            const char *name = strings + symbols[i].n_un.n_strx;
            if(name[0] != '_' || name[1] != '$' || name[2] != 's') continue; // Swift symbols only, eg. _$s7SwiftUI17AccessibilityNodeC13sendAction5namedSbSS_tF
            index->names[index->count++] = name + 1; // skip the leading underscore
        }
        qsort(index->names, index->count, sizeof(const char *), rtb_compareSymbolNames);
    }
    
    [lock lock];
    if(indexesByImage[key] == nil) {
        indexesByImage[key] = [NSValue valueWithPointer:index];
    } else {
        // another thread was faster
        free(index->names);
        free(index);
        index = (RTBSwiftSymbolIndex *)[indexesByImage[key] pointerValue];
    }
    [lock unlock];
    
    return index;
}

static NSArray *rtb_swiftSymbolNamesWithPrefix(const void *imageBase, NSString *prefix) {
    
    RTBSwiftSymbolIndex *index = rtb_swiftSymbolIndexForImage(imageBase);
    if(index == NULL || index->count == 0 || [prefix length] == 0) return @[];
    
    const char *prefixC = [prefix UTF8String];
    size_t prefixLength = strlen(prefixC);
    
    // binary search for the first symbol >= prefix, then walk while the prefix matches
    NSUInteger low = 0, high = index->count;
    while(low < high) {
        NSUInteger mid = (low + high) / 2;
        if(strncmp(index->names[mid], prefixC, prefixLength) < 0) low = mid + 1;
        else high = mid;
    }
    
    NSMutableArray *ma = [NSMutableArray array];
    for(NSUInteger i = low; i < index->count && strncmp(index->names[i], prefixC, prefixLength) == 0; i++) {
        NSString *name = [NSString stringWithCString:index->names[i] encoding:NSUTF8StringEncoding];
        if(name && [[ma lastObject] isEqualToString:name] == NO) [ma addObject:name]; // sorted, so duplicates are neighbours
    }
    return ma;
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
     Turns a demangled symbol into a Swift declaration, or returns nil if the symbol is not a member of typeName:
       Foo.__allocating_init(x: Swift.Int) -> Foo   ->  init(x: Swift.Int)
       Foo.bar(Swift.Int) -> Swift.String            ->  func bar(Swift.Int) -> Swift.String
       static Foo.baz() -> ()                        ->  static func baz() -> ()
       Foo.name.getter : Swift.String                ->  var name: Swift.String { get }
       dispatch thunk of Foo.bar() -> ()             ->  func bar() -> ()
       property descriptor for Foo.name : Swift.String -> var name: Swift.String
     Deinitializers, nested types, closures, thunks and metadata are not members.
     "*/
    NSString *s = symbol;
    NSString *prefix = @"";
    
    if([s rangeOfString:@" with unmangled suffix "].location != NSNotFound) return nil; // eg. coroutine continuations, .resume.0
    
    // symbols that stand for a member: the member itself, its dispatch thunk, its descriptor, a specialization
    for(NSString *p in @[@"dispatch thunk of ", @"method descriptor for ", @"property descriptor for ", @"merged "]) {
        if([s hasPrefix:p]) s = [s substringFromIndex:[p length]];
    }
    for(NSString *p in @[@"generic specialization <", @"function signature specialization <"]) {
        if([s hasPrefix:p]) {
            NSRange r = [s rangeOfString:@"> of "];
            if(r.location == NSNotFound) return nil;
            s = [s substringFromIndex:r.location + [@"> of " length]];
        }
    }
    
    if([s hasPrefix:@"static "]) {
        prefix = @"static ";
        s = [s substringFromIndex:[@"static " length]];
    }
    
    // members declared in extensions, eg. (extension in Other):Module.Foo.bar() -> ()
    if([s hasPrefix:@"(extension in "] && [typeName hasPrefix:@"(extension in "] == NO) {
        NSRange r = [s rangeOfString:@"):"];
        if(r.location != NSNotFound) s = [s substringFromIndex:r.location + 2];
    }
    
    NSString *memberPrefix = [typeName stringByAppendingString:@"."];
    if([s hasPrefix:memberPrefix] == NO) return nil; // not a member of this class, eg. type metadata, a closure, a protocol witness, or a folded function of another class
    s = [s substringFromIndex:[memberPrefix length]];
    
    // private members carry a file discriminator, eg. (childActivationPoint in _2F6327E72581B7F866C81F7546545BE8)(implicit: Swift.Bool)
    if([s hasPrefix:@"("]) {
        NSRange inRange = [s rangeOfString:@" in _"];
        NSRange closingRange = [s rangeOfString:@")"];
        if(inRange.location != NSNotFound && closingRange.location != NSNotFound && inRange.location < closingRange.location) {
            NSString *name = [s substringWithRange:NSMakeRange(1, inRange.location - 1)];
            s = [name stringByAppendingString:[s substringFromIndex:closingRange.location + 1]];
            prefix = [prefix stringByAppendingString:@"private "];
        } else {
            return nil;
        }
    }
    
    if([s hasPrefix:@"__allocating_init("] || [s hasPrefix:@"init("]) {
        NSRange arrowRange = [s rangeOfString:@" -> " options:NSBackwardsSearch];
        NSString *returnType = arrowRange.location != NSNotFound ? [s substringFromIndex:arrowRange.location + 4] : nil;
        if(arrowRange.location != NSNotFound) s = [s substringToIndex:arrowRange.location];
        if([s hasPrefix:@"__allocating_init("]) s = [s substringFromIndex:[@"__allocating_" length]];
        if([returnType hasPrefix:@"Swift.Optional<"]) s = [@"init?" stringByAppendingString:[s substringFromIndex:[@"init" length]]]; // failable
        return [prefix stringByAppendingString:s];
    }
    
    if([s hasPrefix:@"__deallocating_deinit"] || [s hasPrefix:@"deinit"] || [s hasPrefix:@"__ivar_"]) {
        return nil; // every class has them, not interesting
    }
    
    // accessors, eg. name.getter : Swift.String, subscript.getter : (Swift.Int) -> Swift.String
    for(NSString *accessor in @[@".getter : ", @".setter : ", @".modify : ", @".read : ", @".unsafeMutableAddressor : ", @".didset : ", @".willset : "]) {
        NSRange r = [s rangeOfString:accessor];
        if(r.location != NSNotFound) {
            NSString *name = [s substringToIndex:r.location];
            NSString *type = [s substringFromIndex:r.location + [accessor length]];
            if([name rangeOfString:@"."].location != NSNotFound) return nil; // a property of a nested type
            // note that unsafeMutableAddressor is emitted for static let as well, the setter symbol tells about mutability
            BOOL isSetter = [accessor isEqualToString:@".setter : "] || [accessor isEqualToString:@".modify : "] || [accessor isEqualToString:@".didset : "] || [accessor isEqualToString:@".willset : "];
            NSString *accessors = isSetter ? @"{ get set }" : @"{ get }";
            if([name isEqualToString:@"subscript"] && [type hasPrefix:@"("]) {
                return [NSString stringWithFormat:@"%@subscript%@ %@", prefix, type, accessors];
            }
            return [NSString stringWithFormat:@"%@var %@: %@ %@", prefix, name, type, accessors];
        }
    }
    
    // property, from a property descriptor, eg. name : Swift.String
    NSRange colonRange = [s rangeOfString:@" : "];
    NSRange parenRange = [s rangeOfString:@"("];
    NSRange angleRange = [s rangeOfString:@"<"];
    if(colonRange.location != NSNotFound && (parenRange.location == NSNotFound || colonRange.location < parenRange.location) && (angleRange.location == NSNotFound || colonRange.location < angleRange.location)) {
        NSString *name = [s substringToIndex:colonRange.location];
        if([name rangeOfString:@"."].location != NSNotFound || [name rangeOfString:@" "].location != NSNotFound) return nil;
        return [NSString stringWithFormat:@"%@var %@: %@", prefix, name, [s substringFromIndex:colonRange.location + 3]];
    }
    
    // functions, eg. bar(Swift.Int) -> Swift.String, run<A where A: Swift.Equatable>(A) -> ()
    if(parenRange.location == NSNotFound) return nil;
    NSUInteger nameEnd = (angleRange.location != NSNotFound && angleRange.location < parenRange.location) ? angleRange.location : parenRange.location;
    NSString *name = [s substringToIndex:nameEnd];
    
    // operators, eg. == infix(Module.Foo, Module.Foo) -> Swift.Bool
    for(NSString *fixity in @[@" infix", @" prefix", @" postfix"]) {
        if([name hasSuffix:fixity]) {
            name = [name substringToIndex:[name length] - [fixity length]];
            s = [name stringByAppendingString:[s substringFromIndex:nameEnd]];
            break;
        }
    }
    
    if([name length] == 0 || [name rangeOfString:@"."].location != NSNotFound || [name rangeOfString:@" "].location != NSNotFound) return nil; // a member of a nested type, or not a plain function
    
    return [NSString stringWithFormat:@"%@func %@", prefix, s];
}

- (NSArray *)sortedSwiftMembers {
    /*"
     The Swift members of this class, recovered from the symbol table of its image: the symbols whose
     mangled name starts with the mangled name of the class are demangled and turned into declarations,
     eg. "init(name: Swift.String)", "func run() -> ()", "var name: Swift.String { get set }".
     Public members always have exported symbols (dispatch thunks and method descriptors), the internal
     ones only when the image is not stripped.
     "*/
    
    if(_cachedSortedSwiftMembers) return _cachedSortedSwiftMembers;
    
    NSMutableArray *ma = [NSMutableArray array];
    self.cachedSortedSwiftMembers = ma;
    
    Class klass = NSClassFromString(classObjectName);
    if(rtb_classHasSwiftMetadata(klass) == NO) return ma;
    
    rtb_loadSwiftRuntime();
    if(rtb_swift_demangle == NULL) return ma;
    
    const void *metadata = (__bridge const void *)klass;
    NSString *typeName = rtb_swiftTypeName(metadata);
    NSString *mangledName = rtb_swiftMangledNominalTypeName(metadata);
    if(typeName == nil || mangledName == nil) return ma;
    
    // the members of a generic class are declared for the unspecialized type, eg. Swift.ManagedBuffer.header.getter : A
    typeName = rtb_stringByRemovingGenericArguments(typeName);
    
    // the metadata of a generic specialization is instantiated at runtime outside of any image,
    // but its nominal type descriptor is in the image where the class was compiled
    const void *imageBase = NULL;
    Dl_info info;
    const void *description = *(const void **)((const uint8_t *)metadata + 5 * sizeof(void *) + 24); // see TargetClassMetadata
    if(description && dladdr(description, &info) != 0) imageBase = info.dli_fbase;
    if(imageBase == NULL && dladdr(metadata, &info) != 0) imageBase = info.dli_fbase;
    if(imageBase == NULL) return ma;
    
    NSArray *symbols = rtb_swiftSymbolNamesWithPrefix(imageBase, [@"$s" stringByAppendingString:mangledName]);
    
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *propertiesByKey = [NSMutableDictionary dictionary]; // "var name: T" -> the most complete declaration
    
    for(NSString *symbol in symbols) {
        char *demangled = rtb_swift_demangle([symbol UTF8String], [symbol lengthOfBytesUsingEncoding:NSUTF8StringEncoding], NULL, NULL, 0);
        if(demangled == NULL) continue;
        NSString *demangledSymbol = [NSString stringWithCString:demangled encoding:NSUTF8StringEncoding];
        free(demangled);
        
        NSString *declaration = [[self class] swiftDeclarationForDemangledSymbol:demangledSymbol typeName:typeName];
        if(declaration == nil) continue;
        
        // the accessors and the property descriptor of a property yield several declarations, keep the most complete one
        NSRange accessorsRange = [declaration rangeOfString:@" { get"];
        NSString *key = accessorsRange.location != NSNotFound ? [declaration substringToIndex:accessorsRange.location] : declaration;
        if([key hasPrefix:@"var "] || [key hasPrefix:@"static var "] || [key hasPrefix:@"private var "] || [key hasPrefix:@"static private var "]) {
            NSString *existing = propertiesByKey[key];
            if(existing == nil || [declaration length] > [existing length]) propertiesByKey[key] = declaration; // "{ get set }" > "{ get }" > nothing
            continue;
        }
        
        if([seen containsObject:declaration]) continue;
        [seen addObject:declaration];
        [ma addObject:declaration];
    }
    
    [ma addObjectsFromArray:[propertiesByKey allValues]];
    
    // static members, then initializers, then the rest in alphabetical order, private members last
    NSInteger (^rank)(NSString *) = ^NSInteger(NSString *d) {
        if([d hasPrefix:@"static "]) return 0;
        if([d hasPrefix:@"init"]) return 1;
        if([d hasPrefix:@"private "]) return 3;
        return 2;
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
