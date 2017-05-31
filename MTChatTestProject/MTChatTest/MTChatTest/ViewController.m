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
    chatViewController.senderAvatarURL = @"https://images-na.ssl-images-amazon.com/images/M/MV5BNzQzNDMxMjQxNF5BMl5BanBnXkFtZTYwMTc5NTI2._V1_UY317_CR7,0,214,317_AL_.jpg";
    
    [self.navigationController pushViewController:chatViewController animated:YES];

}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
