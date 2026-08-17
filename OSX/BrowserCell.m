//
//  BrowserCell.m
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 2/21/11.
//  Copyright 2011 IICT. All rights reserved.
//

#import "BrowserCell.h"
#import "RTBProtocol.h"
#import "RTBClass.h"
#import "RTBSwiftTypes.h"
#import "BrowserNode.h"

@implementation BrowserCell

+ (NSImage *)branchImage {
    return nil;
}

+ (NSImage *)highlightedBranchImage {
    return nil;
}

+ (void)thisClassIsPartOfTheRuntimeBrowser {}

- (NSImage *)iconForPath:(NSString *)s {
    
    NSString *appExtension = @".app";
    NSRange range = [s rangeOfString:appExtension];
    if(range.location != NSNotFound) {
        NSString *path = [s substringToIndex:(range.location + [appExtension length])];
        return [[NSWorkspace sharedWorkspace] iconForFile:path];
    }
    
    NSArray *extensions = @[@".dylib", @".framework", @".bundle"];
    for(NSString *ext in extensions) {
        if([s rangeOfString:ext].location != NSNotFound) return [NSImage imageNamed:@"framework.tiff"];
    }
    
    return [NSImage imageNamed:@"class.tiff"];
}

- (void)setObjectValue:(id)obj {
    
    NSImage *icon = nil;
    NSString *objectValue = nil;
    
    if([obj isKindOfClass:[RTBProtocol class]]) {
        icon = [NSImage imageNamed:@"protocol.tiff"];
        objectValue = [obj nodeName];
    } else if([obj isKindOfClass:[RTBClass class]]) {
        icon = [NSImage imageNamed:@"class.tiff"];
        objectValue = [obj nodeName];
    } else if([obj isKindOfClass:[RTBSwiftType class]]) {
        icon = [NSImage imageNamed:[(RTBSwiftType *)obj kind] == RTBSwiftTypeKindProtocol ? @"protocol.tiff" : @"class2.tiff"];
        objectValue = [obj nodeName];
    } else if([obj isKindOfClass:[SwiftTypesNode class]]) {
        icon = [obj icon];
        objectValue = [obj nodeName];
    } else if([obj isKindOfClass:[BrowserNode class]]) {
        icon = [self iconForPath:[obj nodeName]];
        objectValue = [[obj nodeName] lastPathComponent];
    }
    
    [icon setSize:NSMakeSize(16,16)];
    
    [self setImage:icon];
    
    [super setObjectValue:objectValue];
}

@end
