//
//  UnitTests.m
//  UnitTests
//
//  Created by Nicolas Seriot on 02/04/15.
//
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import <simd/simd.h>
#import "RTBTypeDecoder.h"
#import "RTBRuntimeHeader.h"
#import "RTBClass.h"
#import "RTBProtocol.h"
#import "RTBSwift.h"
#import "RTBCategories.h"
#import "RTBMethod.h"

#define UNIT_TESTS 1

// BOOL is bool on arm64 and a signed char elsewhere, the decoder follows the platform
#if OBJC_BOOL_IS_BOOL
#define RTB_BOOL_TYPE @"BOOL"
#define RTB_CHAR_TYPE @"char"
#else
#define RTB_BOOL_TYPE @"bool"
#define RTB_CHAR_TYPE @"BOOL"
#endif

#pragma mark - Fixtures for the modern Objective-C runtime features

@protocol RTBTestProtocol <NSObject>
@required
@property (nonatomic, readonly) NSInteger requiredInstanceProperty;
@property (class, nonatomic, readonly) NSString *requiredClassProperty;
- (void)fetchWithCompletion:(void (^)(NSData *data, NSError *error))completion;
- (void)nestedBlock:(void (^)(BOOL (^inner)(NSString *)))block;
- (id<NSCopying, NSCoding>)qualifiedObject:(NSObject<NSCopying> *)object;
+ (instancetype)classMethodWithInt128:(__int128)value;
@optional
@property (nonatomic, weak) id<NSObject> optionalWeakProperty;
@property (class, nonatomic, readonly, getter=isEnabled) BOOL enabled;
- (void)vector:(simd_float4)vector;
@end

@interface RTBTestClass : NSObject <RTBTestProtocol> {
    int _array[5];
    int (*_functionPointer)(int, int);
    unsigned int _bitField : 3;
    NSString *_string;
    void (^_block)(void);
    __int128 _bigInteger;
    simd_float4 _vector;
    struct { float f; simd_float4 v; } _structWithVector;
    id<NSCopying, NSCoding> _qualifiedId;
    NSObject<NSCopying, NSCoding> *_qualifiedObject;
    NSString *_stringArray[3];
    struct { __unsafe_unretained id obj; __unsafe_unretained NSString *str; __unsafe_unretained id *ptr; } _structWithObjects;
}
@property (class, nonatomic, readonly) NSString *requiredClassProperty;
@property (class, nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) NSInteger requiredInstanceProperty;
@property (nonatomic, weak) id<NSObject> optionalWeakProperty;
@property (nonatomic, copy) void (^handler)(NSError *);
@property (nonatomic, strong) NSArray<NSString *> *strings;
@property (nonatomic, retain) NSObject<NSCopying, NSCoding> *qualifiedObject;
@property (nonatomic, assign) simd_float4 vector;
@property (class, nonatomic, readonly) simd_float4 classVector;
@end

@implementation RTBTestClass
@dynamic requiredInstanceProperty;
+ (NSString *)requiredClassProperty { return @""; }
+ (BOOL)isEnabled { return YES; }
+ (simd_float4)classVector { return (simd_float4){0}; }
- (void)fetchWithCompletion:(void (^)(NSData *, NSError *))completion {}
- (void)nestedBlock:(void (^)(BOOL (^inner)(NSString *)))block {}
- (id<NSCopying, NSCoding>)qualifiedObject:(NSObject<NSCopying> *)object { return nil; }
+ (instancetype)classMethodWithInt128:(__int128)value { return nil; }
- (void)vector:(simd_float4)vector {}
- (const char *)constChar:(const void *)p ptr:(int *)ip fn:(int (*)(void))fn { return NULL; }
- (void)structArg:(CGRect)r sel:(SEL)s cls:(Class)c bool:(BOOL)b { }
@end

// a category on a class of another image: the linker merges the categories of the classes of the same image
@interface NSObject (RTBTestCategory)
- (void)rtb_categoryInstanceMethod;
+ (void)rtb_categoryClassMethod;
@end

@implementation NSObject (RTBTestCategory)
- (void)rtb_categoryInstanceMethod {}
+ (void)rtb_categoryClassMethod {}
@end

@interface UnitTests : XCTestCase

@end

@implementation UnitTests

- (void)setUp {
    [super setUp];
    // the fixtures live in the same image as RuntimeBrowser, whose methods are hidden by default
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"RTBShowOCRuntimeClasses"];
}

- (void)tearDown {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RTBShowOCRuntimeClasses"];
    [super tearDown];
}

- (void)testExample {
    // This is an example of a functional test case.
    XCTAssert(YES, @"Pass");
}

- (void)assetLinesAreEqual:(NSString *)s1 withString:(NSString *)s2 {
    NSArray *lines1 = [s1 componentsSeparatedByString:@"\n"];
    NSArray *lines2 = [s2 componentsSeparatedByString:@"\n"];
    XCTAssertEqual([lines1 count], [lines2 count], @"");
    
    for(NSUInteger i = 0; i < [lines1 count]; i++) {
        NSString *line1 = [lines1 objectAtIndex:i];
        NSString *line2 = [lines2 objectAtIndex:i];
        //NSLog(@"-> %@", line1);
        XCTAssertEqualObjects(line1, line2, @"");
    }
}

- (NSString *)decodeFlatCType:(char *)c {
    return [RTBTypeDecoder decodeType:[NSString stringWithCString:c encoding:NSUTF8StringEncoding]
                                            flat:YES];
}

- (NSString *)decodeIvarType:(char *)c {
    return [RTBTypeDecoder decodeType:[NSString stringWithCString:c encoding:NSUTF8StringEncoding]
                                            flat:NO];
}

- (NSString *)decodeIvarModifier:(char *)c {
    RTBTypeDecoder *td = [[RTBTypeDecoder alloc] init];
    return [td ivarCTypeDeclForEncType:c].modifier;
}

- (NSString *)decodeIvarWithName:(NSString *)name type:(char *)c {
    RTBTypeDecoder *td = [[RTBTypeDecoder alloc] init];
    RTBTypeDeclaration *d = [td ivarCTypeDeclForEncType:c];
    return [NSString stringWithFormat:@"%@%@%@;", d.type, name, d.modifier];
}

- (NSString *)contentsForResource:(NSString *)name ofType:(NSString *)type {
    NSString *path = [[NSBundle bundleForClass:[self class]] pathForResource:name ofType:type];
    NSError *error = nil;
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if(s == nil) NSLog(@"-- error: %@", error);
    return s;
}

