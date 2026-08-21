//
//  RTBSwift.m
//  RuntimeBrowser
//
//  See RTBSwift.h
//

#import "RTBSwift.h"
#import "RTBSwiftRuntime.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#pragma mark Swift runtime

char *(*rtb_swift_demangle)(const char *mangledName, size_t mangledNameLength, char *outputBuffer, size_t *outputBufferSize, uint32_t flags);
RTBSwiftTypeNamePair (*rtb_swift_getTypeName)(const void *type, bool qualified);
RTBSwiftTypeNamePair (*rtb_swift_getMangledTypeName)(const void *type);
intptr_t (*rtb_swift_reflectionMirror_recursiveCount)(const void *type);
const void *(*rtb_swift_reflectionMirror_recursiveChildMetadata)(const void *type, intptr_t index, RTBSwiftFieldReflectionMetadata *outMetadata, void (**outFreeFunc)(const char *));
const void *(*rtb_swift_getTypeByMangledNameInContext)(const char *typeNameStart, size_t typeNameLength, const void *context, const void * const *genericArgs);

void rtb_loadSwiftRuntime(void) {
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
        rtb_swift_getTypeByMangledNameInContext = dlsym(handle, "swift_getTypeByMangledNameInContext");
    });
}

NSString *rtb_swiftDemangledName(NSString *mangledName) {
    rtb_loadSwiftRuntime();
    if(rtb_swift_demangle == NULL || mangledName == nil) return nil;
    
    const char *mangledNameC = [mangledName UTF8String];
    char *demangledName = rtb_swift_demangle(mangledNameC, strlen(mangledNameC), NULL, NULL, 0);
    if(demangledName == NULL) return nil; // not a mangled name
    
    NSString *s = [NSString stringWithCString:demangledName encoding:NSUTF8StringEncoding];
    free(demangledName);
    return [s isEqualToString:mangledName] ? nil : s; // swift_demangle() returns the mangled name when it cannot demangle it
}

#pragma mark Metadata

static uintptr_t rtb_objcClassBits(Class klass) {
    // objc_class.bits is the fifth word of a class object, after isa, superclass and the two words of the cache.
    // The Swift runtime uses its two low bits: bit 0 for the pre-stable ABI, bit 1 for the stable ABI (Swift 5).
    return klass ? ((uintptr_t *)(__bridge void *)klass)[4] : 0;
}

static BOOL rtb_classHasSwiftMetadata(Class klass) {
    // The Objective-C class object of a stable ABI Swift class is the beginning of its Swift metadata.
#if __LP64__
    return (rtb_objcClassBits(klass) & 0x2) != 0;
#else
    return NO; // the metadata layout and the runtime calls are only vetted on 64-bit
#endif
}

static BOOL rtb_classIsSwiftLegacy(Class klass) {
    return (rtb_objcClassBits(klass) & 0x1) != 0;
}

