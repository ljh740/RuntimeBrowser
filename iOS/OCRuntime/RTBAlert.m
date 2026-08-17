//
//  RTBAlert.m
//  OCRuntime
//
//  See RTBAlert.h
//

#import "RTBAlert.h"

@implementation RTBAlert

static NSMutableArray *rtb_pendingAlerts = nil; // UIAlertController, presented one at a time
static BOOL rtb_isPresentingAlert = NO;

+ (UIViewController *)topViewController {
    UIViewController *vc = nil;
    for(UIWindow *window in [UIApplication sharedApplication].windows) {
        if(window.isKeyWindow) { vc = window.rootViewController; break; }
    }
    if(vc == nil) vc = [[UIApplication sharedApplication].windows firstObject].rootViewController;
    while(vc.presentedViewController && vc.presentedViewController.isBeingDismissed == NO) {
        vc = vc.presentedViewController;
    }
    return vc;
}

+ (void)presentNextAlert {
    if(rtb_isPresentingAlert || [rtb_pendingAlerts count] == 0) return;

    UIViewController *top = [self topViewController];
    if(top == nil) return;

    UIAlertController *alert = [rtb_pendingAlerts firstObject];
    [rtb_pendingAlerts removeObjectAtIndex:0];
    rtb_isPresentingAlert = YES;
    [top presentViewController:alert animated:YES completion:nil];
}

+ (void)alertDidEnd {
    rtb_isPresentingAlert = NO;
    // the dismissal of the previous alert is animated, wait for it before presenting the next one
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self presentNextAlert];
    });
}

+ (void)enqueueAlert:(UIAlertController *)alert {
    if(rtb_pendingAlerts == nil) rtb_pendingAlerts = [NSMutableArray array];
    [rtb_pendingAlerts addObject:alert];
    [self presentNextAlert];
}

+ (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self alertDidEnd];
        }]];
        [self enqueueAlert:alert];
    });
}

+ (void)showTextInputAlertWithTitle:(NSString *)title
                            message:(NSString *)message
                        cancelTitle:(NSString *)cancelTitle
                       cancelAction:(void (^)(void))cancelAction
                            okTitle:(NSString *)okTitle
                           okAction:(void (^)(NSString *text))okAction {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:cancelTitle style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
            if(cancelAction) cancelAction();
            [self alertDidEnd];
        }]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:okTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *text = [[weakAlert.textFields firstObject] text];
            if(okAction) okAction(text ? text : @"");
            [self alertDidEnd];
        }]];
        [self enqueueAlert:alert];
    });
}

@end
