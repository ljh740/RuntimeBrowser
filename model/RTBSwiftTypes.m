//
//  RTBSwiftTypes.m
//  RuntimeBrowser
//
//  See RTBSwiftTypes.h
//
//  The layouts read here are the stable Swift ABI (Swift 5), see the Swift ABI documentation
//  (TypeMetadata.rst) and include/swift/ABI/Metadata.h in the Swift sources. Every relative
//  pointer is checked to point inside the image before being followed.
//

#import "RTBSwiftTypes.h"
#import "RTBSwiftRuntime.h"
#import "RTBSwift.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

#pragma mark Images and relative pointers

// the address range of a loaded image, to validate the relative pointers
typedef struct {
    const struct mach_header *header;
    uintptr_t start;
    uintptr_t end;
    intptr_t slide;
} RTBImage;

#if __LP64__
typedef struct mach_header_64 rtb_mach_header;
typedef struct segment_command_64 rtb_segment_command;
static const uint32_t rtb_lc_segment = LC_SEGMENT_64;
#else
typedef struct mach_header rtb_mach_header;
typedef struct segment_command rtb_segment_command;
static const uint32_t rtb_lc_segment = LC_SEGMENT;
#endif

static RTBImage rtb_imageWithHeader(const struct mach_header *header) {
    RTBImage image = { header, UINTPTR_MAX, 0, 0 };
    if(header == NULL) { image.start = 0; return image; }

    const rtb_mach_header *mh = (const rtb_mach_header *)header;
    const struct load_command *command = (const struct load_command *)(mh + 1);
    for(uint32_t i = 0; i < mh->ncmds; i++) {
        if(command->cmd == rtb_lc_segment) {
            const rtb_segment_command *segment = (const rtb_segment_command *)command;
            if(strcmp(segment->segname, SEG_TEXT) == 0) image.slide = (intptr_t)header - (intptr_t)segment->vmaddr;
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    command = (const struct load_command *)(mh + 1);
    for(uint32_t i = 0; i < mh->ncmds; i++) {
        if(command->cmd == rtb_lc_segment) {
            const rtb_segment_command *segment = (const rtb_segment_command *)command;
            if(segment->vmsize > 0 && strcmp(segment->segname, SEG_PAGEZERO) != 0) {
                uintptr_t start = (uintptr_t)(segment->vmaddr + image.slide);
                if(start < image.start) image.start = start;
                if(start + segment->vmsize > image.end) image.end = start + segment->vmsize;
            }
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }
    if(image.start == UINTPTR_MAX) image.start = 0;
    return image;
}

static NSLock *rtb_cachesLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// dladdr() gets slow when hundreds of images are loaded, the same descriptors are asked for again and again
static RTBImage rtb_imageContainingAddress(const void *address) {
    static NSMutableDictionary *headersByAddress = nil; // NSValue(address) -> NSValue(header)
    RTBImage none = { NULL, 0, 0, 0 };
    if(address == NULL) return none;

    NSValue *key = [NSValue valueWithPointer:address];
    [rtb_cachesLock() lock];
    if(headersByAddress == nil) headersByAddress = [NSMutableDictionary dictionary];
    NSValue *cached = headersByAddress[key];
    [rtb_cachesLock() unlock];
    if(cached) return rtb_imageWithHeader([cached pointerValue]);

    Dl_info info;
    const void *header = (dladdr(address, &info) != 0) ? info.dli_fbase : NULL;
    [rtb_cachesLock() lock];
    headersByAddress[key] = [NSValue valueWithPointer:header];
    [rtb_cachesLock() unlock];
    return header ? rtb_imageWithHeader(header) : none;
}

static BOOL rtb_imageContains(const RTBImage *image, const void *p, size_t size) {
    return p != NULL && (uintptr_t)p >= image->start && (uintptr_t)p + size <= image->end;
}

// RelativeDirectPointer: the target is at field + *field, in the same image
static const void *rtb_relativePointer(const RTBImage *image, const int32_t *field, size_t targetSize) {
    if(!rtb_imageContains(image, field, sizeof(int32_t)) || *field == 0) return NULL;
    const void *target = (const uint8_t *)field + *field;
    return rtb_imageContains(image, target, targetSize) ? target : NULL;
}

// RelativeIndirectablePointer: when the low bit is set, the target is a pointer, bound by dyld, possibly to another image
static const void *rtb_relativeIndirectablePointer(const RTBImage *image, const int32_t *field) {
    if(!rtb_imageContains(image, field, sizeof(int32_t)) || *field == 0) return NULL;
    int32_t offset = *field & ~1;
    const void *target = (const uint8_t *)field + offset;
    if(*field & 1) {
        if(!rtb_imageContains(image, target, sizeof(void *))) return NULL;
        return *(const void * const *)target;
    }
    return rtb_imageContains(image, target, 1) ? target : NULL;
}

static NSString *rtb_cString(const RTBImage *image, const char *s) {
    if(s == NULL || !rtb_imageContains(image, s, 1)) return nil;
    return [NSString stringWithCString:s encoding:NSUTF8StringEncoding];
}

#pragma mark Context descriptors

/*
 struct TargetContextDescriptor { uint32_t Flags; int32_t Parent; }
   Flags: kind in the low 5 bits (Module 0, Extension 1, Anonymous 2, Protocol 3, OpaqueType 4, Class 16, Struct 17, Enum 18),
          bit 7 isGeneric, bit 6 isUnique
 struct TargetTypeContextDescriptor : Context { int32_t Name; int32_t AccessFunction; int32_t Fields; }
 struct TargetStructDescriptor      : Type { uint32_t NumFields; uint32_t FieldOffsetVectorOffset; }               (28 bytes)
 struct TargetEnumDescriptor        : Type { uint32_t NumPayloadCasesAndPayloadSizeOffset; uint32_t NumEmptyCases; } (28 bytes)
 struct TargetClassDescriptor       : Type { int32_t SuperclassType; uint32_t x2; uint32_t NumImmediateMembers; uint32_t NumFields; uint32_t FieldOffsetVectorOffset; } (44 bytes)
 struct TargetProtocolDescriptor    : Context { int32_t Name; uint32_t NumRequirementsInSignature; uint32_t NumRequirements; int32_t AssociatedTypeNames; } (24 bytes)
 struct TargetModuleContextDescriptor : Context { int32_t Name; }
 struct TargetExtensionContextDescriptor : Context { int32_t ExtendedContext; }  (12 bytes, ExtendedContext is a mangled type name)
 struct TargetAnonymousContextDescriptor : Context { }                          (8 bytes, followed by a mangled name when Flags bit 16 is set)
 The generic contexts are followed by TargetGenericContextDescriptorHeader { uint16_t NumParams; uint16_t NumRequirements; uint16_t x2; },
 which the type descriptors precede with two int32_t: InstantiationCache and DefaultInstantiationPattern.
 NumParams counts the generic parameters of the enclosing types too.
 */

typedef NS_ENUM(uint32_t, RTBContextKind) {
    RTBContextKindModule = 0,
    RTBContextKindExtension = 1,
    RTBContextKindAnonymous = 2,
    RTBContextKindProtocol = 3,
    RTBContextKindOpaqueType = 4,
    RTBContextKindClass = 16,
    RTBContextKindStruct = 17,
    RTBContextKindEnum = 18,
};

static const uint32_t *rtb_descriptorParent(const RTBImage *image, const uint32_t *descriptor, RTBImage *parentImage) {
    const uint32_t *parent = rtb_relativeIndirectablePointer(image, (const int32_t *)&descriptor[1]);
    if(parent == NULL) return NULL;
    if(rtb_imageContains(image, parent, 8)) {
        *parentImage = *image;
    } else {
        *parentImage = rtb_imageContainingAddress(parent);
        if(!rtb_imageContains(parentImage, parent, 8)) return NULL;
    }
    return parent;
}

// the Name field of the module, protocol and type descriptors
static NSString *rtb_descriptorName(const RTBImage *image, const uint32_t *descriptor) {
    if(!rtb_imageContains(image, descriptor, 12)) return nil;
    RTBContextKind kind = descriptor[0] & 0x1F;
    if(kind != RTBContextKindModule && kind != RTBContextKindProtocol && kind < RTBContextKindClass) return nil;
    return rtb_cString(image, rtb_relativePointer(image, (const int32_t *)&descriptor[2], 1));
}

static NSString *rtb_qualifiedDescriptorName(const RTBImage *image, const uint32_t *descriptor, int depth);
static NSString *rtb_mangledDescriptorName(const RTBImage *image, const uint32_t *descriptor, int depth, BOOL preferSymbols);

// The metadata of a non-generic type, from its access function. Generic types need generic arguments.
static const void *rtb_metadataForDescriptor(const RTBImage *image, const uint32_t *descriptor) {
    if(!rtb_imageContains(image, descriptor, 20)) return NULL;
    if(descriptor[0] & 0x80) return NULL; // generic
    RTBContextKind kind = descriptor[0] & 0x1F;
    if(kind != RTBContextKindClass && kind != RTBContextKindStruct && kind != RTBContextKindEnum) return NULL;
    RTBSwiftMetadataResponse (*accessor)(size_t) = (RTBSwiftMetadataResponse (*)(size_t))rtb_relativePointer(image, (const int32_t *)&descriptor[3], 4);
    if(accessor == NULL) return NULL;
    RTBSwiftMetadataResponse response = accessor(0); // MetadataRequest complete, blocking
    return response.metadata;
}

// the number of generic parameters of a context, those of the enclosing contexts included
static NSUInteger rtb_numberOfGenericParameters(const RTBImage *image, const uint32_t *descriptor) {
    if(!rtb_imageContains(image, descriptor, 8) || (descriptor[0] & 0x80) == 0) return 0;
    size_t offset = 0; // of NumParams
    switch(descriptor[0] & 0x1F) {
        case RTBContextKindClass: offset = 44 + 8; break;
        case RTBContextKindStruct: case RTBContextKindEnum: offset = 28 + 8; break;
        case RTBContextKindExtension: offset = 12; break;
        case RTBContextKindAnonymous: offset = 8; break;
        default: return 0;
    }
    const uint16_t *numParams = (const uint16_t *)((const uint8_t *)descriptor + offset);
    if(!rtb_imageContains(image, numParams, sizeof(uint16_t))) return 0;
    return *numParams;
}

// The generic parameters a type introduces, and their depth: the demangler calls the parameters of the outermost
// generic type A, B, C..., those of the types nested in it A1, B1, C1..., etc.
static NSUInteger rtb_ownGenericParameters(const RTBImage *image, const uint32_t *descriptor, NSUInteger *depth) {
    NSUInteger count = rtb_numberOfGenericParameters(image, descriptor);
    *depth = 0;
    if(count == 0) return 0;
    NSUInteger inherited = 0;
    NSUInteger previous = 0;
    RTBImage currentImage = *image;
    const uint32_t *current = descriptor;
    for(int i = 0; i < 16; i++) {
        RTBImage parentImage;
        const uint32_t *parent = rtb_descriptorParent(&currentImage, current, &parentImage);
        if(parent == NULL) break;
        currentImage = parentImage;
        current = parent;
        // the parameters of a generic function are shown on the types declared in it, its anonymous context has no name to carry them
        if((parent[0] & 0x1F) == RTBContextKindAnonymous) continue;
        NSUInteger parentCount = rtb_numberOfGenericParameters(&parentImage, parent);
        if(inherited == 0) inherited = parentCount; // the nearest generic ancestor has them all
        if(parentCount > 0 && parentCount != previous) { (*depth)++; previous = parentCount; }
    }
    return count > inherited ? count - inherited : 0;
}

static NSString *rtb_genericParameterList(NSUInteger count, NSUInteger depth) {
    NSMutableArray *names = [NSMutableArray array];
    for(NSUInteger i = 0; i < count && i < 26; i++) {
        [names addObject:depth == 0 ? [NSString stringWithFormat:@"%c", (char)('A' + i)] : [NSString stringWithFormat:@"%c%lu", (char)('A' + i), (unsigned long)depth]];
    }
    return [names count] > 0 ? [NSString stringWithFormat:@"<%@>", [names componentsJoinedByString:@", "]] : @"";
}

#pragma mark Mangled type names

// The length of a mangled type name with symbolic references: the control bytes 0x01-0x17 are followed
// by 4 bytes, the bytes 0x18-0x1F by 8 bytes.
static size_t rtb_mangledNameLength(const char *s, const RTBImage *image) {
    size_t i = 0;
    while(rtb_imageContains(image, s + i, 1)) {
        unsigned char c = (unsigned char)s[i];
        if(c == 0) return i;
        if(c >= 0x01 && c <= 0x17) i += 5;
        else if(c >= 0x18 && c <= 0x1F) i += 9;
        else i++;
    }
    return 0;
}

/*
 A mangled name found in the metadata, with the symbolic references to context descriptors (kinds 1 direct
 and 2 indirect) spelled out as text, so that the demangler can read it. nil for the other kinds of references.

 The demangler numbers the identifiers, nominal types, bound generic types, optionals and dependent member
 types it reads, and the mangled names refer back to them with substitutions, eg. AB for the second one.
 A symbolic reference counts as one, the text spelling it out as several, so the substitutions which follow
 a spelled out reference are renumbered.
 */

typedef struct {
    NSUInteger index; // the substitution index of a spelled out reference in the original mangled name
    NSUInteger extra; // the number of substitutions the spelling adds
} RTBSubstitutionShift;

typedef struct {
    RTBSubstitutionShift shifts[64];
    NSUInteger count;
} RTBSubstitutionShifts;

// the mangled name of the descriptor a symbolic reference points to, nil if unknown
static NSString *rtb_symbolicReferenceMangledName(const RTBImage *image, const char *reference) {
    unsigned char kind = (unsigned char)reference[0];
    int32_t offset;
    memcpy(&offset, reference + 1, sizeof(offset));
    const void *target = reference + 1 + offset;
    const uint32_t *descriptor = NULL;
    RTBImage descriptorImage = *image;
    if(kind == 0x01) {
        descriptor = rtb_imageContains(image, target, 8) ? target : NULL;
    } else if(rtb_imageContains(image, target, sizeof(void *))) {
        descriptor = *(const uint32_t * const *)target;
        if(!rtb_imageContains(image, descriptor, 8)) descriptorImage = rtb_imageContainingAddress(descriptor);
        if(!rtb_imageContains(&descriptorImage, descriptor, 8)) descriptor = NULL;
    }
    return descriptor ? rtb_mangledDescriptorName(&descriptorImage, descriptor, 0, NO) : nil;
}

// INDEX ::= '_' | NATURAL '_', returns the length or 0
static size_t rtb_mangledIndexLength(const char *s, size_t length) {
    size_t i = 0;
    while(i < length && s[i] >= '0' && s[i] <= '9') i++;
    return (i < length && s[i] == '_') ? i + 1 : 0;
}

// the mangled names are ASCII, anything else is garbage
static BOOL rtb_appendMangledBytes(NSMutableString *text, const char *bytes, size_t length) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:length encoding:NSASCIIStringEncoding];
    if(s == nil) return NO;
    [text appendString:s];
    return YES;
}

// GENERIC-PARAM-INDEX ::= 'z' | INDEX | 'd' INDEX INDEX, returns the length or 0
static size_t rtb_mangledGenericParameterIndexLength(const char *s, size_t length) {
    if(length == 0) return 0;
    if(s[0] == 'z') return 1;
    if(s[0] == 'd') {
        size_t depth = rtb_mangledIndexLength(s + 1, length - 1);
        if(depth == 0) return 0;
        size_t index = rtb_mangledIndexLength(s + 1 + depth, length - 1 - depth);
        return index ? 1 + depth + index : 0;
    }
    return rtb_mangledIndexLength(s, length);
}

// Copies a mangled name (a spelled out symbolic reference, or a name of the metadata when image is not NULL)
// renumbering its substitutions: base is added to the indices, and, for the names of the metadata, the number
// of substitutions the spelled out references add. Returns the number of substitutions the copied name
// creates in *created. The operators it does not know are copied and set *uncertain, the count may be off:
// the copy is unusable if substitutions had to be renumbered.
static NSString *rtb_relocatedMangledName(const RTBImage *image, const char *mangled, size_t length, NSUInteger base, RTBSubstitutionShifts *shifts, NSUInteger *created, BOOL *uncertain, int depth) {
    NSMutableString *text = [NSMutableString string];
    NSUInteger originalCount = 0; // the substitutions created so far, numbered as in the original name
    NSUInteger newCount = 0;      // numbered as in the copy
    BOOL renumbered = NO;
    if(depth > 4) return nil;

    for(size_t i = 0; i < length; ) {
        unsigned char c = (unsigned char)mangled[i];
        size_t remaining = length - i;

        if(c == 0x01 || c == 0x02) {
            if(image == NULL || remaining < 5) return nil;
            NSString *chunk = rtb_symbolicReferenceMangledName(image, mangled + i);
            if(chunk == nil) return nil;
            NSUInteger chunkCreated = 0;
            NSString *relocated = rtb_relocatedMangledName(NULL, [chunk UTF8String], [chunk lengthOfBytesUsingEncoding:NSUTF8StringEncoding], base + newCount, NULL, &chunkCreated, uncertain, depth + 1);
            if(relocated == nil || chunkCreated == 0 || shifts->count >= 64) return nil;
            shifts->shifts[shifts->count].index = originalCount;
            shifts->shifts[shifts->count].extra = chunkCreated - 1;
            shifts->count++;
            [text appendString:relocated];
            originalCount += 1;
            newCount += chunkCreated;
            i += 5;
        } else if(c < 0x20) {
            return nil; // another kind of symbolic reference
        } else if(c >= '0' && c <= '9') {
            // an identifier: NATURAL chars, or with word substitutions '0' ([a-z]* [A-Z] | NATURAL chars)* '0'?, or punycode '00' NATURAL '_'? chars
            size_t j = i;
            BOOL hasWordSubstitutions = NO, isPunycoded = NO;
            if(mangled[j] == '0') {
                j++;
                if(j < length && mangled[j] == '0') { j++; isPunycoded = YES; } else hasWordSubstitutions = YES;
            }
            do {
                while(hasWordSubstitutions && j < length && ((mangled[j] >= 'a' && mangled[j] <= 'z') || (mangled[j] >= 'A' && mangled[j] <= 'Z'))) {
                    if(mangled[j] >= 'A' && mangled[j] <= 'Z') hasWordSubstitutions = NO; // the last word
                    j++;
                }
                if(j < length && mangled[j] == '0') { j++; break; }
                size_t n = 0, digits = 0;
                while(j + digits < length && mangled[j + digits] >= '0' && mangled[j + digits] <= '9') { n = n * 10 + (mangled[j + digits] - '0'); digits++; }
                if(digits == 0 || n == 0) return nil;
                j += digits;
                if(isPunycoded && j < length && mangled[j] == '_') j++;
                if(j + n > length) return nil;
                j += n;
            } while(hasWordSubstitutions);
            if(!rtb_appendMangledBytes(text, mangled + i, j - i)) return nil;
            originalCount++; newCount++;
            i = j;
        } else if(c == 'A') {
            // substitutions: 'A' (NATURAL? [a-z])* (NATURAL? [A-Z] | NATURAL? '_')
            i++;
            NSInteger repeat = -1;
            if(base > 0 || (shifts && shifts->count > 0)) renumbered = YES;
            while(YES) {
                if(i >= length) return nil;
                char s = mangled[i++];
                NSUInteger index;
                BOOL last;
                if(s >= 'a' && s <= 'z') { index = s - 'a'; last = NO; }
                else if(s >= 'A' && s <= 'Z') { index = s - 'A'; last = YES; }
                else if(s == '_') { index = repeat + 27; last = YES; }
                else if(s >= '0' && s <= '9') {
                    repeat = s - '0';
                    while(i < length && mangled[i] >= '0' && mangled[i] <= '9') repeat = repeat * 10 + (mangled[i++] - '0');
                    continue;
                }
                else return nil;
                NSUInteger times = (s == '_' || repeat < 1) ? 1 : (NSUInteger)repeat;
                NSUInteger newIndex = index + base;
                if(shifts) for(NSUInteger k = 0; k < shifts->count; k++) if(shifts->shifts[k].index <= index) newIndex += shifts->shifts[k].extra;
                for(NSUInteger t = 0; t < times; t++) {
                    if(newIndex < 26) [text appendFormat:@"A%c", (char)('A' + newIndex)];
                    else if(newIndex == 26) [text appendString:@"A_"];
                    else [text appendFormat:@"A%lu_", (unsigned long)(newIndex - 27)];
                }
                repeat = -1;
                if(last) break;
            }
        } else if(c == 'S') {
            // standard substitutions: 'S' NATURAL? 'c'? [A-Za-z], Sg is Optional and creates a substitution
            size_t j = i + 1;
            while(j < length && mangled[j] >= '0' && mangled[j] <= '9') j++;
            if(j < length && mangled[j] == 'c') j++;
            if(j >= length) return nil;
            if(mangled[j] == 'g') { originalCount++; newCount++; }
            j++;
            if(!rtb_appendMangledBytes(text, mangled + i, j - i)) return nil;
            i = j;
        } else if(c == 'B') {
            // builtin types: 'B' [A-Za-z] with a NATURAL '_' for Bi64_, Bf32_ and Bv4_
            size_t j = i + 2;
            if(j > length) return nil;
            if(mangled[i + 1] == 'i' || mangled[i + 1] == 'f' || mangled[i + 1] == 'v') {
                size_t n = rtb_mangledIndexLength(mangled + j, length - j);
                if(n == 0) return nil;
                j += n;
            }
            if(!rtb_appendMangledBytes(text, mangled + i, j - i)) return nil;
            i = j;
        } else if(c == 'V' || c == 'C' || c == 'O' || c == 'P' || c == 'G') {
            // a nominal type, a bound generic type
            [text appendFormat:@"%c", c];
            originalCount++; newCount++;
            i++;
        } else if(c == 'Q') {
            // dependent member types, one substitution each: Qz, Qa, QZ, Qy GENERIC-PARAM-INDEX, QY GENERIC-PARAM-INDEX
            size_t j = i + 2;
            if(j > length) return nil;
            char q = mangled[i + 1];
            if(q == 'z' || q == 'a' || q == 'Z') {}
            else if(q == 'y' || q == 'Y') { size_t n = rtb_mangledGenericParameterIndexLength(mangled + j, length - j); if(n == 0) return nil; j += n; }
            else *uncertain = YES; // eg. the parameter packs
            if(!rtb_appendMangledBytes(text, mangled + i, j - i)) return nil;
            originalCount++; newCount++;
            i = j;
        } else if(c == 'q') {
            // generic parameters: q GENERIC-PARAM-INDEX
            size_t n = rtb_mangledGenericParameterIndexLength(mangled + i + 1, length - i - 1);
            if(n == 0) return nil;
            if(!rtb_appendMangledBytes(text, mangled + i, 1 + n)) return nil;
            i += 1 + n;
        } else if(c == 'X' || c == 'Y' || c == 'R' || c == 'L' || c == 'H') {
            // two letters operators without substitution: Xo unowned, XSq sugar, Ya async, Rb requirement, LL private declaration name,
            // L INDEX local declaration name, HC concrete conformance, HD INDEX dependent conformance
            size_t j = i + 2;
            if(j > length) return nil;
            if(c == 'X' && mangled[i + 1] == 'S') j++;
            if(c == 'L' && mangled[i + 1] != 'L') { j = i + 1; size_t n = rtb_mangledIndexLength(mangled + j, length - j); if(n == 0) return nil; j += n; }
            if(c == 'H') j += rtb_mangledIndexLength(mangled + j, length - j);
            if(j > length) return nil;
            if(!rtb_appendMangledBytes(text, mangled + i, j - i)) return nil;
            i = j;
        } else if(c == 'E' || c == 'K' || c == '_' || (c >= 'a' && c <= 'z')) {
            // extensions, throws, list markers, and the operators without substitution: y x t c m p s z n d ...
            [text appendFormat:@"%c", c];
            i++;
        } else if(c < 0x80) {
            // an operator we don't know, eg. the parameter packs
            [text appendFormat:@"%c", c];
            *uncertain = YES;
            i++;
        } else {
            return nil; // not a mangled name
        }
    }
    if(*uncertain && renumbered) return nil;
    *created = newCount;
    return text;
}

static NSString *rtb_spelledOutMangledName(const RTBImage *image, const char *mangled, size_t length) {
    if(mangled == NULL || length == 0) return nil;
    RTBSubstitutionShifts shifts = { {{0, 0}}, 0 };
    NSUInteger created = 0;
    BOOL uncertain = NO;
    return rtb_relocatedMangledName(image, mangled, length, 0, &shifts, &created, &uncertain, 0);
}

// Demangles a spelled out mangled name. The types in anonymous contexts are spelled as private declarations
// with a placeholder discriminator, eg. 4Node13_RTB1E59E2820LL, demangled to (Node in _RTB1E59E2820), which
// this rewrites as the runtime would: (unknown context at $1e59e2820).Node
static NSString *rtb_demangledSpelledOutName(NSString *text) {
    NSString *name = text ? rtb_swiftDemangledName([@"$s" stringByAppendingString:text]) : nil;
    if(name == nil || [name rangeOfString:@" in _RTB"].location == NSNotFound) return name;
    NSRegularExpression *placeholder = [NSRegularExpression regularExpressionWithPattern:@"\\(([^ ()]+) in _RTB([0-9A-F]+)\\)" options:0 error:nil];
    NSMutableString *ms = [name mutableCopy];
    NSArray *matches = [placeholder matchesInString:ms options:0 range:NSMakeRange(0, [ms length])];
    for(NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSString *typeName = [ms substringWithRange:[match rangeAtIndex:1]];
        NSString *address = [[ms substringWithRange:[match rangeAtIndex:2]] lowercaseString];
        [ms replaceCharactersInRange:[match range] withString:[NSString stringWithFormat:@"(unknown context at $%@).%@", address, typeName]];
    }
    return ms;
}

// The name of the type of a mangled type name found in the metadata of a type: resolved by the runtime for the
// non-generic types, else demangled after the symbolic references to other types have been spelled out.
static NSString *rtb_typeNameForMangledFieldType(const RTBImage *image, const char *mangled, const uint32_t *context, BOOL contextIsGeneric) {
    size_t length = rtb_mangledNameLength(mangled, image);
    if(length == 0) return nil;

    if(contextIsGeneric == NO && rtb_swift_getTypeByMangledNameInContext != NULL) {
        const void *metadata = rtb_swift_getTypeByMangledNameInContext(mangled, length, context, NULL);
        NSString *name = rtb_swiftTypeName(metadata);
        if(name) return name;
    }

    return rtb_demangledSpelledOutName(rtb_spelledOutMangledName(image, mangled, length));
}

// The mangled name of the type descriptor from the symbol table, eg. $s10Foundation4DateVMn -> 10Foundation4DateV,
// exact even for the private types and the types in constrained extensions. nil if the symbol was stripped.
static NSString *rtb_mangledDescriptorNameFromSymbols(const void *descriptor) {
    static NSMutableDictionary *namesByDescriptor = nil; // NSValue(descriptor) -> NSString or NSNull
    if(descriptor == NULL) return nil;

    NSValue *key = [NSValue valueWithPointer:descriptor];
    [rtb_cachesLock() lock];
    if(namesByDescriptor == nil) namesByDescriptor = [NSMutableDictionary dictionary];
    id cached = namesByDescriptor[key];
    [rtb_cachesLock() unlock];
    if(cached) return [cached isKindOfClass:[NSString class]] ? cached : nil;

    NSString *name = nil;
    Dl_info info;
    if(dladdr(descriptor, &info) != 0 && info.dli_saddr == descriptor && info.dli_sname != NULL) {
        const char *symbol = info.dli_sname;
        if(symbol[0] == '_') symbol++;
        size_t length = strlen(symbol);
        if(length >= 5 && strncmp(symbol, "$s", 2) == 0 && strcmp(symbol + length - 2, "Mn") == 0) {
            name = [[NSString alloc] initWithBytes:symbol + 2 length:length - 4 encoding:NSUTF8StringEncoding];
        }
    }
    [rtb_cachesLock() lock];
    namesByDescriptor[key] = name ? name : [NSNull null];
    [rtb_cachesLock() unlock];
    return name;
}

#pragma mark Names

// The mangled type name an extension descriptor extends, without the generic arguments, eg. 10Foundation11MeasurementV
static NSString *rtb_extendedNominalMangledName(const RTBImage *image, const uint32_t *descriptor) {
    const char *mangled = rtb_relativePointer(image, (const int32_t *)&descriptor[2], 1);
    if(mangled == NULL) return nil;
    NSString *text = rtb_spelledOutMangledName(image, mangled, rtb_mangledNameLength(mangled, image));
    if(text == nil) return nil;
    // the extended type is mangled with its own generic parameters, eg. 10Foundation11MeasurementVyxG for Measurement<A>
    NSRange y = [text rangeOfString:@"y" options:NSBackwardsSearch];
    if([text hasSuffix:@"G"] && y.location != NSNotFound) {
        NSString *arguments = [text substringWithRange:NSMakeRange(y.location + 1, [text length] - y.location - 2)];
        NSCharacterSet *parameters = [NSCharacterSet characterSetWithCharactersInString:@"xqd_0123456789"];
        if([[arguments stringByTrimmingCharactersInSet:parameters] length] == 0) text = [text substringToIndex:y.location];
    }
    return text;
}

// The name of the extended type of an extension descriptor, eg. Foundation.Measurement<A>
static NSString *rtb_extendedTypeName(const RTBImage *image, const uint32_t *descriptor) {
    const char *mangled = rtb_relativePointer(image, (const int32_t *)&descriptor[2], 1);
    if(mangled == NULL) return nil;
    return rtb_demangledSpelledOutName(rtb_spelledOutMangledName(image, mangled, rtb_mangledNameLength(mangled, image)));
}

// The mangled private name an anonymous context has when the compiler emitted it, eg. 10CodingKeys33_084732462020271F9F243453D5A4FAFELL
static NSString *rtb_anonymousContextMangledName(const RTBImage *image, const uint32_t *descriptor) {
    if(!rtb_imageContains(image, descriptor, 12) || (descriptor[0] & (1 << 16)) == 0) return nil; // no mangled name
    if(descriptor[0] & 0x80) return nil; // the mangled name follows the generic context, whose size depends on the runtime version
    const char *mangled = rtb_relativePointer(image, (const int32_t *)&descriptor[2], 1);
    if(mangled == NULL) return nil;
    return rtb_spelledOutMangledName(image, mangled, rtb_mangledNameLength(mangled, image));
}

// The private name of the type in an anonymous context, when the compiler emitted it, eg. (CodingKeys in _084732462020271F9F243453D5A4FAFE)
static NSString *rtb_anonymousContextName(const RTBImage *image, const uint32_t *descriptor) {
    return rtb_demangledSpelledOutName(rtb_anonymousContextMangledName(image, descriptor));
}

// The name of a context as the Swift runtime and demangler write it: Module.Outer.Name<A>, (extension in Module):Extended.Name,
// Module.(unknown context at $1234).Name, Module.(Name in _HASH).
static NSString *rtb_qualifiedDescriptorName(const RTBImage *image, const uint32_t *descriptor, int depth) {
    if(depth > 16 || !rtb_imageContains(image, descriptor, 8)) return nil;
    RTBContextKind kind = descriptor[0] & 0x1F;

    RTBImage parentImage;
    const uint32_t *parent = rtb_descriptorParent(image, descriptor, &parentImage);
    NSString *parentName = parent ? rtb_qualifiedDescriptorName(&parentImage, parent, depth + 1) : nil;

    if(kind == RTBContextKindModule) {
        return rtb_descriptorName(image, descriptor);
    }
    if(kind == RTBContextKindExtension) {
        NSString *extended = rtb_extendedTypeName(image, descriptor);
        return [NSString stringWithFormat:@"(extension in %@):%@", parentName ? parentName : @"?", extended ? extended : @"?"];
    }
    if(kind == RTBContextKindAnonymous || kind == RTBContextKindOpaqueType) {
        NSString *name = kind == RTBContextKindAnonymous ? rtb_anonymousContextName(image, descriptor) : nil;
        if(name == nil) name = [NSString stringWithFormat:@"(unknown context at $%lx)", (unsigned long)descriptor];
        return parentName ? [NSString stringWithFormat:@"%@.%@", parentName, name] : name;
    }

    NSString *name = rtb_descriptorName(image, descriptor);
    if(name == nil) return nil;
    // a private type: the parent already reads (Name in _HASH)
    if(parentName && [[[parentName componentsSeparatedByString:@"."] lastObject] hasPrefix:[NSString stringWithFormat:@"(%@ in _", name]]) return parentName;
    if(descriptor[0] & 0x80) {
        NSUInteger genericDepth = 0;
        NSUInteger count = rtb_ownGenericParameters(image, descriptor, &genericDepth);
        name = [name stringByAppendingString:rtb_genericParameterList(count, genericDepth)];
    }
    return parentName ? [NSString stringWithFormat:@"%@.%@", parentName, name] : name;
}

// The mangled nominal type name of a descriptor: <len>Module<len>Name + kind letter, nested types included,
// eg. 10Foundation4DateV, SS10FoundationE8EncodingV for a type in an extension.
// The names spelled from the descriptors lack the requirements of the constrained extensions and the discriminators
// of the private types, which the demangler doesn't need to name the types but the symbol table has: the symbols
// are preferred to find the members of a type, the spelled names to display the types.
static NSString *rtb_mangledDescriptorName(const RTBImage *image, const uint32_t *descriptor, int depth, BOOL preferSymbols) {
    if(depth > 16 || !rtb_imageContains(image, descriptor, 8)) return nil;
    RTBContextKind kind = descriptor[0] & 0x1F;
    NSString *letter = nil;
    switch(kind) {
        case RTBContextKindModule: letter = @""; break;
        case RTBContextKindExtension: letter = @"E"; break;
        case RTBContextKindClass: letter = @"C"; break;
        case RTBContextKindStruct: letter = @"V"; break;
        case RTBContextKindEnum: letter = @"O"; break;
        case RTBContextKindProtocol: letter = @"P"; break;
        default: return nil; // anonymous and opaque contexts
    }
    BOOL isNominal = kind != RTBContextKindModule && kind != RTBContextKindExtension;
    if(isNominal && preferSymbols) {
        NSString *symbolName = rtb_mangledDescriptorNameFromSymbols(descriptor);
        if(symbolName) return symbolName;
    }

    RTBImage parentImage;
    const uint32_t *parent = rtb_descriptorParent(image, descriptor, &parentImage);
    NSString *privateName = nil; // <name><discriminator>LL, for the types in anonymous contexts
    if(parent && (parent[0] & 0x1F) == RTBContextKindAnonymous && isNominal) {
        NSString *name = rtb_descriptorName(image, descriptor);
        if([name length] == 0) return nil;
        NSString *identifier = [NSString stringWithFormat:@"%lu%@", (unsigned long)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], name];
        NSString *anonymousMangled = rtb_anonymousContextMangledName(&parentImage, parent); // the private name of the type when the compiler emitted it
        if([anonymousMangled hasPrefix:identifier] && [anonymousMangled hasSuffix:@"LL"]) {
            privateName = anonymousMangled;
        } else {
            // no discriminator in the metadata: a placeholder with the address of the anonymous context, see rtb_demangledSpelledOutName()
            NSString *discriminator = [NSString stringWithFormat:@"_RTB%lX", (unsigned long)parent];
            privateName = [NSString stringWithFormat:@"%@%lu%@LL", identifier, (unsigned long)[discriminator length], discriminator];
        }
        RTBImage grandParentImage;
        parent = rtb_descriptorParent(&parentImage, parent, &grandParentImage);
        parentImage = grandParentImage;
    }
    NSString *parentMangled = parent ? rtb_mangledDescriptorName(&parentImage, parent, depth + 1, preferSymbols) : nil;
    if(parentMangled == nil && isNominal && preferSymbols == NO) return rtb_mangledDescriptorNameFromSymbols(descriptor); // eg. a type in an opaque context

    if(kind == RTBContextKindModule) {
        NSString *name = rtb_descriptorName(image, descriptor);
        if([name length] == 0) return nil;
        // the standard library and the Objective-C module have short mangling
        if([name isEqualToString:@"Swift"]) return @"s";
        if([name isEqualToString:@"__C"]) return @"So";
        return [NSString stringWithFormat:@"%lu%@", (unsigned long)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], name];
    }
    if(parentMangled == nil) return nil;
    if(kind == RTBContextKindExtension) {
        // <extended type><module>E
        NSString *extended = rtb_extendedNominalMangledName(image, descriptor);
        return extended ? [NSString stringWithFormat:@"%@%@E", extended, parentMangled] : nil;
    }
    if(privateName) return [NSString stringWithFormat:@"%@%@%@", parentMangled, privateName, letter];
    NSString *name = rtb_descriptorName(image, descriptor);
    if([name length] == 0) return nil;
    return [NSString stringWithFormat:@"%@%lu%@%@", parentMangled, (unsigned long)[name lengthOfBytesUsingEncoding:NSUTF8StringEncoding], name, letter];
}