NSString *rtb_swiftTypeName(const void *metadata) {
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

// (extension in Foundation):Foundation.Measurement< where A: __C.NSDimension>.FormatStyle.width -> (extension in Foundation):Foundation.Measurement.FormatStyle.width
// The demangler writes the requirements of the constrained extensions in the contexts, the names of the types don't have them.
static NSString *rtb_stringByRemovingWhereClauses(NSString *s) {
    NSRange r = [s rangeOfString:@"< where "];
    if(r.location == NSNotFound) return s;
    NSMutableString *ms = [NSMutableString string];
    NSUInteger depth = 0;
    for(NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if(depth == 0 && c == '<' && [s rangeOfString:@"< where " options:NSAnchoredSearch range:NSMakeRange(i, [s length] - i)].location != NSNotFound) {
            depth = 1;
        } else if(depth > 0) {
            if(c == '<') depth++;
            else if(c == '>') depth--;
        } else {
            [ms appendFormat:@"%C", c];
        }
    }
    return ms;
}

NSString *rtb_swiftMangledNominalTypeName(const void *metadata) {
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
        indexesByImage = [[NSMutableDictionary alloc] init];
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

NSArray *rtb_swiftSymbolNamesWithPrefix(const void *imageBase, NSString *prefix) {
    
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

#pragma mark Members

NSArray *rtb_swiftSortedMembers(NSString *typeName, NSString *mangledNominalName, const void *imageBase) {
    /*"
     The symbols of the image whose mangled name starts with the mangled name of the type are demangled
     and turned into declarations, eg. "init(name: Swift.String)", "func run() -> ()", "var name: Swift.String { get set }".
     "*/
    
    NSMutableArray *ma = [NSMutableArray array];
    
    rtb_loadSwiftRuntime();
    if(rtb_swift_demangle == NULL || typeName == nil || mangledNominalName == nil || imageBase == NULL) return ma;
    
    // the members of a generic type are declared for the unspecialized type, eg. Swift.ManagedBuffer.header.getter : A
    typeName = rtb_stringByRemovingGenericArguments(typeName);
    
    NSArray *symbols = rtb_swiftSymbolNamesWithPrefix(imageBase, [@"$s" stringByAppendingString:mangledNominalName]);
    
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *propertiesByKey = [NSMutableDictionary dictionary]; // "var name: T" -> the most complete declaration
    
    for(NSString *symbol in symbols) {
        char *demangled = rtb_swift_demangle([symbol UTF8String], [symbol lengthOfBytesUsingEncoding:NSUTF8StringEncoding], NULL, NULL, 0);
        if(demangled == NULL) continue;
        NSString *demangledSymbol = [NSString stringWithCString:demangled encoding:NSUTF8StringEncoding];
        free(demangled);
        
        NSString *declaration = [RTBSwift declarationForDemangledSymbol:rtb_stringByRemovingWhereClauses(demangledSymbol) typeName:typeName];
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

#pragma mark - RTBSwift

@implementation RTBSwift

+ (BOOL)classHasSwiftMetadata:(Class)klass {
    return rtb_classHasSwiftMetadata(klass);
}

+ (BOOL)isSwiftClass:(Class)klass {
    if(klass == Nil) return NO;
    if(rtb_classHasSwiftMetadata(klass) || rtb_classIsSwiftLegacy(klass)) return YES;
    // Swift classes are registered with mangled names such as _TtC10Foundation13__NSSwiftData,
    // or Module.ClassName since Swift 4. Objective-C class names cannot contain dots.
    const char *name = class_getName(klass);
    return name && (strncmp(name, "_Tt", 3) == 0 || strchr(name, '.') != NULL);
}

+ (NSString *)demangledName:(NSString *)mangledName {
    return rtb_swiftDemangledName(mangledName);
}

+ (NSString *)nameOfClass:(Class)klass {
    if([self isSwiftClass:klass] == NO) return nil;
    
    rtb_loadSwiftRuntime();
    
    if(rtb_classHasSwiftMetadata(klass)) {
        NSString *name = rtb_swiftTypeName((__bridge const void *)klass); // also works for classes with an @objc(Name) name
        if(name) return name;
    }
    
    return [self demangledName:NSStringFromClass(klass)];
}

+ (NSDictionary *)fieldsByNameOfClass:(Class)klass {
    /*"
     The stored properties declared by a class (not by its superclasses), as read from the Swift metadata:
     name -> @{@"type": qualified Swift type name, @"isVar": bool, @"isStrong": bool}
     Empty for non-Swift classes and when the Swift runtime is too old.
     "*/
    
    NSMutableDictionary *md = [NSMutableDictionary dictionary];
    
    if(rtb_classHasSwiftMetadata(klass) == NO) return md;
    
    rtb_loadSwiftRuntime();
    if(rtb_swift_reflectionMirror_recursiveCount == NULL || rtb_swift_reflectionMirror_recursiveChildMetadata == NULL) return md;
    
    const void *metadata = (__bridge const void *)klass;
    
    // the count includes the fields of the Swift superclasses, which come first
    intptr_t count = rtb_swift_reflectionMirror_recursiveCount(metadata);
    Class superclass = class_getSuperclass(klass);
    intptr_t superclassCount = rtb_classHasSwiftMetadata(superclass) ? rtb_swift_reflectionMirror_recursiveCount((__bridge const void *)superclass) : 0;
    
    // the runtime aborts on the fields whose type goes through a missing weak symbol, they are read from the field descriptor
    NSDictionary *unresolvableFields = rtb_swiftClassFieldsWithMissingSymbols(klass);

    for(intptr_t i = superclassCount; i < count; i++) {
        NSDictionary *unresolvableField = unresolvableFields[@(i - superclassCount)];
        if(unresolvableField) {
            NSString *name = unresolvableField[@"name"];
            if(md[name] == nil) md[name] = @{@"type": @"?", @"isVar": unresolvableField[@"isVar"], @"isStrong": unresolvableField[@"isStrong"]};
            continue;
        }

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

#pragma mark Simplified type names

// the index of the '>' closing the '<' at openIndex, NSNotFound if unbalanced
static NSUInteger rtb_indexOfClosingAngleBracket(NSString *s, NSUInteger openIndex) {
    NSInteger depth = 0;
    for(NSUInteger i = openIndex; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if(c == '<') depth++;
        else if(c == '>' && !(i > 0 && [s characterAtIndex:i - 1] == '-')) { depth--; if(depth == 0) return i; } // not the arrow of a function type
    }
    return NSNotFound;
}

// splits at the commas that are not nested in <> or ()
static NSArray *rtb_topLevelComponents(NSString *s) {
    NSMutableArray *components = [NSMutableArray array];
    NSInteger depth = 0;
    NSUInteger start = 0;
    for(NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL isArrow = c == '>' && i > 0 && [s characterAtIndex:i - 1] == '-';
        if(c == '<' || c == '(' || c == '[') depth++;
        else if((c == '>' && !isArrow) || c == ')' || c == ']') depth--;
        else if(c == ',' && depth == 0) {
            [components addObject:[[s substringWithRange:NSMakeRange(start, i - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            start = i + 1;
        }
    }
    [components addObject:[[s substringFromIndex:start] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    return components;
}

// a function type, a protocol composition or an existential must be parenthesized before a '?'
static BOOL rtb_needsParenthesesForOptional(NSString *s) {
    NSInteger depth = 0;
    for(NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL isArrow = c == '>' && i > 0 && [s characterAtIndex:i - 1] == '-';
        if(c == '<' || c == '(' || c == '[') depth++;
        else if((c == '>' && !isArrow) || c == ')' || c == ']') depth--;
        else if(depth == 0 && c == ' ') return YES; // "(Int) -> Int", "A & B", "any P", "some P"
    }
    return NO;
}

+ (NSString *)simplifiedTypeNamesInString:(NSString *)string {
    if([string length] == 0) return string;
    
    NSMutableString *s = [string mutableCopy];
    
    // the sugar, innermost first would be natural but leftmost first with recursion on the argument works the same
    NSArray *sugars = @[@"Swift.Optional<", @"Swift.Array<", @"Swift.Dictionary<"];
    BOOL found = YES;
    NSUInteger guard = 0;
    while(found && guard++ < 10000) {
        found = NO;
        NSRange best = NSMakeRange(NSNotFound, 0);
        NSString *bestSugar = nil;
        for(NSString *sugar in sugars) {
            NSRange r = [s rangeOfString:sugar];
            if(r.location != NSNotFound && (best.location == NSNotFound || r.location < best.location)) { best = r; bestSugar = sugar; }
        }
        if(bestSugar == nil) break;
        
        NSUInteger openIndex = best.location + best.length - 1;
        NSUInteger closeIndex = rtb_indexOfClosingAngleBracket(s, openIndex);
        if(closeIndex == NSNotFound) break;
        
        NSString *inner = [self simplifiedTypeNamesInString:[s substringWithRange:NSMakeRange(openIndex + 1, closeIndex - openIndex - 1)]];
        NSString *replacement = nil;
        if([bestSugar isEqualToString:@"Swift.Optional<"]) {
            replacement = rtb_needsParenthesesForOptional(inner) ? [NSString stringWithFormat:@"(%@)?", inner] : [inner stringByAppendingString:@"?"];
        } else if([bestSugar isEqualToString:@"Swift.Array<"]) {
            replacement = [NSString stringWithFormat:@"[%@]", inner];
        } else {
            NSArray *components = rtb_topLevelComponents(inner);
            replacement = [components count] == 2 ? [NSString stringWithFormat:@"[%@: %@]", components[0], components[1]] : [NSString stringWithFormat:@"Dictionary<%@>", inner];
        }
        [s replaceCharactersInRange:NSMakeRange(best.location, closeIndex - best.location + 1) withString:replacement];
        found = YES;
    }
    
    // module prefixes, when they start an identifier: Swift.Int -> Int, __C.NSRunLoop -> NSRunLoop, but not SwiftUI.View
    for(NSString *prefix in @[@"Swift.", @"__C."]) {
        NSRange searchRange = NSMakeRange(0, [s length]);
        while(searchRange.length > 0) {
            NSRange r = [s rangeOfString:prefix options:0 range:searchRange];
            if(r.location == NSNotFound) break;
            unichar before = r.location > 0 ? [s characterAtIndex:r.location - 1] : ' ';
            BOOL startsIdentifier = !(isalnum(before) || before == '_' || before == '.');
            if(startsIdentifier) {
                [s deleteCharactersInRange:r];
                searchRange = NSMakeRange(r.location, [s length] - r.location);
            } else {
                searchRange = NSMakeRange(r.location + r.length, [s length] - r.location - r.length);
            }
        }
    }
    
    return s;
}

+ (BOOL)simplifiesTypeNames {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"RTBSimplifiedSwiftTypes"];
}

+ (NSString *)displayedTypeNamesInString:(NSString *)string {
    return [self simplifiesTypeNames] ? [self simplifiedTypeNamesInString:string] : string;
}

#pragma mark Members

+ (NSString *)declarationForDemangledSymbol:(NSString *)symbol typeName:(NSString *)typeName {
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
    
    if([s hasPrefix:@"__allocating_init("] || [s hasPrefix:@"init("] || [s hasPrefix:@"__allocating_init<"] || [s hasPrefix:@"init<"]) {
        NSRange arrowRange = [s rangeOfString:@" -> " options:NSBackwardsSearch];
        NSString *returnType = arrowRange.location != NSNotFound ? [s substringFromIndex:arrowRange.location + 4] : nil;
        if(arrowRange.location != NSNotFound) s = [s substringToIndex:arrowRange.location];
        if([s hasPrefix:@"__allocating_init"]) s = [s substringFromIndex:[@"__allocating_" length]];
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

+ (NSArray *)sortedMembersOfClass:(Class)klass {
    /*"
     The Swift members of a class, recovered from the symbol table of its image, see rtb_swiftSortedMembers().
     Public members always have exported symbols (dispatch thunks and method descriptors), the internal
     ones only when the image is not stripped.
     "*/
    
    if(rtb_classHasSwiftMetadata(klass) == NO) return @[];
    
    rtb_loadSwiftRuntime();
    
    const void *metadata = (__bridge const void *)klass;
    NSString *typeName = rtb_swiftTypeName(metadata);
    NSString *mangledName = rtb_swiftMangledNominalTypeName(metadata);
    if(typeName == nil || mangledName == nil) return @[];
    
    // the metadata of a generic specialization is instantiated at runtime outside of any image,
    // but its nominal type descriptor is in the image where the class was compiled
    const void *imageBase = NULL;
    Dl_info info;
    const void *description = *(const void **)((const uint8_t *)metadata + 5 * sizeof(void *) + 24); // see TargetClassMetadata
    if(description && dladdr(description, &info) != 0) imageBase = info.dli_fbase;
    if(imageBase == NULL && dladdr(metadata, &info) != 0) imageBase = info.dli_fbase;
    if(imageBase == NULL) return @[];
    
    return rtb_swiftSortedMembers(typeName, mangledName, imageBase);
}

@end
