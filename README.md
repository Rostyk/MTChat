![alt text](https://www.dropbox.com/s/k0y1g9a6ea8an0b/logo.png?dl=1)
<br>
# MTChat
Maliwan chat backed back-ended with Firebase.
<br>
# Features
- Typing indicator
- Photo messages
- Avatars as urls or as iamges

# How to integrate

1. Add `MTChat.framework` to the project.

 ![alt text](https://www.dropbox.com/s/3evc6bqqq4dhtsd/mtchattestproj.png?dl=1)
 
<br>

2. Subclass from main chat view controller:
 ```
 @class MTChatViewController;
 
 @interface MyChatViewController : MTChatViewController {
 }
 
 @end
```
<br>

3. Add the `chatDidLoad` and `onError` handling block inside MyChatViewController.m:

```
#import "MyChatViewController.h"

@import MTChat;

@implementation MyChatViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  
  //show spinner here
  self.onChatDidLoad = ^{
     //[weakSelf removeSpinner];
  };
  
  self.onError = ^(NSError *error) {
     NSLog(@"Eror: %@", error.localizedDescription);
  };
  
}
@end
```
<br>

4. Instantiate your chat view controller and set display name and avatars:
```
MyChatViewController *chatViewController = [[MyChatViewController alloc] init];
chatViewController.senderDisplayName = @"User2";
chatViewController.channelId = @"hockey";
chatViewController.senderId = @"user2";
    
chatViewController.ownAvatarURL = @"https://encrypted-tbn0.gstatic.com/images?q=tbn:ANd9GcRE6Jn-YODWU_Ra92q8sEQdFdlB1D6FBePwNhr3PeCAgPzuZugt";
chatViewController.senderAvatarURL = @"https://images-na.ssl-images-amazon.com/images/M/MV5BNzQzNDMxMjQxNF5BMl5BanBnXkFtZTYwMTc5NTI2._V1_UY317_CR7,0,214,317_AL_.jpg";
    
[self.navigationController pushViewController:chatViewController animated:YES];
```
