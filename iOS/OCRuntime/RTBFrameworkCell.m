//
//  FrameworkCell.m
//  RuntimeBrowser
//
//  Created by Nicolas Seriot on 01.09.08.
//  Copyright 2008 seriot.ch. All rights reserved.
//

#import "RTBFrameworkCell.h"

@interface RTBFrameworkCell ()
@property (nonatomic, strong) IBOutlet UILabel *label;
@property (nonatomic, strong) IBOutlet UIImageView *frameworkImageView;
@end

@implementation RTBFrameworkCell

- (void)awakeFromNib {
    [super awakeFromNib];

    self.label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.label.adjustsFontForContentSizeCategory = YES;

    self.frameworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.frameworkImageView.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [self.frameworkImageView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [self.frameworkImageView.widthAnchor constraintEqualToConstant:32.0],
        [self.frameworkImageView.heightAnchor constraintEqualToConstant:32.0],
        [self.label.leadingAnchor constraintEqualToAnchor:self.frameworkImageView.trailingAnchor constant:8.0],
        [self.label.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        [self.label.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8.0],
        [self.label.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        [self.label.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
    ]];
}

- (void)setFrameworkName:(NSString *)frameworkName {
    self.label.text = frameworkName;
}

- (NSString *)frameworkName {
    return self.label.text;
}

- (void)setSkipped:(BOOL)skipped {
    _skipped = skipped;
    self.label.enabled = !skipped;
}

/*
- (id)initWithFrame:(CGRect)frame reuseIdentifier:(NSString *)reuseIdentifier {
	if (self = [super initWithFrame:frame reuseIdentifier:reuseIdentifier]) {
		// Initialization code
	}
	return self;
}


- (void)setSelected:(BOOL)selected animated:(BOOL)animated {

	[super setSelected:selected animated:animated];

	// Configure the view for the selected state
}


- (void)dealloc {
	[super dealloc];
}
*/

@end