#pragma mark - RTBSwiftType

@interface RTBSwiftTypes ()
+ (NSArray *)conformancesOfDescriptor:(const void *)descriptor;
@end

@interface RTBSwiftType ()
@property (nonatomic, retain) NSString *name;
@property (nonatomic) RTBSwiftTypeKind kind;
@property (nonatomic, retain) NSString *imagePath;
@property (nonatomic) BOOL isGeneric;
@property (nonatomic) const uint32_t *descriptor;
@property (nonatomic) RTBImage image;
@property (nonatomic) const void *metadata;         // non-generic structs, enums and classes
@property (nonatomic, retain) NSString *cachedMangledName; // nominal, for the symbols
@property (nonatomic, retain) NSString *cachedDeclaration;
@end

@implementation RTBSwiftType

- (NSString *)kindName {
    switch(_kind) {
        case RTBSwiftTypeKindStruct: return @"struct";
        case RTBSwiftTypeKindEnum: return @"enum";
        case RTBSwiftTypeKindClass: return @"class";
        case RTBSwiftTypeKindProtocol: return @"protocol";
    }
    return @"?";
}

- (NSComparisonResult)compare:(RTBSwiftType *)other {
    return [_name compare:other.name];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ %@", [self kindName], _name];
}

#pragma mark Fields, cases and requirements

