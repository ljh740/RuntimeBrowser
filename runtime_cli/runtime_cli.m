#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "RTBRuntimeHeader.h"
#import "RTBRuntime.h"
#import "RTBClass.h"
#import "RTBProtocol.h"
#import "RTBSwiftTypes.h"

/*
 runtime_cli [--load image ...] [ClassName]        prints the header of the class as RuntimeBrowser sees it, NSString by default
 runtime_cli [--load image ...] --swift TypeName   prints the declaration of a Swift struct, enum or protocol, eg. Foundation.Date
 runtime_cli --sweep directory [--frameworks N]    loads up to N frameworks (400) of /System/Library/Frameworks and PrivateFrameworks
                                                   and writes the headers of all the classes and protocols, and the declarations of
                                                   all the Swift types, in classes/, protocols/ and swift/. A regression test for the
                                                   model: sweep before and after a change, then diff -r the two directories.
 */

static void rtb_usage(void) {
    fprintf(stderr, "usage: runtime_cli [--load image ...] [ClassName]\n"
                    "       runtime_cli [--load image ...] --swift TypeName\n"
                    "       runtime_cli --sweep directory [--frameworks N]\n");
}

static NSUInteger rtb_loadFrameworks(NSString *directory, NSUInteger limit) {
    NSUInteger loaded = 0;
    for(NSString *item in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if([[item pathExtension] isEqualToString:@"framework"] == NO) continue;
        if(loaded >= limit) break;
        NSString *path = [[directory stringByAppendingPathComponent:item] stringByAppendingPathComponent:[item stringByDeletingPathExtension]];
        if(dlopen([path fileSystemRepresentation], RTLD_LAZY | RTLD_NOLOAD) != NULL) continue; // already loaded
        if(dlopen([path fileSystemRepresentation], RTLD_LAZY) != NULL) loaded++;
    }
    return loaded;
}

