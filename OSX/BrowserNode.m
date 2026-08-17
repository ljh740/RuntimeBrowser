//
//  RootItem.m
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 2/20/11.
//  Copyright 2011 seriot.ch. All rights reserved.
//

#import "BrowserNode.h"
#import "RTBRuntime.h"
#import "RTBProtocol.h"
#import "RTBSwiftTypes.h"

@implementation BrowserNode

+ (BrowserNode *)rootNodeList {
	BrowserNode *rn = [[BrowserNode alloc] init];
	rn.children = [[RTBRuntime sharedInstance] sortedClassStubs];
	return rn;
}

+ (BrowserNode *)rootNodeTree {
	BrowserNode *rn = [[BrowserNode alloc] init];
	rn.children = [[RTBRuntime sharedInstance] rootClasses];
	return rn;
}

+ (BrowserNode *)rootNodeImages {
	BrowserNode *bn = [[BrowserNode alloc] init];
	
	NSDictionary *allStubsByImage = [RTBRuntime sharedInstance].allClassStubsByImagePath;
	
	NSMutableArray *images = [NSMutableArray array];
	
	for(NSString *image in [allStubsByImage allKeys]) {
		BrowserNode *node = [[BrowserNode alloc] init];
		node.nodeName = image;
		NSMutableArray *stubs = [NSMutableArray arrayWithArray:[allStubsByImage valueForKey:image]];
		[stubs sortUsingSelector:@selector(compare:)];
		if([RTBSwiftTypes imageAtPathHasSwiftTypes:image]) {
			[stubs insertObject:[SwiftTypesNode nodeForImageAtPath:image] atIndex:0]; // first, before the classes
		}
		node.children = stubs;
		[images addObject:node];
	}
	
	[images sortUsingSelector:@selector(compare:)]; // TODO: sort by lastPathComponent?
	
	bn.nodeName = @"Images";
	bn.children = images;
	return bn;
}

+ (BrowserNode *)rootNodeProtocols {
    BrowserNode *bn = [[BrowserNode alloc] init];
    
    bn.nodeName = @"Protocols";
    bn.children = [[RTBRuntime sharedInstance] sortedProtocolStubs];
    
    return bn;
}

- (NSImage *)icon {

    NSArray *extensions = @[@".app", @".framework", @".bundle", @".dylib"];
    for(NSString *ext in extensions) {
        NSRange range = [_nodeName rangeOfString:ext];
        if(range.location != NSNotFound) {
            NSString *bundlePath = [_nodeName substringToIndex:(range.location + [ext length])];
            return [[NSWorkspace sharedWorkspace] iconForFile:bundlePath];
        }
    }

    return nil;
}

+ (void)thisClassIsPartOfTheRuntimeBrowser {}

- (NSComparisonResult)compare:(BrowserNode *)otherNode {
    return [_nodeName compare:[otherNode nodeName]];
}

- (NSString *)nodeInfo {
    NSArray *pathComponents = [_nodeName componentsSeparatedByString:@"/"];
    return [NSString stringWithFormat:@"%@ (%lu)", [pathComponents lastObject], (unsigned long)[_children count]];
}

- (BOOL)canBeSavedAsHeader {
	return NO;
}

@end

@implementation SwiftTypesNode

+ (SwiftTypesNode *)nodeForImageAtPath:(NSString *)imagePath {
    SwiftTypesNode *node = [[SwiftTypesNode alloc] init];
    node.imagePath = imagePath;
    return node;
}

- (NSArray *)children {
    if([super children] == nil) {
        [super setChildren:[RTBSwiftTypes typesInImageAtPath:_imagePath]];
    }
    return [super children];
}

- (NSString *)nodeName {
    return [NSString stringWithFormat:@"Swift types (%lu)", (unsigned long)[[self children] count]];
}

- (NSString *)nodeInfo {
    return [self nodeName];
}

- (NSImage *)icon {
    return [NSImage imageNamed:@"class2.tiff"];
}

@end
