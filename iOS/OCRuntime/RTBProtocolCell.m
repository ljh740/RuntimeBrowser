//
//  ClassCell.m
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 13.08.08.
//  Copyright 2008 seriot.ch. All rights reserved.
//

#import "RTBProtocolCell.h"

@interface RTBProtocolCell ()
@property (nonatomic, strong) IBOutlet UILabel *label;
@property (nonatomic, strong) IBOutlet UIButton *button;
@end

@implementation RTBProtocolCell

- (void)awakeFromNib {
    [super awakeFromNib];

    UIFontDescriptor *descriptor = [[UIFont preferredFontForTextStyle:UIFontTextStyleBody].fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic];
    self.label.font = [UIFont fontWithDescriptor:descriptor size:0.0];
    self.label.adjustsFontForContentSizeCategory = YES;

    self.button.translatesAutoresizingMaskIntoConstraints = NO;
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.button.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [self.button.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.button.widthAnchor constraintEqualToConstant:32.0],
        [self.button.heightAnchor constraintEqualToConstant:32.0],
        [self.label.leadingAnchor constraintEqualToAnchor:self.button.trailingAnchor constant:8.0],
        [self.label.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        [self.label.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8.0],
        [self.label.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        [self.label.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
    ]];

    [self.button setTitle:nil forState:UIControlStateNormal];
    self.button.accessibilityLabel = NSLocalizedString(@"Show Header", nil);
}

- (void)setProtocolObject:(RTBProtocol *)p {
    _protocolObject = p;
    _label.text = [p protocolName];
    self.accessoryType = [p hasChildren] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
}

- (IBAction)showHeaders:(id)sender {
    // TODO: use a notification here
	id appDelegate = [[UIApplication sharedApplication] delegate];
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
	[appDelegate performSelector:@selector(showHeaderForProtocol:) withObject:_protocolObject];
#pragma clang diagnostic pop
}

@end