static BOOL rtb_write(NSString *contents, NSString *directory, NSString *filename) {
    NSString *path = [directory stringByAppendingPathComponent:[filename stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
    NSError *error = nil;
    if([contents writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) return YES;
    fprintf(stderr, "cannot write %s: %s\n", [path UTF8String], [[error localizedDescription] UTF8String]);
    return NO;
}

static int rtb_sweep(NSString *directory, NSUInteger frameworksLimit) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for(NSString *sub in @[@"classes", @"protocols", @"swift"]) {
        NSError *error = nil;
        if(![fm createDirectoryAtPath:[directory stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "cannot create %s: %s\n", [directory UTF8String], [[error localizedDescription] UTF8String]);
            return 1;
        }
    }

    for(NSString *frameworks in @[@"/System/Library/Frameworks", @"/System/Library/PrivateFrameworks"]) {
        NSUInteger loaded = rtb_loadFrameworks(frameworks, frameworksLimit);
        fprintf(stderr, "loaded %lu frameworks from %s\n", (unsigned long)loaded, [frameworks UTF8String]);
    }

    // the classes
    NSDate *start = [NSDate date];
    RTBRuntime *runtime = [RTBRuntime sharedInstance];
    NSArray *classStubs = [runtime sortedClassStubs];
    fprintf(stderr, "%lu classes read in %.1fs\n", (unsigned long)[classStubs count], -[start timeIntervalSinceNow]);

    start = [NSDate date];
    NSUInteger classHeaders = 0, warnings = 0, unknownAttributes = 0, swiftConformances = 0;
    for(RTBClass *classStub in classStubs) { @autoreleasepool {
        Class klass = NSClassFromString([classStub classObjectName]);
        if(klass == Nil) { fprintf(stderr, "no class named %s\n", [[classStub classObjectName] UTF8String]); continue; }
        NSString *header = [RTBRuntimeHeader headerForClass:klass displayPropertiesDefaultValues:NO];
        if([header rangeOfString:@"/* Warning:"].location != NSNotFound) warnings++; // the type decoder met an encoding it does not know
        if([header rangeOfString:@"unknown property attribute"].location != NSNotFound) unknownAttributes++;
        if([header rangeOfString:@"// Swift conformances"].location != NSNotFound) swiftConformances++;
        if(rtb_write(header, [directory stringByAppendingPathComponent:@"classes"], [[classStub classObjectName] stringByAppendingPathExtension:@"h"])) classHeaders++;
    } }
    fprintf(stderr, "%lu class headers in %.1fs: %lu with Swift conformances, %lu with type decoder warnings, %lu with unknown property attributes\n",
            (unsigned long)classHeaders, -[start timeIntervalSinceNow], (unsigned long)swiftConformances, (unsigned long)warnings, (unsigned long)unknownAttributes);

    // the protocols
    start = [NSDate date];
    NSUInteger protocolHeaders = 0;
    for(RTBProtocol *protocol in [runtime sortedProtocolStubs]) { @autoreleasepool {
        NSString *header = [RTBRuntimeHeader headerForProtocol:protocol];
        if(rtb_write(header, [directory stringByAppendingPathComponent:@"protocols"], [[protocol protocolName] stringByAppendingPathExtension:@"h"])) protocolHeaders++;
    } }
    fprintf(stderr, "%lu protocol headers in %.1fs\n", (unsigned long)protocolHeaders, -[start timeIntervalSinceNow]);

    // the Swift types, one file per image
    start = [NSDate date];
    NSUInteger images = 0, types = 0, generic = 0, withMembers = 0, unknownFieldTypes = 0;
    NSUInteger kinds[4] = {0, 0, 0, 0};
    for(NSString *imagePath in [RTBSwiftTypes imagePathsWithSwiftTypes]) { @autoreleasepool {
        NSArray *imageTypes = [RTBSwiftTypes typesInImageAtPath:imagePath];
        if([imageTypes count] == 0) continue;
        images++;
        NSMutableString *all = [NSMutableString string];
        for(RTBSwiftType *type in imageTypes) { @autoreleasepool {
            NSString *declaration = [type declaration];
            [all appendString:declaration];
            [all appendString:@"\n\n"];
            types++;
            kinds[type.kind]++;
            if(type.isGeneric) generic++;
            if([declaration rangeOfString:@"// members"].location != NSNotFound) withMembers++;
            if([declaration rangeOfString:@": ?\n"].location != NSNotFound || [declaration rangeOfString:@"(?)"].location != NSNotFound) unknownFieldTypes++;
        } }
        rtb_write(all, [directory stringByAppendingPathComponent:@"swift"], [[imagePath lastPathComponent] stringByAppendingPathExtension:@"swift"]);
    } }
    fprintf(stderr, "%lu Swift types of %lu images in %.1fs: %lu structs, %lu enums, %lu protocols, %lu generic, %lu with members, %lu with unknown field types\n",
            (unsigned long)types, (unsigned long)images, -[start timeIntervalSinceNow], (unsigned long)kinds[RTBSwiftTypeKindStruct], (unsigned long)kinds[RTBSwiftTypeKindEnum],
            (unsigned long)kinds[RTBSwiftTypeKindProtocol], (unsigned long)generic, (unsigned long)withMembers, (unsigned long)unknownFieldTypes);
    return 0;
}

int main (int argc, const char * argv[]) {

    @autoreleasepool {
        NSMutableArray *arguments = [NSMutableArray array];
        for(int i = 1; i < argc; i++) [arguments addObject:[NSString stringWithUTF8String:argv[i]]];

        NSString *sweepDirectory = nil;
        NSString *swiftTypeName = nil;
        NSString *className = nil;
        NSUInteger frameworksLimit = 400;

        for(NSUInteger i = 0; i < [arguments count]; i++) {
            NSString *argument = arguments[i];
            NSString *value = i + 1 < [arguments count] ? arguments[i + 1] : nil;
            if([argument isEqualToString:@"--load"] && value) {
                if(dlopen([value fileSystemRepresentation], RTLD_LAZY) == NULL) { fprintf(stderr, "cannot load %s: %s\n", [value UTF8String], dlerror()); return 1; }
                i++;
            } else if([argument isEqualToString:@"--swift"] && value) {
                swiftTypeName = value;
                i++;
            } else if([argument isEqualToString:@"--sweep"] && value) {
                sweepDirectory = value;
                i++;
            } else if([argument isEqualToString:@"--frameworks"] && value) {
                frameworksLimit = (NSUInteger)[value integerValue];
                i++;
            } else if([argument hasPrefix:@"-"]) {
                rtb_usage();
                return 1;
            } else {
                className = argument;
            }
        }

        if(sweepDirectory) return rtb_sweep(sweepDirectory, frameworksLimit);

        if(swiftTypeName) {
            RTBSwiftType *type = [RTBSwiftTypes typeNamed:swiftTypeName];
            if(type == nil) { fprintf(stderr, "no Swift type named %s in the loaded images\n", [swiftTypeName UTF8String]); return 1; }
            printf("%s\n", [[type declaration] UTF8String]);
            return 0;
        }

        if(className == nil) className = @"NSString";
        Class klass = NSClassFromString(className);
        if(klass == Nil) {
            fprintf(stderr, "no class named %s\n", [className UTF8String]);
            return 1;
        }
        NSString *header = [RTBRuntimeHeader headerForClass:klass displayPropertiesDefaultValues:YES];
        printf("%s\n", [header UTF8String]);
    }

    return 0;
}
