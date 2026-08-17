//
//  RTBBundleLoadGuard.m
//  OCRuntime
//
//  See RTBBundleLoadGuard.h
//

#import "RTBBundleLoadGuard.h"
#import "RTBAppDelegate.h"

static NSString * const RTBLoadingBundlePathKey = @"RTBLoadingBundlePath";   // the bundle being loaded, if any
static NSString * const RTBSkippedBundlePathsKey = @"RTBSkippedBundlePaths"; // the bundles whose loading crashed the app

@implementation RTBBundleLoadGuard

+ (NSString *)relativePathForBundle:(NSBundle *)bundle {
    // relative to the system root, so that the paths survive a simulator runtime update
    NSString *path = [bundle bundlePath];
    NSString *systemRootPath = [RTBAppDelegate systemRootPath];
    if([systemRootPath length] > 0 && [path hasPrefix:systemRootPath]) {
        path = [path substringFromIndex:[systemRootPath length]];
    }
    return path;
}

+ (NSArray *)skippedBundlePaths {
    NSArray *paths = [[NSUserDefaults standardUserDefaults] arrayForKey:RTBSkippedBundlePathsKey];
    return paths ? paths : @[];
}

+ (void)setSkippedBundlePaths:(NSArray *)paths {
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:RTBSkippedBundlePathsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)bundlePathThatCrashedPreviousLaunch {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSString *path = [defaults stringForKey:RTBLoadingBundlePathKey];
    if(path == nil) return nil;

    [defaults removeObjectForKey:RTBLoadingBundlePathKey];

    NSMutableArray *paths = [[self skippedBundlePaths] mutableCopy];
    if([paths containsObject:path] == NO) [paths addObject:path];
    [self setSkippedBundlePaths:paths];

    NSLog(@"-- loading %@ crashed the previous run, Load All will skip it", path);

    return path;
}

+ (BOOL)shouldSkipBundle:(NSBundle *)bundle {
    return [[self skippedBundlePaths] containsObject:[self relativePathForBundle:bundle]];
}

+ (void)willLoadBundle:(NSBundle *)bundle {
    // written to disk right away, the app may not survive the load
    [[NSUserDefaults standardUserDefaults] setObject:[self relativePathForBundle:bundle] forKey:RTBLoadingBundlePathKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (void)didLoadBundle:(NSBundle *)bundle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:RTBLoadingBundlePathKey];

    NSString *path = [self relativePathForBundle:bundle];
    NSArray *paths = [self skippedBundlePaths];
    if([bundle isLoaded] && [paths containsObject:path]) {
        // loaded fine after all, eg. explicitly by the user
        NSMutableArray *ma = [paths mutableCopy];
        [ma removeObject:path];
        [self setSkippedBundlePaths:ma];
    }

    [defaults synchronize];
}

@end