- (void)testBasicTypes {
    XCTAssertEqualObjects([self decodeFlatCType:"c"], RTB_CHAR_TYPE, @"");
    XCTAssertEqualObjects([self decodeFlatCType:"C"], @"unsigned char", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"s"], @"short", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"S"], @"unsigned short", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"i"], @"int", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"I"], @"unsigned int", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"l"], @"long", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"L"], @"unsigned long", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"q"], @"long long", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"Q"], @"unsigned long long", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"f"], @"float", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"d"], @"double", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"v"], @"void", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"@"], @"id", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"#"], @"Class", @"");
    XCTAssertEqualObjects([self decodeFlatCType:":"], @"SEL", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"*"], @"char *", @"");
}

- (void)testComplicatedTypes {
    XCTAssertEqualObjects([self decodeFlatCType:"^f"], @"float *", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"^v"], @"void *", @"");
    XCTAssertEqualObjects([self decodeFlatCType:"^@"], @"id *", @"");
    
    XCTAssertEqualObjects([self decodeIvarType:"[10i]"], @"int ", @"");
    XCTAssertEqualObjects([self decodeIvarModifier:"[10i]"], @"[10]", @"");
    
    NSLog(@"------ %@", [self decodeIvarWithName:@"x" type:"{example=@*i}"]);
    
    XCTAssertEqualObjects([self decodeIvarWithName:@"x" type:"[10i]"], @"int x[10];", @"");
    //	STAssertEqualObjects([self decodeIvarWithName:@"x" type:"{?=i[3f]b128i3b131i2c}"], @"struct { int x1; float x2[3]; unsigned int x3 : 128; int x4; /* Warning: Unrecognized filer type: '3' using 'void*' */ void*x5; unsigned int x6 : 131; int x7; void*x8; BOOL x9; } x;' should be equal to 'int x[10];", @"");
    XCTAssertEqualObjects([self decodeIvarWithName:@"x" type:"{example=@*i}"], @"struct example { id x1; char *x2; int x3; } x;", @"");
    XCTAssertEqualObjects([self decodeIvarWithName:@"x" type:"^{example=@*i}"], @"struct example { id x1; char *x2; int x3; } *x;", @"");
    XCTAssertEqualObjects([self decodeIvarWithName:@"x" type:"^^{example}"], @"struct example {} **x;", @"");
}

- (void)testMultiTypes {

    NSString *typesString = @"c32@0:8^{_colordef=II{_rgbquad=b8b8b8b8}}16@\"NSString\"24";

    NSArray *types = [RTBTypeDecoder decodeTypes:typesString flat:YES];

    XCTAssertEqual(5, [types count]);
    
    XCTAssertEqualObjects(types[0], RTB_CHAR_TYPE);
    XCTAssertEqualObjects(types[1], @"id");
    XCTAssertEqualObjects(types[2], @"SEL");
    XCTAssertEqualObjects(types[3], @"struct _colordef { unsigned int x1; unsigned int x2; struct _rgbquad { unsigned int x_3_1_1 : 8; unsigned int x_3_1_2 : 8; unsigned int x_3_1_3 : 8; unsigned int x_3_1_4 : 8; } x3; } *");
    XCTAssertEqualObjects(types[4], @"NSString *");
}

- (void)testExtendedEncodingForBlock {

    // - (void)aaaWithCompletionHandler:(void (^)(NSURLResponse* response, NSData* data, NSError* connectionError))completionHandler;
    NSString *typeString = @"v24@0:8@?<v@?@\"NSURLResponse\"@\"NSData\"@\"NSError\">16";

    NSArray *types = [RTBTypeDecoder decodeTypes:typeString flat:YES];
    
    XCTAssertEqual(4, [types count]);
    
    XCTAssertEqualObjects(types[0], @"void");
    XCTAssertEqualObjects(types[1], @"id");
    XCTAssertEqualObjects(types[2], @"SEL");
    XCTAssertEqualObjects(types[3], @"void (^)(NSURLResponse *, NSData *, NSError *)");
}

- (void)testExtendedEncodingForBlocks {
    XCTAssertEqualObjects([self decodeFlatCType:"@?<v@?>"], @"void (^)(void)");
    XCTAssertEqualObjects([self decodeFlatCType:"@?<v@?q>"], @"void (^)(long long)");
    XCTAssertEqualObjects([self decodeFlatCType:"@?<B@?@\"NSMutableDictionary\"@\"NSMutableArray\">"], ([NSString stringWithFormat:@"%@ (^)(NSMutableDictionary *, NSMutableArray *)", RTB_BOOL_TYPE]));
    XCTAssertEqualObjects([self decodeFlatCType:"@?<v@?@?<B@?@\"NSString\">>"], ([NSString stringWithFormat:@"void (^)(%@ (^)(NSString *))", RTB_BOOL_TYPE])); // nested blocks
    XCTAssertEqualObjects([self decodeFlatCType:"@?<v@?^@>"], @"void (^)(id *)");
    XCTAssertEqualObjects([self decodeFlatCType:"@?"], @"id"); // no signature
    XCTAssertEqualObjects([self decodeFlatCType:"@?<v@?"], @"id"); // unbalanced signature
    
    NSArray *types = [RTBTypeDecoder decodeTypes:@"v40@0:8@?<v@?@?<v@?@@\"NSError\">>16@?<B@?@\"NSError\">24@?<v@?@@\"NSError\">32" flat:YES];
    XCTAssertEqual(6, [types count]);
    XCTAssertEqualObjects(types[3], @"void (^)(void (^)(id, NSError *))");
    XCTAssertEqualObjects(types[4], ([NSString stringWithFormat:@"%@ (^)(NSError *)", RTB_BOOL_TYPE]));
    XCTAssertEqualObjects(types[5], @"void (^)(id, NSError *)");
}

- (void)testProtocolQualifiedObjects {
    XCTAssertEqualObjects([self decodeFlatCType:"@\"NSString\""], @"NSString *");
    XCTAssertEqualObjects([self decodeFlatCType:"@\"<NSCopying>\""], @"id <NSCopying>");
    XCTAssertEqualObjects([self decodeFlatCType:"@\"<NSCopying><NSCoding>\""], @"id <NSCopying, NSCoding>");
    XCTAssertEqualObjects([self decodeFlatCType:"@\"NSObject<NSCopying><NSCoding>\""], @"NSObject<NSCopying, NSCoding> *");
    XCTAssertEqualObjects([self decodeIvarType:"@\"<NSCopying>\""], @"id <NSCopying> ");
    
    NSArray *types = [RTBTypeDecoder decodeTypes:@"@\"<NSCopying><NSCoding>\"24@0:8@\"NSObject<NSCopying>\"16" flat:YES];
    XCTAssertEqual(4, [types count]);
    XCTAssertEqualObjects(types[0], @"id <NSCopying, NSCoding>");
    XCTAssertEqualObjects(types[3], @"NSObject<NSCopying> *");
}

