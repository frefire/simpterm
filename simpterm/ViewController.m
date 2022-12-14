//
//  ViewController.m
//  simpterm
//
//  Created by Eric Wong on 2022/12/12.
//

#import "ViewController.h"
#import "CmdResponder.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    UITextField *cmdInput = [[UITextField alloc]
                             initWithFrame:CGRectMake(20, 60, 300, 30)];
    
    cmdInput.borderStyle = UITextBorderStyleRoundedRect;
    cmdInput.delegate = self;
    cmdInput.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.view addSubview:cmdInput];
    [cmdInput becomeFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    //[textField resignFirstResponder];
    if ([textField.text isEqualToString:@""] && self.lastCmd != nil) {
        NSLog(@"%@", cmdRespond(self.lastCmd));
    } else {
        NSLog(@"%@", cmdRespond(textField.text));
        self.lastCmd = textField.text;
        textField.text = nil;
    }
    return YES;
}

@end
