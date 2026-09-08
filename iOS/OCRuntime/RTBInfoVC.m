//
//  InfoViewController.m
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 25.01.09.
//  Copyright 2009 Sen:te. All rights reserved.
//

#import "RTBInfoVC.h"
#import "RTBAppDelegate.h"
#import "GCDWebServer.h"

@interface RTBInfoVC ()

@property (nonatomic, strong) IBOutlet UITextView *aboutTextView;
@property (nonatomic, strong) IBOutlet UIButton *websiteButton;
@property (nonatomic, strong) IBOutlet UILabel *webServerStatusLabel;
@property (nonatomic, strong) IBOutlet UILabel *showOCRuntimeClassesLabel;
@property (nonatomic, strong) IBOutlet UILabel *addCommentForBlocksLabel;
@property (nonatomic, strong) IBOutlet UILabel *simplifiedSwiftTypesLabel;
@property (nonatomic, strong) IBOutlet UILabel *toggleWebServerLabel;

@property (nonatomic, strong) IBOutlet UISwitch *showOCRuntimeClassesSwitch;
@property (nonatomic, strong) IBOutlet UISwitch *addCommentForBlocksSwitch;
@property (nonatomic, strong) IBOutlet UISwitch *toggleWebServerSwitch;
@property (nonatomic, strong) IBOutlet UISwitch *simplifiedSwiftTypesSwitch;

@end

@implementation RTBInfoVC

- (UIStackView *)settingsRowWithLabel:(UILabel *)label control:(UISwitch *)control {
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentNatural;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12.0;
    return row;
}

- (void)setupAdaptiveLayout {
    UILabel *aboutLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    aboutLabel.text = self.aboutTextView.text;
    aboutLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    aboutLabel.adjustsFontForContentSizeCategory = YES;
    aboutLabel.numberOfLines = 0;
    [self.aboutTextView removeFromSuperview];

    [self.websiteButton setAttributedTitle:nil forState:UIControlStateNormal];
    [self.websiteButton setTitle:@"github.com/nst/RuntimeBrowser" forState:UIControlStateNormal];
    self.websiteButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.websiteButton.titleLabel.adjustsFontForContentSizeCategory = YES;

    self.webServerStatusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.webServerStatusLabel.adjustsFontForContentSizeCategory = YES;
    self.webServerStatusLabel.numberOfLines = 0;

    UIStackView *settings = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self settingsRowWithLabel:self.simplifiedSwiftTypesLabel control:self.simplifiedSwiftTypesSwitch],
        [self settingsRowWithLabel:self.addCommentForBlocksLabel control:self.addCommentForBlocksSwitch],
        [self settingsRowWithLabel:self.showOCRuntimeClassesLabel control:self.showOCRuntimeClassesSwitch],
        [self settingsRowWithLabel:self.toggleWebServerLabel control:self.toggleWebServerSwitch]
    ]];
    settings.axis = UILayoutConstraintAxisVertical;
    settings.spacing = 16.0;

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        aboutLabel,
        self.websiteButton,
        settings,
        self.webServerStatusLabel
    ]];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = 24.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:scrollView];
    [scrollView addSubview:content];

    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scrollView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [scrollView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor constant:20.0],
        [content.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor constant:-20.0],
        [content.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:20.0],
        [content.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-20.0],
        [content.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor constant:-40.0]
    ]];
}

//- (void)dismissModalView:(id)sender {
//	[self dismissViewControllerAnimated:YES completion:nil];
//}

- (void)updateWebServerStatus {
	RTBAppDelegate *appDelegate = (RTBAppDelegate *)[[UIApplication sharedApplication] delegate];
	NSString *serverURL = [NSString stringWithFormat:@"http://%@:%d/", [appDelegate myIPAddress], [appDelegate serverPort]];
	_webServerStatusLabel.text = [[appDelegate webServer] isRunning] ? serverURL : @"";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [_showOCRuntimeClassesSwitch setOn:[[[NSUserDefaults standardUserDefaults] valueForKey:@"RTBShowOCRuntimeClasses"] boolValue]];
    [_addCommentForBlocksSwitch setOn:[[[NSUserDefaults standardUserDefaults] valueForKey:@"RTBAddCommentsForBlocks"] boolValue]];
    [_toggleWebServerSwitch setOn:[[[NSUserDefaults standardUserDefaults] valueForKey:@"RTBEnableWebServer"] boolValue]];
    [_simplifiedSwiftTypesSwitch setOn:[[NSUserDefaults standardUserDefaults] boolForKey:@"RTBSimplifiedSwiftTypes"]];

    [self updateWebServerStatus];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = NSLocalizedString(@"About", nil);
    if(@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    }
    [self setupAdaptiveLayout];
}

- (IBAction)openWebSiteAction:(id)sender {
	[[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/nst/RuntimeBrowser/"] options:@{} completionHandler:nil];
}

- (IBAction)showOCRuntimeClassesAction:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:((UISwitch *)sender).isOn forKey:@"RTBShowOCRuntimeClasses"];
}

- (IBAction)addBlockCommentsAction:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:((UISwitch *)sender).isOn forKey:@"RTBAddCommentsForBlocks"];
}

- (IBAction)simplifySwiftTypesAction:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:((UISwitch *)sender).isOn forKey:@"RTBSimplifiedSwiftTypes"];
}

- (IBAction)toggleWebServerAction:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:((UISwitch *)sender).isOn forKey:@"RTBEnableWebServer"];

    RTBAppDelegate *appDelegate = (RTBAppDelegate *)[[UIApplication sharedApplication] delegate];

    if(((UISwitch *)sender).isOn) {
        [appDelegate startWebServer];
    } else {
        [appDelegate stopWebServer];
    }
    
    [self updateWebServerStatus];
}

@end