- (void)testModernScalarTypes {
    XCTAssertEqualObjects([self decodeFlatCType:"t"], @"__int128");
    XCTAssertEqualObjects([self decodeFlatCType:"T"], @"unsigned __int128");
    XCTAssertEqualObjects([self decodeFlatCType:"D"], @"long double");
    XCTAssertEqualObjects([self decodeFlatCType:"Ai"], @"_Atomic int");
    XCTAssertEqualObjects([self decodeFlatCType:"jd"], @"_Complex double");
    XCTAssertEqualObjects([self decodeFlatCType:"r*"], @"const char *");
    XCTAssertEqualObjects([self decodeFlatCType:"Vv"], @"oneway void");
    XCTAssertEqualObjects([self decodeFlatCType:"O@"], @"bycopy id");
}

- (void)testTypesNotEncodedByTheCompiler {
    // clang does not encode vector types, they are simply left out
    XCTAssertEqualObjects([self decodeFlatCType:"[3]"], @"void /* ? */[3]"); // array of vectors
    XCTAssertEqualObjects([self decodeFlatCType:"^96"], @"void /* ? */ *"); // pointer to vector, followed by the offset
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"f\"f\"v\"}"], @"struct { float f; void /* ? */ v; }"); // struct with a vector member
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"lights\"[11]\"power\" \"lightness\" }"], @"struct { void /* ? */ lights[11]; void /* ? */ power; void /* ? */ lightness; }"); // _Float16 members are encoded as a space
    XCTAssertEqualObjects([self decodeFlatCType:"(?=\"eulerAngles\"\"axisAngle\"\"quaternion\"{?=\"vector\"})"], @"union { void /* ? */ eulerAngles; void /* ? */ axisAngle; struct { void /* ? */ vector; } quaternion; }");
    XCTAssertEqualObjects([self decodeFlatCType:"r16"], @"const void /* ? */");
    XCTAssertEqualObjects([RTBTypeDecoder decodeType:@"" flat:YES], @"void /* ? */");
    XCTAssertEqualObjects([RTBTypeDecoder decodeType:@"1" flat:YES], @"void /* ? */"); // what method_copyReturnType() returns for 16@0:8
    XCTAssertEqual(0, [[RTBTypeDecoder decodeTypes:nil flat:YES] count]);
    
    // a method type encoding starting with digits has an empty return type
    NSArray *types = [RTBTypeDecoder decodeTypes:@"16@0:8" flat:YES];
    XCTAssertEqual(3, [types count]);
    XCTAssertEqualObjects(types[0], @"void /* ? */");
    XCTAssertEqualObjects(types[1], @"id");
    XCTAssertEqualObjects(types[2], @"SEL");
}

- (void)testStructsWithObjectsAndPointers {
    // a quoted name after a pointer is always the next member name, never a class name
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"obj\"@\"str\"@\"NSString\"\"ptr\"^@}"], @"struct { id obj; NSString *str; id *ptr; }");
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"buffer\"^@\"state\"i}"], @"struct { id *buffer; int state; }");
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"name\"@\"NSString\"\"obj\"@\"NSObject<NSCopying>\"\"q\"@\"<NSCopying>\"\"arr\"[2@\"NSString\"]}"], @"struct { NSString *name; NSObject<NSCopying> *obj; id <NSCopying> q; NSString *arr[2]; }");
    XCTAssertEqualObjects([self decodeFlatCType:"(?=\"a\"@\"NSString\")"], @"union { NSString *a; }");
    XCTAssertEqualObjects([self decodeFlatCType:"{?=\"buffer\"^@\"state\"(?=\"\"{?=\"mutations\"Q}\"\"{?=\"muts\"I\"other\"I})}"], @"struct { id *buffer; union { struct { unsigned long long mutations; } ; struct { unsigned int muts; unsigned int other; } ; } state; }");
}

- (void)testCPlusPlusTemplateNames {
    XCTAssertEqualObjects([self decodeFlatCType:"{vector<CGPoint, std::allocator<CGPoint>>=^{CGPoint}^{CGPoint}}"], @"struct vector<CGPoint, std::allocator<CGPoint>> { struct CGPoint {} *x1; struct CGPoint {} *x2; }");
    XCTAssertEqualObjects([self decodeFlatCType:"{function<bool (unsigned long long)>={__value_func<bool (unsigned long long)>={type=[24C]}^v}}"], @"struct function<bool (unsigned long long)> { struct __value_func<bool (unsigned long long)> { struct type { unsigned char x_1_2_1[24]; } x_1_1_1; void *x_1_1_2; } x1; }");
    XCTAssertEqualObjects([self decodeFlatCType:"^{vector<int, std::allocator<int>>}"], @"struct vector<int, std::allocator<int>> {} *");
    XCTAssertEqualObjects([self decodeFlatCType:"(function<void ()>)"], @"union function<void ()> {}");
    XCTAssertEqualObjects([self decodeFlatCType:"{deque<id, std::allocator<id>>=\"__start_\"Q\"__size_\"{__compressed_pair<unsigned long, std::allocator<id>>=\"__value_\"Q}}"], @"struct deque<id, std::allocator<id>> { unsigned long long __start_; struct __compressed_pair<unsigned long, std::allocator<id>> { unsigned long long __value_; } __size_; }");
}

- (void)testFlatModifiers {
    XCTAssertEqualObjects([self decodeFlatCType:"^?"], @"int (*)()");
    XCTAssertEqualObjects([self decodeFlatCType:"[5i]"], @"int[5]");
    XCTAssertEqualObjects([self decodeFlatCType:"b3"], @"unsigned int : 3");
    NSArray *types = [RTBTypeDecoder decodeTypes:@"r*40@0:8r^v16^i24^?32" flat:YES];
    XCTAssertEqualObjects(types, (@[@"const char *", @"id", @"SEL", @"const void *", @"int *", @"int (*)()"]));
}