// the fields of a struct or class, the cases of an enum, from the field descriptor:
// FieldDescriptor { int32 MangledTypeName; int32 Superclass; uint16 Kind; uint16 FieldRecordSize; uint32 NumFields; FieldRecord[] { uint32 Flags; int32 MangledTypeName; int32 FieldName; } }
- (NSArray *)fieldLines {
    NSMutableArray *lines = [NSMutableArray array];
    const RTBImage *image = &_image;

    const uint32_t *fieldDescriptor = rtb_relativePointer(image, (const int32_t *)&_descriptor[4], 16);
    if(fieldDescriptor == NULL) return lines;
    uint16_t recordSize = *(const uint16_t *)((const uint8_t *)fieldDescriptor + 10);
    uint32_t numFields = fieldDescriptor[3];
    if(recordSize != 12 || numFields > 10000) return lines;
    if(!rtb_imageContains(image, fieldDescriptor, 16 + (size_t)numFields * recordSize)) return lines;

    // the runtime knows the fields of the non-generic structs and classes best, when it has records for them:
    // the imported C++ structs declare stored properties without records, the runtime would read past the field descriptor
    if(_metadata && _kind != RTBSwiftTypeKindEnum && rtb_swift_reflectionMirror_recursiveCount && rtb_swift_reflectionMirror_recursiveChildMetadata) {
        intptr_t count = rtb_swift_reflectionMirror_recursiveCount(_metadata);
        if(count >= 0 && count <= numFields) {
            for(intptr_t i = 0; i < count; i++) {
                RTBSwiftFieldReflectionMetadata fieldMetadata = {0};
                const void *fieldType = rtb_swift_reflectionMirror_recursiveChildMetadata(_metadata, i, &fieldMetadata, &fieldMetadata.freeFunc);
                if(fieldMetadata.name == NULL) continue;
                NSString *type = rtb_swiftTypeName(fieldType);
                [lines addObject:[NSString stringWithFormat:@"    %@ %s: %@", fieldMetadata.isVar ? @"var" : @"let", fieldMetadata.name, type ? [RTBSwift displayedTypeNamesInString:type] : @"?"]];
                if(fieldMetadata.freeFunc) fieldMetadata.freeFunc(fieldMetadata.name);
            }
            return lines;
        }
    }

    for(uint32_t i = 0; i < numFields; i++) {
        const int32_t *record = (const int32_t *)((const uint8_t *)fieldDescriptor + 16 + i * recordSize);
        uint32_t flags = (uint32_t)record[0]; // 1: indirect case, 2: var
        const char *mangledType = rtb_relativePointer(image, &record[1], 1);
        NSString *name = rtb_cString(image, rtb_relativePointer(image, &record[2], 1));
        if(name == nil) continue;
        NSString *type = mangledType ? rtb_typeNameForMangledFieldType(image, mangledType, _descriptor, _isGeneric) : nil;
        if(mangledType && type) type = [RTBSwift displayedTypeNamesInString:type];
        if(_kind == RTBSwiftTypeKindEnum) {
            NSString *payload = mangledType ? [NSString stringWithFormat:@"(%@)", type ? type : @"?"] : @"";
            [lines addObject:[NSString stringWithFormat:@"    %@case %@%@", (flags & 1) ? @"indirect " : @"", name, payload]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"    %@ %@: %@", (flags & 2) ? @"var" : @"let", name, type ? type : @"?"]];
        }
    }
    return lines;
}

