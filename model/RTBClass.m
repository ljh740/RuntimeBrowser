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
#import "RTBSwift.h"
#import "dlfcn.h"

#import "RTBTypeDecoder.h"

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
@property (nonatomic, retain) NSString *cachedSearchableText;
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

- (NSString *)searchableText {
    /*"
     Everything the search looks into, lowercase, one token per line: the names of the class,
     the ivars, the methods parts, the protocols and the ivar types. Built once per class.
     "*/
    if(_cachedSearchableText == nil) {
        NSMutableArray *tokens = [NSMutableArray array];
        [tokens addObject:classObjectName];
        NSString *swiftName = [self swiftDemangledName];
        if(swiftName) [tokens addObject:swiftName];
        [tokens addObjectsFromArray:[[self iVarNames] allObjects]];
        [tokens addObjectsFromArray:[[self methodsNamePartsLowercase] allObjects]];
        [tokens addObjectsFromArray:[[self protocolsNames] allObjects]];
        [tokens addObjectsFromArray:[[self iVarDecodedTypes] allObjects]];
        self.cachedSearchableText = [[tokens componentsJoinedByString:@"\n"] lowercaseString];
    }
    return _cachedSearchableText;
}

- (BOOL)containsSearchString:(NSString *)searchString {
    NSString *ss = [searchString lowercaseString];
    if([ss length] == 0) return NO;
    return [[self searchableText] rangeOfString:ss].location != NSNotFound; // no newline in ss, so no match across tokens
}

- (NSString *)declarationForIvar:(Ivar)ivar name:(NSString *)name {
    
    // Swift-only types are not encoded (NULL or empty encoding) but the Swift runtime knows them, eg. Swift.Optional<Swift.String>
    const char *encodedTypeC = ivar_getTypeEncoding(ivar);
    NSString *encodedType = encodedTypeC ? [NSString stringWithCString:encodedTypeC encoding:NSUTF8StringEncoding] : nil;
    
    NSDictionary *swiftField = ([encodedType length] == 0 && name) ? [self swiftFieldsByName][name] : nil;
    if(swiftField) {
        NSMutableArray *comments = [NSMutableArray array];
        if([swiftField[@"isVar"] boolValue] == NO) [comments addObject:@"let"];
        if([swiftField[@"isStrong"] boolValue] == NO) [comments addObject:@"weak or unowned"];
        NSString *comment = [comments count] > 0 ? [NSString stringWithFormat:@" // %@", [comments componentsJoinedByString:@", "]] : @"";
        return [NSString stringWithFormat:@"%@ %@;%@", [RTBSwift displayedTypeNamesInString:swiftField[@"type"]], name, comment];
    }
    
    // full declaration, including the modifiers, eg. int _foo[10], int (*_callback)(), unsigned int _flags : 3
    return [[RTBTypeDecoder ivarDeclarationForEncodedType:encodedType name:name] stringByAppendingString:@";"];
}

- (NSArray *)sortedIvarDictionaries {
    
    Class class = NSClassFromString(classObjectName);
    NSAssert(class, @"no class named %@", classObjectName);
    
    unsigned int ivarListCount;
    Ivar *ivarList = class_copyIvarList(class, &ivarListCount);
    
    NSMutableArray *ivarDictionaries = [NSMutableArray array];
    
    for (unsigned int i = 0; i < ivarListCount; ++i ) {
        Ivar ivar = ivarList[i];
        
        // the compiler may generate ivar entries with NULL ivar_name (e.g. for anonymous bit fields).
        const char *nameC = ivar_getName(ivar);
        NSString *name = nameC ? [NSString stringWithCString:nameC encoding:NSUTF8StringEncoding] : nil;
        
        NSString *s = [NSString stringWithFormat:@"    %@", [self declarationForIvar:ivar name:name]];
        
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

- (BOOL)isSwiftClass {
    return [RTBSwift isSwiftClass:NSClassFromString(classObjectName)];
}

- (NSString *)swiftDemangledName {
    if(_cachedSwiftDemangledName == nil) {
        NSString *name = [RTBSwift nameOfClass:NSClassFromString(classObjectName)];
        self.cachedSwiftDemangledName = name ? name : @""; // remember the failures too
    }
    return [_cachedSwiftDemangledName length] > 0 ? _cachedSwiftDemangledName : nil;
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
    if(_cachedSwiftFieldsByName == nil) {
        self.cachedSwiftFieldsByName = [RTBSwift fieldsByNameOfClass:NSClassFromString(classObjectName)];
    }
    return _cachedSwiftFieldsByName;
}

- (NSArray *)sortedSwiftMembers {
    if(_cachedSortedSwiftMembers == nil) {
        self.cachedSortedSwiftMembers = [RTBSwift sortedMembersOfClass:NSClassFromString(classObjectName)];
    }
    return _cachedSortedSwiftMembers;
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