- (void)testIvarDeclarations {
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"[5i]" name:@"_array"], @"int  _array[5]");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"^?" name:@"_callback"], @"int (*_callback)()");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"b3" name:@"_flags"], @"unsigned int  _flags : 3");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"@\"NSString\"" name:@"_name"], @"NSString * _name");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"[3@\"NSString\"]" name:@"_names"], @"NSString * _names[3]");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"[5^v]" name:@"_reserved"], @"void * _reserved[5]");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:nil name:@"_swiftOnly"], @"void /* ? */ _swiftOnly"); // Swift-only types have no encoding
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"" name:@"_swiftOnly"], @"void /* ? */ _swiftOnly");
    XCTAssertEqualObjects([RTBTypeDecoder ivarDeclarationForEncodedType:@"b1" name:nil], @"unsigned int  /* ? */ : 1"); // anonymous bit field
}

- (void)testSELReturnType {
    NSString *typeString = @":16@0:8";
    
    NSArray *types = [RTBTypeDecoder decodeTypes:typeString flat:YES];
    
    XCTAssertEqual(3, [types count]);
    
    XCTAssertEqualObjects(types[0], @"SEL");
    XCTAssertEqualObjects(types[1], @"id");
    XCTAssertEqualObjects(types[2], @"SEL");
}

#pragma mark - Properties

- (NSString *)propertyDescription:(NSString *)attributes {
    return [RTBRuntimeHeader descriptionForPropertyWithName:@"p" attributes:attributes displayPropertiesDefaultValues:NO];
}

- (void)testPropertyAttributes {
    XCTAssertEqualObjects([self propertyDescription:@"T@\"NSString\",R,C"], @"@property (readonly, copy) NSString *p;");
    XCTAssertEqualObjects([self propertyDescription:@"T@\"NSArray\",&,N,V_strings"], @"@property (nonatomic, retain) NSArray *p;");
    XCTAssertEqualObjects([self propertyDescription:@"T@\"<NSObject>\",W,N,V_delegate"], @"@property (nonatomic, weak) id <NSObject> p;"); // W is __weak
    XCTAssertEqualObjects([self propertyDescription:@"T@\"NSObject<NSCopying><NSCoding>\",&,N"], @"@property (nonatomic, retain) NSObject<NSCopying, NSCoding> *p;");
    XCTAssertEqualObjects([self propertyDescription:@"Tq,R,D,N"], @"@property (nonatomic, readonly) long long p;"); // D is @dynamic
    XCTAssertEqualObjects([self propertyDescription:@"TB,R,N,GisEnabled"], ([NSString stringWithFormat:@"@property (getter=isEnabled, nonatomic, readonly) %@ p;", RTB_BOOL_TYPE]));
    XCTAssertEqualObjects([self propertyDescription:@"T@\"NSString\",?,R,C"], @"@property (readonly, copy) NSString *p;"); // ? is @optional in a protocol
    XCTAssertEqualObjects([self propertyDescription:@"T@?,C,N,V_handler"], @"@property (nonatomic, copy) id p;"); // block
    XCTAssertEqualObjects([self propertyDescription:@"T,N,V_vec"], @"@property (nonatomic) void /* ? */ p;"); // vector types are not encoded
    XCTAssertEqualObjects([self propertyDescription:@"T@,X"], @"@property id p; /* unknown property attribute: X */");
    XCTAssertEqualObjects([RTBRuntimeHeader descriptionForPropertyWithName:@"p" attributes:@"T@\"NSString\",R,C" displayPropertiesDefaultValues:YES], @"@property (atomic, readonly, copy) NSString *p;");
}

- (void)testClassPropertyAttributes {
    NSString *s = [RTBRuntimeHeader descriptionForPropertyWithName:@"standardUserDefaults" attributes:@"T@\"NSUserDefaults\",R,D" isClassProperty:YES displayPropertiesDefaultValues:NO];
    XCTAssertEqualObjects(s, @"@property (class, readonly) NSUserDefaults *standardUserDefaults;");
}

- (void)testPropertyAttributesWithCPlusPlusTemplateNames {
    // the commas inside the type encoding are not attribute separators
    NSString *attributes = @"T{pair<int, int>=ii},N,V_pair";
    XCTAssertEqualObjects([RTBRuntimeHeader componentsOfPropertyAttributes:attributes], (@[@"T{pair<int, int>=ii}", @"N", @"V_pair"]));
    XCTAssertEqualObjects([self propertyDescription:attributes], @"@property (nonatomic) struct pair<int, int> { int x1; int x2; } p;");
    XCTAssertEqualObjects([RTBRuntimeHeader componentsOfPropertyAttributes:@"T@\"NSString\",R,C"], (@[@"T@\"NSString\"", @"R", @"C"]));
}

- (void)testOptionalPropertyAttribute {
    XCTAssertTrue([RTBRuntimeHeader isOptionalPropertyWithAttributes:@"T@\"NSString\",?,R,C"]);
    XCTAssertFalse([RTBRuntimeHeader isOptionalPropertyWithAttributes:@"T@\"NSString\",R,C"]);
}

#pragma mark - Methods

- (void)testMethodDescription {
    NSString *s = [RTBRuntimeHeader descriptionForMethodName:@"foo:bar:" returnType:@"void" argumentTypes:@[@"id", @"SEL", @"int", @"NSString *"] newlineAfterArgs:NO isClassMethod:NO];
    XCTAssertEqualObjects(s, @"- (void)foo:(int)arg1 bar:(NSString *)arg2;");
    
    s = [RTBRuntimeHeader descriptionForMethodName:@"foo" returnType:@"id" argumentTypes:@[@"id", @"SEL"] newlineAfterArgs:NO isClassMethod:YES];
    XCTAssertEqualObjects(s, @"+ (id)foo;");
    
    // clang did not encode the vector argument: the selector still has its colon
    s = [RTBRuntimeHeader descriptionForMethodName:@"vector:" returnType:@"void" argumentTypes:@[@"id", @"SEL"] newlineAfterArgs:NO isClassMethod:NO];
    XCTAssertEqualObjects(s, @"- (void)vector:(void *)arg1; // needs 1 arg types, found 0: ");
    
    s = [RTBRuntimeHeader descriptionForMethodName:@"a:b:" returnType:@"void" argumentTypes:@[@"id", @"SEL", @"int"] newlineAfterArgs:NO isClassMethod:NO];
    XCTAssertEqualObjects(s, @"- (void)a:(void *)arg1 b:(void *)arg2; // needs 2 arg types, found 1: int");
    
    // no argument types at all
    s = [RTBRuntimeHeader descriptionForMethodName:@"foo:" returnType:@"void" argumentTypes:@[] newlineAfterArgs:NO isClassMethod:NO];
    XCTAssertEqualObjects(s, @"- (void)foo:(void *)arg1; // needs 1 arg types, found 0: ");
}

#pragma mark - Headers

