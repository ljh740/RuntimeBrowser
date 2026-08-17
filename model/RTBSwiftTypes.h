//
//  RTBSwiftTypes.h
//  RuntimeBrowser
//
//  The Swift types that never enter the Objective-C runtime: structs, enums and protocols,
//  and the Swift protocol conformances, read from the Swift metadata sections of the loaded
//  images (__swift5_types, __swift5_protos, __swift5_proto).
//
//  See RTBSwift.h for the Swift classes, which are visible in the Objective-C runtime.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, RTBSwiftTypeKind) {
    RTBSwiftTypeKindStruct,
    RTBSwiftTypeKindEnum,
    RTBSwiftTypeKindClass,
    RTBSwiftTypeKindProtocol,
};

@interface RTBSwiftType : NSObject

@property (nonatomic, readonly) NSString *name;      // qualified, eg. Foundation.Date, Swift.Optional<A>
@property (nonatomic, readonly) RTBSwiftTypeKind kind;
@property (nonatomic, readonly) NSString *kindName;  // struct, enum, class, protocol
@property (nonatomic, readonly) NSString *imagePath;
@property (nonatomic, readonly) BOOL isGeneric;

// The Swift declaration of the type, as a header: members, cases, conformances, ...
- (NSString *)declaration;

// YES if the declaration contains the string, case insensitive
- (BOOL)containsSearchString:(NSString *)searchString;

- (NSComparisonResult)compare:(RTBSwiftType *)other;

// BrowserNode protocol, for the macOS browser
- (NSArray *)children;   // none
- (NSString *)nodeName;  // eg. struct Foundation.Date
- (NSString *)nodeInfo;
- (BOOL)canBeSavedAsHeader;

@end

@interface RTBSwiftTypes : NSObject

// YES if the image has Swift type metadata. Cheap, unlike typesInImageAtPath: which reads it.
+ (BOOL)imageAtPathHasSwiftTypes:(NSString *)imagePath;

// The paths of the loaded images with Swift type metadata
+ (NSArray *)imagePathsWithSwiftTypes;

// The structs, enums and protocols of an image, sorted by name. The classes are in the class browser.
+ (NSArray *)typesInImageAtPath:(NSString *)imagePath;

// The type of any loaded image with this qualified name, nil if none
+ (RTBSwiftType *)typeNamed:(NSString *)name;

// The Swift protocols a class conforms to, from the conformance records of the loaded images,
// for Swift classes as well as for Objective-C classes with Swift extensions, eg. Swift.Hashable
+ (NSArray *)conformancesOfClass:(Class)klass;

@end