// the protocols a protocol inherits from, and its associated types
- (void)getInheritedProtocols:(NSArray **)inheritedProtocols associatedTypes:(NSArray **)associatedTypes {
    NSMutableArray *inherited = [NSMutableArray array];
    NSMutableArray *associated = [NSMutableArray array];
    *inheritedProtocols = inherited;
    *associatedTypes = associated;
    const RTBImage *image = &_image;
    if(!rtb_imageContains(image, _descriptor, 24)) return;

    // AssociatedTypeNames: the names separated by spaces
    NSString *names = rtb_cString(image, rtb_relativePointer(image, (const int32_t *)&_descriptor[5], 1));
    for(NSString *name in [names componentsSeparatedByString:@" "]) {
        if([name length] > 0) [associated addObject:name];
    }

    // the requirement signature: GenericRequirementDescriptor[NumRequirementsInSignature] { uint32 Flags; int32 Param; int32 Protocol/Type }
    // the requirements on Self ("x") of kind Protocol are the inherited protocols
    uint32_t numRequirements = _descriptor[3];
    if(numRequirements > 1000) return;
    const int32_t *requirements = (const int32_t *)((const uint8_t *)_descriptor + 24);
    if(!rtb_imageContains(image, requirements, (size_t)numRequirements * 12)) return;
    for(uint32_t i = 0; i < numRequirements; i++) {
        const int32_t *requirement = requirements + i * 3;
        uint32_t flags = (uint32_t)requirement[0];
        if((flags & 0x1F) != 0) continue; // kind Protocol
        NSString *param = rtb_cString(image, rtb_relativePointer(image, &requirement[1], 1));
        if([param isEqualToString:@"x"] == NO) continue; // Self
        // RelativeIndirectablePointerIntPair: bit 0 indirect, bit 1 the protocol is an Objective-C protocol
        int32_t value = requirement[2];
        BOOL isObjC = (value & 2) != 0;
        int32_t offset = value & ~3;
        const void *target = (const uint8_t *)&requirement[2] + offset;
        if(!rtb_imageContains(image, target, sizeof(void *))) continue;
        if(value & 1) target = *(const void * const *)target;
        if(target == NULL) continue;
        NSString *protocolName = nil;
        if(isObjC) {
            protocolName = [NSString stringWithCString:protocol_getName((__bridge Protocol *)target) encoding:NSUTF8StringEncoding];
        } else {
            RTBImage protocolImage = rtb_imageContains(image, target, 8) ? *image : rtb_imageContainingAddress(target);
            protocolName = rtb_qualifiedDescriptorName(&protocolImage, target, 0);
        }
        if(protocolName && [inherited containsObject:protocolName] == NO) [inherited addObject:protocolName];
    }
}