- (NSString *)headerForTestClass {
    return [RTBRuntimeHeader headerForClass:[RTBTestClass class] displayPropertiesDefaultValues:NO];
}

- (void)assertHeader:(NSString *)header containsLine:(NSString *)line {
    NSArray *lines = [header componentsSeparatedByString:@"\n"];
    XCTAssertTrue([lines containsObject:line], @"line not found: %@ in\n%@", line, header);
}

- (void)testClassHeaderIvars {
    NSString *header = [self headerForTestClass];
    [self assertHeader:header containsLine:@"    int  _array[5];"];
    [self assertHeader:header containsLine:@"    int (*_functionPointer)();"];
    [self assertHeader:header containsLine:@"    unsigned int  _bitField : 3;"];
    [self assertHeader:header containsLine:@"    NSString * _string;"];
    [self assertHeader:header containsLine:@"    id  _block;"];
    [self assertHeader:header containsLine:@"    __int128  _bigInteger;"];
    [self assertHeader:header containsLine:@"    void /* ? */ _vector;"]; // vector types are not encoded
    [self assertHeader:header containsLine:@"        void /* ? */ v; "];
    [self assertHeader:header containsLine:@"    id <NSCopying, NSCoding>  _qualifiedId;"];
    [self assertHeader:header containsLine:@"    NSObject<NSCopying, NSCoding> * _qualifiedObject;"];
    [self assertHeader:header containsLine:@"    NSString * _stringArray[3];"];
    [self assertHeader:header containsLine:@"        NSString *str; "];
    [self assertHeader:header containsLine:@"        id *ptr; "];
}

- (void)testClassHeaderProperties {
    NSString *header = [self headerForTestClass];
    [self assertHeader:header containsLine:[NSString stringWithFormat:@"@property (class, getter=isEnabled, nonatomic, readonly) %@ enabled;", RTB_BOOL_TYPE]];
    [self assertHeader:header containsLine:@"@property (class, nonatomic, readonly) NSString *requiredClassProperty;"];
    [self assertHeader:header containsLine:@"@property (class, nonatomic, readonly) void /* ? */ classVector;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, readonly) long long requiredInstanceProperty;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, weak) id <NSObject> optionalWeakProperty;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, copy) id handler;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, retain) NSArray *strings;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, retain) NSObject<NSCopying, NSCoding> *qualifiedObject;"];
    [self assertHeader:header containsLine:@"@property (nonatomic) void /* ? */ vector;"];
    XCTAssertFalse([header containsString:@"unknown property attribute"]);
    
    // class properties come first
    NSRange classRange = [header rangeOfString:@"@property (class"];
    NSRange instanceRange = [header rangeOfString:@"@property (nonatomic, readonly) long long"];
    XCTAssertTrue(classRange.location < instanceRange.location);
}

- (void)testClassHeaderMethods {
    NSString *header = [self headerForTestClass];
    [self assertHeader:header containsLine:@"+ (id)classMethodWithInt128:(__int128)arg1;"];
    [self assertHeader:header containsLine:@"+ (void /* ? */)classVector;"]; // empty return type, 16@0:8
    [self assertHeader:header containsLine:@"- (void)fetchWithCompletion:(id)arg1;"]; // no block signature in method lists
    [self assertHeader:header containsLine:@"- (id)qualifiedObject:(id)arg1;"];
    [self assertHeader:header containsLine:@"- (const char *)constChar:(const void *)arg1 ptr:(int *)arg2 fn:(int (*)())arg3;"];
    [self assertHeader:header containsLine:@"- (void)vector:(void *)arg1; // needs 1 arg types, found 0: "]; // the colon is kept
    XCTAssertTrue([header containsString:@"- (void)structArg:(struct CGRect {"]);
    XCTAssertFalse([header containsString:@"Warning"]);
    XCTAssertFalse([[self headerForTestClass] containsString:@"Swift class"]);
}

- (void)testProtocolHeader {
    RTBProtocol *protocol = [RTBProtocol protocolStubWithProtocolName:@"RTBTestProtocol"];
    NSString *header = [RTBRuntimeHeader headerForProtocol:protocol displayPropertiesDefaultValues:NO];
    
    XCTAssertTrue([header hasPrefix:@"/* Generated by RuntimeBrowser.\n */\n\n@protocol RTBTestProtocol <NSObject>\n\n@required\n\n"]);
    
    // properties, the '?' attribute tells the optional ones
    [self assertHeader:header containsLine:@"@property (class, nonatomic, readonly) NSString *requiredClassProperty;"];
    [self assertHeader:header containsLine:@"@property (nonatomic, readonly) long long requiredInstanceProperty;"];
    [self assertHeader:header containsLine:[NSString stringWithFormat:@"@property (class, getter=isEnabled, nonatomic, readonly) %@ enabled;", RTB_BOOL_TYPE]];
    [self assertHeader:header containsLine:@"@property (nonatomic, weak) id <NSObject> optionalWeakProperty;"];
    
    // extended type encodings have class names and block signatures
    [self assertHeader:header containsLine:@"+ (id)classMethodWithInt128:(__int128)arg1;"];
    [self assertHeader:header containsLine:@"- (void)fetchWithCompletion:(void (^)(NSData *, NSError *))arg1;"];
    [self assertHeader:header containsLine:[NSString stringWithFormat:@"- (void)nestedBlock:(void (^)(%@ (^)(NSString *)))arg1;", RTB_BOOL_TYPE]];
    [self assertHeader:header containsLine:@"- (id <NSCopying, NSCoding>)qualifiedObject:(NSObject<NSCopying> *)arg1;"];
    [self assertHeader:header containsLine:@"- (void)vector:(void *)arg1; // needs 1 arg types, found 0: "];
    
    NSRange requiredRange = [header rangeOfString:@"@required"];
    NSRange optionalRange = [header rangeOfString:@"@optional"];
    NSRange requiredClassPropertyRange = [header rangeOfString:@"requiredClassProperty;"];
    NSRange optionalPropertyRange = [header rangeOfString:@"optionalWeakProperty;"];
    NSRange enabledRange = [header rangeOfString:[NSString stringWithFormat:@"%@ enabled;", RTB_BOOL_TYPE]];
    XCTAssertTrue(enabledRange.location != NSNotFound);
    XCTAssertTrue(requiredRange.location < requiredClassPropertyRange.location);
    XCTAssertTrue(requiredClassPropertyRange.location < optionalRange.location);
    XCTAssertTrue(optionalRange.location < optionalPropertyRange.location);
    XCTAssertTrue(optionalRange.location < enabledRange.location);
    XCTAssertTrue([header hasSuffix:@"@end\n"]);
}

