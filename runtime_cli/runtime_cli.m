#import <Foundation/Foundation.h>
#import "RTBRuntimeHeader.h"
#import "RTBTypeDecoder.h"

// runtime_cli [ClassName]
// prints the header of the class as RuntimeBrowser sees it, NSString by default

int main (int argc, const char * argv[]) {

    @autoreleasepool {
        NSString *className = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"NSString";
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
