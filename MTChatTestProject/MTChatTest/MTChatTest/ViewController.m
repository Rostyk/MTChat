//
//  ViewController.m
//  MTChatTest
//
//  Created by Rostyslav Stepanyak on 5/27/17.
//  Copyright © 2017 Rostyslav.Stepanyak. All rights reserved.
//

#import "ViewController.h"
@import MTChat;

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    MTChatViewController *chatViewController = [MTChatViewController new];
    chatViewController.senderDisplayName = @"User1";
    chatViewController.channelId = @"hockey";
    chatViewController.senderId = @"user1";
    
    [self.navigationController pushViewController:chatViewController animated:YES];

}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