- (void)testProtocolWithoutExtendedTypeEncodings {
    // protocols built at runtime have no extended type encodings, and possibly no encodings at all
    Protocol *p = objc_allocateProtocol("RTBRuntimeBuiltProtocol");
    if(p == NULL) return; // already registered by a previous run in the same process
    protocol_addMethodDescription(p, @selector(foo:), "v24@0:8@16", YES, YES);
    protocol_addMethodDescription(p, @selector(bar), NULL, NO, YES);
    objc_registerProtocol(p);
    
    RTBProtocol *protocol = [RTBProtocol protocolStubWithProtocolName:@"RTBRuntimeBuiltProtocol"];
    NSString *header = [RTBRuntimeHeader headerForProtocol:protocol displayPropertiesDefaultValues:NO];
    [self assertHeader:header containsLine:@"- (void)foo:(id)arg1;"];
    [self assertHeader:header containsLine:@"- (void /* ? */)bar;"];
}

#pragma mark - Swift

- (void)testSwiftClasses {
    RTBClass *cs = [RTBClass classStubWithClass:[RTBTestClass class]];
    XCTAssertFalse([cs isSwiftClass]);
    XCTAssertNil([cs swiftDemangledName]);
    XCTAssertEqualObjects([cs displayName], @"RTBTestClass");
    XCTAssertEqualObjects([cs swiftFieldsByName], @{});
    XCTAssertEqualObjects([cs sortedSwiftMembers], @[]);
    
    Class swiftObject = NSClassFromString(@"_TtCs12_SwiftObject"); // Swift._SwiftObject, present when libswiftCore is loaded
    if(swiftObject == nil) return;
    RTBClass *swiftStub = [RTBClass classStubWithClass:swiftObject];
    XCTAssertTrue([swiftStub isSwiftClass]);
    XCTAssertEqualObjects([swiftStub swiftDemangledName], @"Swift._SwiftObject");
    XCTAssertEqualObjects([swiftStub displayName], @"Swift._SwiftObject");
    NSString *header = [RTBRuntimeHeader headerForClass:swiftObject displayPropertiesDefaultValues:NO];
    XCTAssertTrue([header containsString:@"   Swift class: Swift._SwiftObject\n"]);
}

- (void)testSwiftClassMetadata {
    // the Foundation overlay classes are present as soon as Foundation is loaded on macOS 12+
    Class timerPublisher = NSClassFromString(@"_TtCE10FoundationCSo7NSTimer14TimerPublisher");
    if(timerPublisher == nil) return;
    
    RTBClass *cs = [RTBClass classStubWithClass:timerPublisher];
    XCTAssertTrue([cs isSwiftClass]);
    XCTAssertEqualObjects([cs swiftDemangledName], @"(extension in Foundation):__C.NSTimer.TimerPublisher");
    XCTAssertEqualObjects([cs displayName], @"(extension in Foundation):__C.NSTimer.TimerPublisher"); // mangled names are displayed demangled
    XCTAssertEqualObjects([cs nodeName], [cs displayName]);
    XCTAssertEqualObjects([cs classObjectName], @"_TtCE10FoundationCSo7NSTimer14TimerPublisher"); // the runtime name is unchanged
    
    // stored properties, from the Swift reflection metadata
    NSDictionary *fields = [cs swiftFieldsByName];
    XCTAssertEqualObjects(fields[@"interval"][@"type"], @"Swift.Double");
    XCTAssertEqualObjects(fields[@"interval"][@"isVar"], @NO);
    XCTAssertEqualObjects(fields[@"interval"][@"isStrong"], @YES);
    XCTAssertEqualObjects(fields[@"tolerance"][@"type"], @"Swift.Optional<Swift.Double>");
    XCTAssertEqualObjects(fields[@"sides"][@"isVar"], @YES);
    
    NSString *header = [RTBRuntimeHeader headerForClass:timerPublisher displayPropertiesDefaultValues:NO];
    [self assertHeader:header containsLine:@"   Swift class: (extension in Foundation):__C.NSTimer.TimerPublisher"];
    [self assertHeader:header containsLine:@"    Swift.Double interval; // let"];
    [self assertHeader:header containsLine:@"    Swift.Optional<Swift.Double> tolerance; // let"];
    XCTAssertFalse([header containsString:@"void /* ? */"]);
    
    // members recovered from the symbol table, the public API of Timer.TimerPublisher is always exported
    NSArray *members = [cs sortedSwiftMembers];
    XCTAssertTrue([members count] >= 3, @"%@", members);
    XCTAssertTrue([[members firstObject] hasPrefix:@"init(interval: Swift.Double, tolerance: Swift.Optional<Swift.Double>, runLoop: __C.NSRunLoop, mode: __C.NSRunLoopMode"], @"%@", members);
    XCTAssertTrue([members containsObject:@"func connect() -> Combine.Cancellable"], @"%@", members);
    XCTAssertTrue([members containsObject:@"var interval: Swift.Double { get }"], @"%@", members);
    [self assertHeader:header containsLine:@"// Swift members, from the symbol table (stripped members are missing)"];
    
    // the search finds the demangled name
    XCTAssertTrue([cs containsSearchString:@"TimerPublisher"]);
    XCTAssertTrue([cs containsSearchString:@"Swift.Optional<Swift.Double>"]);
}

- (void)testSwiftClassWithObjCName {
    // Swift classes may be registered with a plain name with @objc(Name), the metadata still tells they are Swift
    Class swiftData = NSClassFromString(@"Foundation.__NSSwiftData");
    if(swiftData == nil) return;
    RTBClass *cs = [RTBClass classStubWithClass:swiftData];
    XCTAssertTrue([cs isSwiftClass]);
    XCTAssertEqualObjects([cs swiftDemangledName], @"Foundation.__NSSwiftData");
    XCTAssertEqualObjects([cs displayName], @"Foundation.__NSSwiftData");
    XCTAssertEqualObjects([cs swiftFieldsByName][@"_backing"][@"type"], @"Swift.Optional<Foundation.__DataStorage>");
}

