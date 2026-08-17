//
//  RTBSwift.h
//  RuntimeBrowser
//
//  What the Swift runtime and the symbol tables tell about the Swift classes
//  registered in the Objective-C runtime.
//
//  Swift classes are visible in the Objective-C runtime, but with mangled names,
//  no type encoding for their Swift-only ivars, and only their @objc members.
//  We don't link against libswiftCore.dylib, its entry points are resolved with dlsym().
//

#import <Foundation/Foundation.h>

@interface RTBSwift : NSObject

// YES for a class compiled with the stable Swift ABI (Swift 5), whose metadata can be read.
+ (BOOL)classHasSwiftMetadata:(Class)klass;

// YES for Swift classes: stable ABI, pre-stable ABI, or a Swift-looking name (_TtC..., Module.Name).
+ (BOOL)isSwiftClass:(Class)klass;

// The qualified Swift name of a class, eg. Foundation.__NSSwiftData or (extension in Foundation):__C.NSTimer.TimerPublisher.
// nil for non-Swift classes and for pre-stable ABI classes whose name cannot be demangled.
+ (NSString *)nameOfClass:(Class)klass;

// swift_demangle(), nil if not a mangled name, eg. Module.ClassName.
+ (NSString *)demangledName:(NSString *)mangledName;

// The stored properties declared by the class (not by its superclasses), from the reflection metadata:
// name -> @{@"type": qualified Swift type name, @"isVar": bool, @"isStrong": bool}
// Empty when the class has no Swift metadata, when its reflection metadata was stripped, or when the runtime is too old (Swift 5.2+).
+ (NSDictionary *)fieldsByNameOfClass:(Class)klass;

// The Swift members of the class, recovered from the symbol table of its image, as sorted Swift declarations,
// eg. "init(name: Swift.String)", "func run() -> ()", "var name: Swift.String { get set }".
// Public members always have exported symbols (dispatch thunks and method descriptors), the internal ones only in non-stripped images.
+ (NSArray *)sortedMembersOfClass:(Class)klass;

// "Module.Foo.bar(Swift.Int) -> ()" with typeName "Module.Foo" -> "func bar(Swift.Int) -> ()", nil if the symbol is not a member of typeName.
+ (NSString *)declarationForDemangledSymbol:(NSString *)symbol typeName:(NSString *)typeName;

// The Swift sugar for the type names found in a string: Swift.Optional<Swift.String> -> String?, Swift.Array<X> -> [X],
// Swift.Dictionary<K, V> -> [K: V], and the Swift. and __C. module prefixes are dropped.
+ (NSString *)simplifiedTypeNamesInString:(NSString *)string;

// The RTBSimplifiedSwiftTypes user default: whether the headers show the simplified type names.
+ (BOOL)simplifiesTypeNames;
+ (NSString *)displayedTypeNamesInString:(NSString *)string; // simplified or not, according to the user default

@end
