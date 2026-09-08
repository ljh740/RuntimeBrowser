//
//  RTBTreeTVC.h
//  OCRuntime
//
//  Created by Nicolas Seriot on 7/17/13.
//  Copyright (c) 2013 Nicolas Seriot. All rights reserved.
//

#import <UIKit/UIKit.h>

@class RTBClassDisplayVC;
@class RTBRuntime;

@interface RTBTreeTVC : UITableViewController <UITableViewDataSource, UITableViewDelegate>

@property BOOL isSubLevel;
@property (nonatomic, strong) NSArray *classStubs;
@property (nonatomic, strong) RTBRuntime *allClasses;
@property (nonatomic, strong) RTBClassDisplayVC *classDisplayVC;

@end