// the mangled nominal name, for the symbols
- (NSString *)mangledName {
    if(_cachedMangledName == nil) {
        NSString *mangledName = _metadata ? rtb_swiftMangledNominalTypeName(_metadata) : nil;
        if(mangledName == nil) mangledName = rtb_mangledDescriptorName(&_image, _descriptor, 0, YES);
        _cachedMangledName = mangledName ? mangledName : @"";
    }
    return [_cachedMangledName length] > 0 ? _cachedMangledName : nil;
}

- (NSArray *)members {
    NSString *mangledName = [self mangledName];
    if(mangledName == nil) return @[];
    return rtb_swiftSortedMembers(_name, mangledName, _image.header);
}

- (NSString *)declaration {
    if(_cachedDeclaration) return _cachedDeclaration;

    NSMutableString *header = [NSMutableString string];
    [header appendFormat:@"/* Generated by RuntimeBrowser\n   Image: %@\n */\n\n", _imagePath];

    NSString *displayedName = [RTBSwift displayedTypeNamesInString:_name];

    NSMutableArray *inheritance = [NSMutableArray array];
    NSArray *associatedTypes = @[];
    if(_kind == RTBSwiftTypeKindProtocol) {
        NSArray *inheritedProtocols = nil;
        [self getInheritedProtocols:&inheritedProtocols associatedTypes:&associatedTypes];
        [inheritance addObjectsFromArray:inheritedProtocols];
    } else {
        [inheritance addObjectsFromArray:[RTBSwiftTypes conformancesOfDescriptor:_descriptor]];
    }
    NSMutableArray *displayedInheritance = [NSMutableArray array];
    for(NSString *s in inheritance) [displayedInheritance addObject:[RTBSwift displayedTypeNamesInString:s]];

    [header appendFormat:@"%@ %@", [self kindName], displayedName];
    if([displayedInheritance count] > 0) [header appendFormat:@": %@", [displayedInheritance componentsJoinedByString:@", "]];
    [header appendString:@" {\n"];

    for(NSString *name in associatedTypes) {
        [header appendFormat:@"    associatedtype %@\n", name];
    }
    NSArray *fieldLines = _kind == RTBSwiftTypeKindProtocol ? @[] : [self fieldLines];
    for(NSString *line in fieldLines) {
        [header appendFormat:@"%@\n", line];
    }
    [header appendString:@"}\n"];

    NSArray *members = [self members];
    if([members count] > 0) {
        [header appendString:@"\n// members, from the symbol table (stripped members are missing)\n\n"];
        for(NSString *member in members) {
            [header appendFormat:@"%@\n", [RTBSwift displayedTypeNamesInString:member]];
        }
    }

    self.cachedDeclaration = header;
    return header;
}

