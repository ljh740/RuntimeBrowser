//
//  NSTextView+SyntaxColoring.h
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 04.08.08.
//  Copyright 2008 seriot.ch. All rights reserved.
//

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

@interface NSString (SyntaxColoring)

// keywords and classes are colored when they appear as whole words, comments and @directives always
- (NSAttributedString *)colorizeWithKeywords:(NSArray *)keywords classes:(NSArray *)classes colorize:(BOOL)colorize;

// The keywords of the Swift declarations, see RTBSwiftTypes.h
+ (NSArray *)swiftKeywords;

@end
