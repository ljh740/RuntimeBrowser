//
//  RTBCategories.h
//  RuntimeBrowser
//
//  Which category a method comes from, without symbols.
//
//  The runtime attaches the method lists of a category to its class by reference, so a Method
//  points inside the method list of the category that declares it. The __objc_catlist sections
//  of the loaded images tell where these lists are, and how the categories are named.
//
//  This only works for the images outside of the dyld shared cache: the cache builder merges
//  the categories of a class into one list, only the symbol names remember them there.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface RTBCategories : NSObject

// The name of the category declaring the method, nil if unknown (class methods, or a category of an image in the shared cache).
+ (NSString *)categoryNameForMethod:(Method)method;

@end