- (void)testSwiftDeclarationsFromDemangledSymbols {
    NSString *t = @"Module.Foo";
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.__allocating_init(x: Swift.Int) -> Module.Foo" typeName:t], @"init(x: Swift.Int)");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.init(x: Swift.Int) -> Module.Foo" typeName:t], @"init(x: Swift.Int)");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.init(x: Swift.Int) -> Swift.Optional<Module.Foo>" typeName:t], @"init?(x: Swift.Int)"); // failable
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.bar(Swift.Int) -> Swift.String" typeName:t], @"func bar(Swift.Int) -> Swift.String");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.run<A where A: Swift.Equatable>(_: A, count: Swift.Int) -> ()" typeName:t], @"func run<A where A: Swift.Equatable>(_: A, count: Swift.Int) -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.load() throws -> Foundation.Data" typeName:t], @"func load() throws -> Foundation.Data");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"static Module.Foo.baz() -> ()" typeName:t], @"static func baz() -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"static Module.Foo.== infix(Module.Foo, Module.Foo) -> Swift.Bool" typeName:t], @"static func ==(Module.Foo, Module.Foo) -> Swift.Bool");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.name.getter : Swift.String" typeName:t], @"var name: Swift.String { get }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.name.setter : Swift.String" typeName:t], @"var name: Swift.String { get set }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.name.modify : Swift.String" typeName:t], @"var name: Swift.String { get set }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.handler.getter : (Swift.Int) -> ()" typeName:t], @"var handler: (Swift.Int) -> () { get }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"static Module.Foo.shared.getter : Module.Foo" typeName:t], @"static var shared: Module.Foo { get }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"static Module.Foo.shared.unsafeMutableAddressor : Module.Foo" typeName:t], @"static var shared: Module.Foo { get }"); // emitted for static let too
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.subscript.getter : (Swift.Int) -> Swift.String" typeName:t], @"subscript(Swift.Int) -> Swift.String { get }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.(secret in _2F6327E72581B7F866C81F7546545BE8)(implicit: Swift.Bool) -> ()" typeName:t], @"private func secret(implicit: Swift.Bool) -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"Module.Foo.(cache in _2F6327E72581B7F866C81F7546545BE8).getter : Swift.Int" typeName:t], @"private var cache: Swift.Int { get }");
    
    // symbols that stand for a member: dispatch thunks and method descriptors of public members (exported even when the implementation is stripped), property descriptors, specializations
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"dispatch thunk of Module.Foo.bar() -> ()" typeName:t], @"func bar() -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"dispatch thunk of static Module.Foo.baz() -> ()" typeName:t], @"static func baz() -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"dispatch thunk of Module.Foo.name.setter : Swift.String" typeName:t], @"var name: Swift.String { get set }");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"dispatch thunk of Module.Foo.__allocating_init(x: Swift.Int) -> Module.Foo" typeName:t], @"init(x: Swift.Int)");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"method descriptor for Module.Foo.bar() -> ()" typeName:t], @"func bar() -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"property descriptor for Module.Foo.name : Swift.String" typeName:t], @"var name: Swift.String");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"generic specialization <Swift.Int> of Module.Foo.run<A>(A) -> ()" typeName:t], @"func run<A>(A) -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"function signature specialization <Arg[0] = Dead> of Module.Foo.fire(__C.NSTimer) -> ()" typeName:t], @"func fire(__C.NSTimer) -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"merged Module.Foo.bar() -> ()" typeName:t], @"func bar() -> ()");
    XCTAssertEqualObjects([RTBSwift declarationForDemangledSymbol:@"(extension in Other):Module.Foo.ext() -> ()" typeName:t], @"func ext() -> ()");
    
    // not members of Module.Foo: metadata, nested types, closures, thunks, witnesses, deinit, other classes (identical code folding)
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"type metadata for Module.Foo" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"type metadata accessor for Module.Foo" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.Nested.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.Nested.name.getter : Swift.String" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"closure #1 () -> () in Module.Foo.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"partial apply forwarder for closure #1 () -> () in Module.Foo.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"@objc Module.Foo.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"key path getter for Module.Foo.name : Swift.String : Module.Foo" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"variable initialization expression of Module.Foo.name : Swift.String" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"direct field offset for Module.Foo.name : Swift.String" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"default argument 0 of Module.Foo.bar(x: Swift.Int) -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.name.modify : Swift.String with unmangled suffix \".resume.0\"" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.__deallocating_deinit" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.deinit" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.__ivar_destroyer" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.FooBar.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Other.bar() -> ()" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"protocol witness for Swift.Equatable.== infix(A, A) -> Swift.Bool in conformance Module.Foo : Swift.Equatable in Module" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"destructiveInjectEnumTag value witness for Module.Foo" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"OUTLINED_FUNCTION_20" typeName:t]);
    XCTAssertNil([RTBSwift declarationForDemangledSymbol:@"Module.Foo.notAFunction" typeName:t]);
}

- (void)testSearch {
    RTBClass *cs = [RTBClass classStubWithClass:[RTBTestClass class]];
    XCTAssertTrue([cs containsSearchString:@"RTBTestClass"]);
    XCTAssertTrue([cs containsSearchString:@"testclass"]); // case insensitive
    XCTAssertTrue([cs containsSearchString:@"_bitField"]); // ivar name
    XCTAssertTrue([cs containsSearchString:@"fetchWithCompletion"]); // method
    XCTAssertTrue([cs containsSearchString:@"classMethodWithInt128"]); // class method
    XCTAssertTrue([cs containsSearchString:@"RTBTestProtocol"]); // protocol
    XCTAssertTrue([cs containsSearchString:@"NSObject<NSCopying, NSCoding>"]); // ivar type
    XCTAssertFalse([cs containsSearchString:@"zzzznotfound"]);
    XCTAssertFalse([cs containsSearchString:@""]);
    XCTAssertFalse([cs containsSearchString:@"RTBTestClass\n_bitField"]); // no match across tokens
    
    RTBClass *nsObject = [RTBClass classStubWithClass:[NSObject class]];
    XCTAssertFalse([nsObject containsSearchString:@"zzzznotfound"]); // used to match everything for non-Swift classes
    XCTAssertTrue([nsObject containsSearchString:@"nsobject"]);
    
    Class timerPublisher = NSClassFromString(@"_TtCE10FoundationCSo7NSTimer14TimerPublisher");
    if(timerPublisher) {
        RTBClass *swift = [RTBClass classStubWithClass:timerPublisher];
        XCTAssertTrue([swift containsSearchString:@"TimerPublisher"]); // demangled name
        XCTAssertTrue([swift containsSearchString:@"Swift.Optional<Swift.Double>"]); // Swift field type
        XCTAssertFalse([swift containsSearchString:@"zzzznotfound"]);
    }
}

