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
    chatViewController.senderDisplayName = @"User2";
    chatViewController.channelId = @"hockey";
    chatViewController.senderId = @"user2";
    chatViewController.ownAvatarURL = @"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRE6Jn-YODWU_Ra92q8sEQdFdlB1D6FBePwNhr3PeCAgPzuZugt";
    chatViewController.senderAvatarURL = @"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcQwSQJ7mzN7EwBJtakY040DVy4MEs9jQXVe92jc1m1JVWZtnSzO";
    
    [self.navigationController pushViewController:chatViewController animated:YES];

}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