#pragma mark BrowserNode protocol

- (NSArray *)children {
    return @[];
}

- (NSString *)nodeName {
    return [NSString stringWithFormat:@"%@ %@", [self kindName], [RTBSwift displayedTypeNamesInString:_name]];
}

- (NSString *)nodeInfo {
    return [self nodeName];
}

- (BOOL)canBeSavedAsHeader {
    return YES; // the declaration
}

@end

#pragma mark - RTBSwiftTypes

@implementation RTBSwiftTypes

+ (NSLock *)lock {
    static NSLock *lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [[NSLock alloc] init]; }); // not rtb_cachesLock(), which the callees take
    return lock;
}

// the types of an image, all kinds, by descriptor address
+ (NSArray *)allTypesInImage:(RTBImage)image path:(NSString *)imagePath {
    NSMutableArray *types = [NSMutableArray array];
    if(image.header == NULL) return types;

    rtb_loadSwiftRuntime();

    unsigned long typesSize = 0, protocolsSize = 0;
    const int32_t *records = (const int32_t *)getsectiondata((const rtb_mach_header *)image.header, "__TEXT", "__swift5_types", &typesSize);
    const int32_t *protocols = (const int32_t *)getsectiondata((const rtb_mach_header *)image.header, "__TEXT", "__swift5_protos", &protocolsSize);

    NSMutableArray *descriptors = [NSMutableArray array];
    for(unsigned long i = 0; records && i < typesSize / sizeof(int32_t); i++) {
        const uint32_t *descriptor = rtb_relativePointer(&image, &records[i], 20);
        if(descriptor) [descriptors addObject:[NSValue valueWithPointer:descriptor]];
    }
    for(unsigned long i = 0; protocols && i < protocolsSize / sizeof(int32_t); i++) {
        const uint32_t *descriptor = rtb_relativePointer(&image, &protocols[i], 24);
        if(descriptor) [descriptors addObject:[NSValue valueWithPointer:descriptor]];
    }

    for(NSValue *v in descriptors) {
        const uint32_t *descriptor = [v pointerValue];
        RTBContextKind contextKind = descriptor[0] & 0x1F;
        RTBSwiftTypeKind kind;
        switch(contextKind) {
            case RTBContextKindStruct: kind = RTBSwiftTypeKindStruct; break;
            case RTBContextKindEnum: kind = RTBSwiftTypeKindEnum; break;
            case RTBContextKindClass: kind = RTBSwiftTypeKindClass; break;
            case RTBContextKindProtocol: kind = RTBSwiftTypeKindProtocol; break;
            default: continue;
        }

        RTBSwiftType *type = [[RTBSwiftType alloc] init];
        type.kind = kind;
        type.imagePath = imagePath;
        type.descriptor = descriptor;
        type.image = image;
        type.isGeneric = (descriptor[0] & 0x80) != 0;
        type.metadata = kind == RTBSwiftTypeKindClass ? NULL : rtb_metadataForDescriptor(&image, descriptor); // the classes are known to the Objective-C runtime

        NSString *name = type.metadata ? rtb_swiftTypeName(type.metadata) : nil;
        if(name == nil) name = rtb_qualifiedDescriptorName(&image, descriptor, 0);
        if(name == nil) continue;
        type.name = name;

        [types addObject:type];
    }
    return types;
}

