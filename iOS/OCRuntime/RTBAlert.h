//
//  RTBAlert.h
//  OCRuntime
//
//  UIAlertController conveniences, replacing UIAlertView. The alerts are queued and
//  presented one after the other on the topmost view controller.
//

#import <UIKit/UIKit.h>

@interface RTBAlert : NSObject

// an alert with an OK button
+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)message;

// an alert with a text field; okAction receives the text, cancelAction may be nil
+ (void)showTextInputAlertWithTitle:(NSString *)title
                            message:(NSString *)message
                        cancelTitle:(NSString *)cancelTitle
                       cancelAction:(void (^)(void))cancelAction
                            okTitle:(NSString *)okTitle
                           okAction:(void (^)(NSString *text))okAction;

@end
