//
//  SearchViewController.h
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 18.01.09.
//  Copyright 2009 Sen:te. All rights reserved.
//

#import <UIKit/UIKit.h>

@class RTBRuntime;

@interface RTBSearchVC : UIViewController <UITableViewDataSource, UISearchBarDelegate>

@property (nonatomic, strong) NSMutableArray *foundClasses;
@property (nonatomic, strong) RTBRuntime *allClasses;

@property (nonatomic, strong) IBOutlet UISearchBar *theSearchBar;
@property (nonatomic, strong) IBOutlet UITableView *tableView;

@end