+ (const struct mach_header *)headerOfImageAtPath:(NSString *)imagePath {
    const char *path = [imagePath fileSystemRepresentation];
    if(path == NULL) return NULL;
    for(uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if(name && strcmp(name, path) == 0) return _dyld_get_image_header(i);
    }
    return NULL;
}

+ (BOOL)imageAtPathHasSwiftTypes:(NSString *)imagePath {
    const struct mach_header *header = [self headerOfImageAtPath:imagePath];
    if(header == NULL) return NO;
    unsigned long size = 0;
    return getsectiondata((const rtb_mach_header *)header, "__TEXT", "__swift5_types", &size) != NULL || getsectiondata((const rtb_mach_header *)header, "__TEXT", "__swift5_protos", &size) != NULL;
}

+ (NSArray *)typesInImageAtPath:(NSString *)imagePath {
    static NSMutableDictionary *typesByImagePath = nil;

    [[self lock] lock];
    if(typesByImagePath == nil) typesByImagePath = [NSMutableDictionary dictionary];
    NSArray *cached = typesByImagePath[imagePath];
    [[self lock] unlock];
    if(cached) return cached;

    NSMutableArray *types = [NSMutableArray array];
    const struct mach_header *header = [self headerOfImageAtPath:imagePath];
    if(header) {
        for(RTBSwiftType *type in [self allTypesInImage:rtb_imageWithHeader(header) path:imagePath]) {
            if(type.kind == RTBSwiftTypeKindClass) continue; // the classes are in the class browser
            [types addObject:type];
        }
    }
    [types sortUsingSelector:@selector(compare:)];

    [[self lock] lock];
    typesByImagePath[imagePath] = types;
    [[self lock] unlock];

    return types;
}

