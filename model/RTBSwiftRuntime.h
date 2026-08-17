//
//  RTBSwiftRuntime.h
//  RuntimeBrowser
//
//  Private: the Swift runtime entry points and helpers shared by RTBSwift and RTBSwiftTypes.
//  Resolved with dlsym(), we don't link against libswiftCore.dylib. They are SWIFT_CC(swift)
//  functions, which for these signatures is compatible with the C calling convention on
//  arm64 and x86_64.
//

#import <Foundation/Foundation.h>

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

typedef struct {
    const void *metadata;
    size_t state;
} RTBSwiftMetadataResponse;

extern char *(*rtb_swift_demangle)(const char *mangledName, size_t mangledNameLength, char *outputBuffer, size_t *outputBufferSize, uint32_t flags);
extern RTBSwiftTypeNamePair (*rtb_swift_getTypeName)(const void *type, bool qualified);
extern RTBSwiftTypeNamePair (*rtb_swift_getMangledTypeName)(const void *type);
extern intptr_t (*rtb_swift_reflectionMirror_recursiveCount)(const void *type);
extern const void *(*rtb_swift_reflectionMirror_recursiveChildMetadata)(const void *type, intptr_t index, RTBSwiftFieldReflectionMetadata *outMetadata, void (**outFreeFunc)(const char *));
extern const void *(*rtb_swift_getTypeByMangledNameInContext)(const char *typeNameStart, size_t typeNameLength, const void *context, const void * const *genericArgs);

// dlsym() everything, once
void rtb_loadSwiftRuntime(void);

// swift_demangle(), nil if not a mangled name
NSString *rtb_swiftDemangledName(NSString *mangledName);

// swift_getTypeName(metadata, qualified: true), nil if unavailable
NSString *rtb_swiftTypeName(const void *metadata);

// The mangled name of the type without the generic arguments, eg. 7SwiftUI17AccessibilityNodeC, nil if unavailable
NSString *rtb_swiftMangledNominalTypeName(const void *metadata);

// The Swift symbols of the image whose name starts with prefix, sorted (index built once per image)
NSArray *rtb_swiftSymbolNamesWithPrefix(const void *imageBase, NSString *prefix);

// The members of a type from the symbols of its image, as sorted Swift declarations, see RTBSwift +sortedMembersOfClass:
NSArray *rtb_swiftSortedMembers(NSString *typeName, NSString *mangledNominalName, const void *imageBase);
