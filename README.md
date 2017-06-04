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
# Backend. Firebase database and storage for photos

![alt text](https://www.dropbox.com/s/e3weh8x3de7y4ff/firebasedatabase.png?dl=1)
<br>
`Channels` contain the list of channels. `Messages` keep the conversation history. Appending new node in `messages` will automatically result in new incoming message. 

## Messages
There're two types of messages:
1. Text message
2. Photo message

### Text message
It consists of:
* `senderId`. A simple unique id of the user who sent the message. Should not contain special symbols llike @, /, "", etc.
* `senderName`. A name of the user that sent a message. It will show up visually in the chat.
* `text`. Text of the message.

### Photo message
It consists of:
* `photoURL`. The url of to the photo in the Firebase Storate.
* `senderId`. A simple unique id of the user who sent the message. Should not contain special symbols llike @, /, "", etc.

## Firebase Storage
![alt text](https://www.dropbox.com/s/ok7xaw3szmk9k8b/firebasestorage.png?dl=1)
<br>
The storage persis all the images sent in chat. In this example the structure of the storage is the following:
Every user has its own foler in the root folder of the storage. Folder name is the user id and the filename of the picture inside that folder is just the time when user sent that picture.
`Firebase.auth().currenuser().uid()/[timestamp].jpg`