+ (RTBSwiftType *)typeNamed:(NSString *)name {
    for(uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *imageName = _dyld_get_image_name(i);
        if(imageName == NULL) continue;
        for(RTBSwiftType *type in [self typesInImageAtPath:[NSString stringWithUTF8String:imageName]]) {
            if([type.name isEqualToString:name]) return type;
        }
    }
    return nil;
}

#pragma mark Conformances

/*
 struct TargetProtocolConformanceDescriptor { int32_t Protocol; int32_t TypeRef; int32_t WitnessTablePattern; uint32_t Flags; }
   Flags bits 3-5: the kind of TypeRef: 0 direct type descriptor, 1 indirect type descriptor, 2 Objective-C class name, 3 indirect Objective-C class
 */

// protocol names by type descriptor address, Objective-C class name and class pointer, from all the loaded images
+ (NSDictionary *)conformanceIndex {
    static NSDictionary *index = nil;
    static uint32_t indexedImageCount = 0;

    [[self lock] lock];
    uint32_t imageCount = _dyld_image_count();
    if(index == nil || indexedImageCount != imageCount) {
        NSMutableDictionary *newIndex = [NSMutableDictionary dictionary]; // NSValue(descriptor) or NSString(class name) -> NSMutableArray of protocol names
        rtb_loadSwiftRuntime();
        for(uint32_t i = 0; i < imageCount; i++) {
            RTBImage image = rtb_imageWithHeader(_dyld_get_image_header(i));
            if(image.header == NULL) continue;
            unsigned long size = 0;
            const int32_t *records = (const int32_t *)getsectiondata((const rtb_mach_header *)image.header, "__TEXT", "__swift5_proto", &size);
            for(unsigned long r = 0; records && r < size / sizeof(int32_t); r++) {
                const int32_t *conformance = rtb_relativePointer(&image, &records[r], 16);
                if(conformance == NULL) continue;

                const void *protocolDescriptor = rtb_relativeIndirectablePointer(&image, &conformance[0]);
                if(protocolDescriptor == NULL) continue;
                RTBImage protocolImage = rtb_imageContains(&image, protocolDescriptor, 8) ? image : rtb_imageContainingAddress(protocolDescriptor);
                NSString *protocolName = rtb_qualifiedDescriptorName(&protocolImage, protocolDescriptor, 0);
                if(protocolName == nil) continue;

                uint32_t flags = (uint32_t)conformance[3];
                uint32_t referenceKind = (flags >> 3) & 0x7;
                id key = nil;
                if(referenceKind == 0) {
                    const void *descriptor = rtb_relativePointer(&image, &conformance[1], 8);
                    if(descriptor) key = [NSValue valueWithPointer:descriptor];
                } else if(referenceKind == 1) {
                    const void * const *slot = rtb_relativePointer(&image, &conformance[1], sizeof(void *));
                    if(slot && *slot) key = [NSValue valueWithPointer:*slot];
                } else if(referenceKind == 2) {
                    key = rtb_cString(&image, rtb_relativePointer(&image, &conformance[1], 1));
                } else if(referenceKind == 3) {
                    const void * const *slot = rtb_relativePointer(&image, &conformance[1], sizeof(void *));
                    if(slot && *slot) key = [NSString stringWithUTF8String:class_getName((__bridge Class)*slot)];
                }
                if(key == nil) continue;

                NSMutableArray *names = newIndex[key];
                if(names == nil) { names = [NSMutableArray array]; newIndex[key] = names; }
                if([names containsObject:protocolName] == NO) [names addObject:protocolName];
            }
        }
        for(NSMutableArray *names in [newIndex allValues]) [names sortUsingSelector:@selector(compare:)];
        index = newIndex;
        indexedImageCount = imageCount;
    }
    NSDictionary *result = index;
    [[self lock] unlock];
    return result;
}

+ (NSArray *)conformancesOfDescriptor:(const void *)descriptor {
    if(descriptor == NULL) return @[];
    NSArray *names = [self conformanceIndex][[NSValue valueWithPointer:descriptor]];
    return names ? names : @[];
}

+ (NSArray *)conformancesOfClass:(Class)klass {
    if(klass == Nil) return @[];
    NSDictionary *index = [self conformanceIndex];
    NSMutableArray *names = [NSMutableArray array];

    // Swift classes: by their descriptor
    if([RTBSwift classHasSwiftMetadata:klass]) {
        const void *descriptor = *(const void * const *)((const uint8_t *)(__bridge const void *)klass + 5 * sizeof(void *) + 24); // see TargetClassMetadata
        for(NSString *name in index[[NSValue valueWithPointer:descriptor]]) if([names containsObject:name] == NO) [names addObject:name];
    }
    // Objective-C classes with Swift extensions: by name
    NSString *className = NSStringFromClass(klass);
    for(NSString *name in index[className]) if([names containsObject:name] == NO) [names addObject:name];

    [names sortUsingSelector:@selector(compare:)];
    return names;
}

@end
