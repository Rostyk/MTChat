//
//  MTChatViewController.m
//  MTChat
//
//  Created by Rostyslav Stepanyak on 5/27/17.
//  Copyright © 2017 Rostyslav.Stepanyak. All rights reserved.
//

#import "MTChatViewController.h"
#import <FirebaseAnalytics/FirebaseAnalytics.h>
#import <FirebaseCore/FirebaseCore.h>


@interface MTChatViewController ()

@end

@implementation MTChatViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [FIRApp configure];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
