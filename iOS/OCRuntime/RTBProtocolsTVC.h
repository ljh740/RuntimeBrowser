//
//  RTBProtocolsTVC.h
//  OCRuntime
//
//  Created by Nicolas Seriot on 27/04/15.
//  Copyright (c) 2015 Nicolas Seriot. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface RTBProtocolsTVC : UITableViewController

@property (nonatomic, strong) NSArray *protocolStubs;
@property (nonatomic, strong) NSMutableArray *protocolStubsDictionaries; // [{'A':classStubs}, {'B':classStubs}]

@end