- (void)testCategoriesFromTheCategoryLists {
    // the test bundle is not in the shared cache, its category lists are intact
    Method instanceMethod = class_getInstanceMethod([NSObject class], @selector(rtb_categoryInstanceMethod));
    Method classMethod = class_getClassMethod([NSObject class], @selector(rtb_categoryClassMethod));
    Method baseMethod = class_getInstanceMethod([RTBTestClass class], @selector(fetchWithCompletion:));
    XCTAssertEqualObjects([RTBCategories categoryNameForMethod:instanceMethod], @"RTBTestCategory");
    XCTAssertEqualObjects([RTBCategories categoryNameForMethod:classMethod], @"RTBTestCategory");
    XCTAssertNil([RTBCategories categoryNameForMethod:baseMethod]);
    XCTAssertNil([RTBCategories categoryNameForMethod:NULL]);
    
    // the shared cache merges the categories of a class, only the symbols remember them
    Method valueForKey = class_getInstanceMethod([NSObject class], @selector(valueForKey:));
    XCTAssertNil([RTBCategories categoryNameForMethod:valueForKey]);
    
    RTBMethod *m = [RTBMethod methodObjectWithMethod:instanceMethod isClassMethod:NO];
    XCTAssertEqualObjects([m categoryName], @"RTBTestCategory");
    
    NSString *header = [RTBRuntimeHeader headerForClass:[NSObject class] displayPropertiesDefaultValues:NO];
    [self assertHeader:header containsLine:@"// NSObject (RTBTestCategory)"];
    [self assertHeader:header containsLine:@"+ (void)rtb_categoryClassMethod;"];
    [self assertHeader:header containsLine:@"- (void)rtb_categoryInstanceMethod;"];
}

- (void)testSimplifiedSwiftTypeNames {
    NSString *(^simplify)(NSString *) = ^(NSString *s) { return [RTBSwift simplifiedTypeNamesInString:s]; };
    XCTAssertEqualObjects(simplify(@"Swift.Int"), @"Int");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<Swift.String>"), @"String?");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<Swift.Optional<Swift.Int>>"), @"Int??");
    XCTAssertEqualObjects(simplify(@"Swift.Array<Swift.Int>"), @"[Int]");
    XCTAssertEqualObjects(simplify(@"Swift.Dictionary<Swift.String, Swift.Array<Foundation.URL>>"), @"[String: [Foundation.URL]]");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<Swift.Range<Swift.Int>>"), @"Range<Int>?");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<(Swift.Int) -> Swift.Bool>"), @"((Int) -> Bool)?"); // function types are parenthesized
    XCTAssertEqualObjects(simplify(@"Swift.Optional<(Swift.Int, Swift.Int)>"), @"(Int, Int)?");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<__C.NSObject & SwiftUI.PlatformAccessibilityElementProtocol>"), @"(NSObject & SwiftUI.PlatformAccessibilityElementProtocol)?");
    XCTAssertEqualObjects(simplify(@"__C.NSRunLoopMode"), @"NSRunLoopMode");
    XCTAssertEqualObjects(simplify(@"SwiftUI.View"), @"SwiftUI.View"); // not the Swift module
    XCTAssertEqualObjects(simplify(@"Foundation.__NSSwiftData"), @"Foundation.__NSSwiftData");
    XCTAssertEqualObjects(simplify(@"init(interval: Swift.Double, tolerance: Swift.Optional<Swift.Double>, runLoop: __C.NSRunLoop)"), @"init(interval: Double, tolerance: Double?, runLoop: NSRunLoop)");
    XCTAssertEqualObjects(simplify(@"var sides: Swift.Dictionary<Combine.CombineIdentifier, Foundation.Side> { get set }"), @"var sides: [Combine.CombineIdentifier: Foundation.Side] { get set }");
    XCTAssertEqualObjects(simplify(@"func receive<A where A: Combine.Subscriber, A.Failure == Swift.Never>(subscriber: A) -> ()"), @"func receive<A where A: Combine.Subscriber, A.Failure == Never>(subscriber: A) -> ()");
    XCTAssertEqualObjects(simplify(@"Swift.Optional<Swift.String"), @"Optional<String"); // unbalanced: no sugar, prefixes still dropped
    XCTAssertEqualObjects(simplify(@""), @"");
    
    // the user default
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"RTBSimplifiedSwiftTypes"];
    XCTAssertEqualObjects([RTBSwift displayedTypeNamesInString:@"Swift.Optional<Swift.String>"], @"String?");
    Class timerPublisher = NSClassFromString(@"_TtCE10FoundationCSo7NSTimer14TimerPublisher");
    if(timerPublisher) {
        NSString *header = [RTBRuntimeHeader headerForClass:timerPublisher displayPropertiesDefaultValues:NO];
        [self assertHeader:header containsLine:@"    Double interval; // let"];
        [self assertHeader:header containsLine:@"    Double? tolerance; // let"];
        [self assertHeader:header containsLine:@"var interval: Double { get }"];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"RTBSimplifiedSwiftTypes"];
    XCTAssertEqualObjects([RTBSwift displayedTypeNamesInString:@"Swift.Optional<Swift.String>"], @"Swift.Optional<Swift.String>");
}

- (void)testSortedAdoptedProtocolsNames {
    RTBProtocol *protocol = [RTBProtocol protocolStubWithProtocolName:@"NSMutableCopying"];
    XCTAssertEqualObjects([protocol sortedAdoptedProtocolsNames], @[]);
    protocol = [RTBProtocol protocolStubWithProtocolName:@"NSSecureCoding"];
    XCTAssertEqualObjects([protocol sortedAdoptedProtocolsNames], @[@"NSCoding"]);
}

- (void)_testHeadersLinesNSString {
//    ClassDisplay *cd = [ClassDisplay classDisplayWithClass:[NSString class]];
//    NSString *generatedHeader = [cd header];
//    
//    [generatedHeader writeToFile:@"/tmp/NSString.h" atomically:YES encoding:NSUTF8StringEncoding error:nil];
//    
//    NSString *referenceHeader = [self contentsForResource:@"NSString" ofType:@"h"];
//    
//    [self assetLinesAreEqual:generatedHeader withString:referenceHeader];
}

- (void)_testHeadersLinesCALayer {
//    ClassDisplay *cd = [ClassDisplay classDisplayWithClass:[CALayer class]];
//    NSString *generatedHeader = [cd header];
//    
//    [generatedHeader writeToFile:@"/tmp/CALayer.h" atomically:YES encoding:NSUTF8StringEncoding error:nil];
//    
//    NSString *referenceHeader = [self contentsForResource:@"CALayer" ofType:@"h"];;
//    
//    [self assetLinesAreEqual:generatedHeader withString:referenceHeader];
}

@end

