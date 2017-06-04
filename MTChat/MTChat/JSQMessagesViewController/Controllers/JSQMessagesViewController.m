//
//  Created by Jesse Squires
//  http://www.jessesquires.com
//
//
//  Documentation
//  http://cocoadocs.org/docsets/JSQMessagesViewController
//
//
//  GitHub
//  https://github.com/jessesquires/JSQMessagesViewController
//
//
//  License
//  Copyright (c) 2014 Jesse Squires
//  Released under an MIT license: http://opensource.org/licenses/MIT
//

#import "JSQMessagesViewController.h"
#import "JSQMessagesCollectionViewFlowLayoutInvalidationContext.h"
#import "JSQMessagesAvatarImageFactory.h"
#import "UIImage+animatedGIF.h"
#import "JSQPhotoMediaItem.h"
#import "JSQMessage.h"
#import "JSQMessageData.h"
#import "JSQMessageBubbleImageDataSource.h"
#import "JSQMessageAvatarImageDataSource.h"

#import "JSQMessagesCollectionViewCellIncoming.h"
#import "JSQMessagesCollectionViewCellOutgoing.h"

#import "JSQMessagesTypingIndicatorFooterView.h"
#import "JSQMessagesLoadEarlierHeaderView.h"

#import "NSString+JSQMessages.h"
#import "NSBundle+JSQMessages.h"
#import "JSQMessagesBubbleImageFactory.h"
#import "UIColor+JSQMessages.h"

#import <FirebaseStorage/FirebaseStorage.h>
#import <FirebaseCore/FirebaseCore.h>
#import <FirebaseAuth/FirebaseAuth.h>
#import <FirebaseDatabase/FirebaseDatabase.h>
#import "JTSImageViewController.h"
#import "PINCache.h"
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define     CHAT_ERROR_DOMAIN            @"MTChatDomain"
#define     imageURLNotSetKey            @"NOTSET"

// Fixes rdar://26295020
// See issue #1247 and Peter Steinberger's comment:
// https://github.com/jessesquires/JSQMessagesViewController/issues/1247#issuecomment-219386199
// Gist with workaround: https://gist.github.com/steipete/b00fc02aa9f1c66c11d0f996b1ba1265
// Forgive me
static IMP JSQReplaceMethodWithBlock(Class c, SEL origSEL, id block) {
    NSCParameterAssert(block);

    // get original method
    Method origMethod = class_getInstanceMethod(c, origSEL);
    NSCParameterAssert(origMethod);

    // convert block to IMP trampoline and replace method implementation
    IMP newIMP = imp_implementationWithBlock(block);

    // Try adding the method if not yet in the current class
    if (!class_addMethod(c, origSEL, newIMP, method_getTypeEncoding(origMethod))) {
        return method_setImplementation(origMethod, newIMP);
    } else {
        return method_getImplementation(origMethod);
    }
}

static void JSQInstallWorkaroundForSheetPresentationIssue26295020(void) {
    __block void (^removeWorkaround)(void) = ^{};
    const void (^installWorkaround)(void) = ^{
        const SEL presentSEL = @selector(presentViewController:animated:completion:);
        __block IMP origIMP = JSQReplaceMethodWithBlock(UIViewController.class, presentSEL, ^(UIViewController *self, id vC, BOOL animated, id completion) {
            UIViewController *targetVC = self;
            while (targetVC.presentedViewController) {
                targetVC = targetVC.presentedViewController;
            }
            ((void (*)(id, SEL, id, BOOL, id))origIMP)(targetVC, presentSEL, vC, animated, completion);
        });
        removeWorkaround = ^{
            Method origMethod = class_getInstanceMethod(UIViewController.class, presentSEL);
            NSCParameterAssert(origMethod);
            class_replaceMethod(UIViewController.class,
                                presentSEL,
                                origIMP,
                                method_getTypeEncoding(origMethod));
        };
    };

    const SEL presentSheetSEL = NSSelectorFromString(@"presentSheetFromRect:");
    const void (^swizzleOnClass)(Class k) = ^(Class klass) {
        const __block IMP origIMP = JSQReplaceMethodWithBlock(klass, presentSheetSEL, ^(id self, CGRect rect) {
            // Before calling the original implementation, we swizzle the presentation logic on UIViewController
            installWorkaround();
            // UIKit later presents the sheet on [view.window rootViewController];
            // See https://github.com/WebKit/webkit/blob/1aceb9ed7a42d0a5ed11558c72bcd57068b642e7/Source/WebKit2/UIProcess/ios/WKActionSheet.mm#L102
            // Our workaround forwards this to the topmost presentedViewController instead.
            ((void (*)(id, SEL, CGRect))origIMP)(self, presentSheetSEL, rect);
            // Cleaning up again - this workaround would swallow bugs if we let it be there.
            removeWorkaround();
        });
    };

    // _UIRotatingAlertController
    Class alertClass = NSClassFromString([NSString stringWithFormat:@"%@%@%@", @"_U", @"IRotat", @"ingAlertController"]);
    if (alertClass) {
        swizzleOnClass(alertClass);
    }

    // WKActionSheet
    Class actionSheetClass = NSClassFromString([NSString stringWithFormat:@"%@%@%@", @"W", @"KActio", @"nSheet"]);
    if (actionSheetClass) {
        swizzleOnClass(actionSheetClass);
    }
}


@interface JSQMessagesViewController () <JSQMessagesInputToolbarDelegate, UIImagePickerControllerDelegate>

@property (weak, nonatomic) IBOutlet JSQMessagesCollectionView *collectionView;
@property (strong, nonatomic) IBOutlet JSQMessagesInputToolbar *inputToolbar;

@property (nonatomic) NSLayoutConstraint *toolbarHeightConstraint;
@property (strong, nonatomic) NSIndexPath *selectedIndexPathForMenu;

@property (nonatomic, strong) NSMutableArray *messages;

@property (nonatomic, strong) id<JSQMessageBubbleImageDataSource> outgoingBubbleImageView;
@property (nonatomic, strong) id<JSQMessageBubbleImageDataSource> incomingBubbleImageView;

@property (nonatomic, strong) FIRDatabaseReference *channelRef;
@property (nonatomic, strong) FIRDatabaseReference *messageRef;
@property (nonatomic, strong) FIRDatabaseReference *userIsTypingRef;
@property (nonatomic, strong) FIRDatabaseQuery *userIsTypingQuery;
@property (nonatomic) BOOL localTyping;
@property (nonatomic) BOOL isTyping;
@property (nonatomic) BOOL alreadyLoaded;
@property (nonatomic) FIRDatabaseHandle newMessageRefHandle;
@property (nonatomic) FIRDatabaseHandle updatedMessageRefHandle;
@property (nonatomic, strong) FIRStorageReference *storageRef;
@property (nonatomic, strong) NSMutableDictionary *photoMessageMap;

@property (nonatomic, strong) JSQMessagesAvatarImageFactory *avatarImageFactory;
@end


@implementation JSQMessagesViewController

#pragma mark - Class methods

+ (UINib *)nib
{
    return [UINib nibWithNibName:NSStringFromClass([JSQMessagesViewController class])
                          bundle:[NSBundle bundleForClass:[JSQMessagesViewController class]]];
}

+ (instancetype)messagesViewController
{
    return [[[self class] alloc] initWithNibName:NSStringFromClass([JSQMessagesViewController class])
                                          bundle:[NSBundle bundleForClass:[JSQMessagesViewController class]]];
}

+ (void)initialize {
    [super initialize];
    if (self == [JSQMessagesViewController self]) {
        JSQInstallWorkaroundForSheetPresentationIssue26295020();
    }
}

- (id<JSQMessageBubbleImageDataSource>)setupOutgoingBubble {
    JSQMessagesBubbleImageFactory *factory = [JSQMessagesBubbleImageFactory new];
    return [factory outgoingMessagesBubbleImageWithColor:[UIColor jsq_messageBubbleBlueColor]];
}

- (id<JSQMessageBubbleImageDataSource>)setupIncomingBubble {
    JSQMessagesBubbleImageFactory *factory = [JSQMessagesBubbleImageFactory new];
    return [factory outgoingMessagesBubbleImageWithColor:[UIColor jsq_messageBubbleLightGrayColor]];
}

#pragma mark - access overrides

- (JSQMessagesAvatarImageFactory *)avatarImageFactory {
    if (!_avatarImageFactory) {
        _avatarImageFactory = [[JSQMessagesAvatarImageFactory alloc] initWithDiameter:_collectionView.collectionViewLayout.outgoingAvatarViewSize.width];
    }
    
    return _avatarImageFactory;
}

- (NSMutableDictionary *)photoMessageMap {
    if (!_photoMessageMap) {
        _photoMessageMap = [NSMutableDictionary new];
    }
    
    return _photoMessageMap;
}

- (FIRStorageReference *)storageRef {
    if (!_storageRef) {
        _storageRef = [[FIRStorage storage] referenceForURL:@"gs://betterthan-e5be9.appspot.com"];
    }
    
    return _storageRef;
}

- (FIRDatabaseQuery *)userIsTypingQuery {
    if (!_userIsTypingQuery) {
        _userIsTypingQuery = [[[self.channelRef child:@"typingIndicator"] queryOrderedByValue] queryEqualToValue:@(1)];
    }
    
    return _userIsTypingQuery;
}

- (FIRDatabaseReference *)userIsTypingRef {
    if (!_userIsTypingRef) {
        _userIsTypingRef =  [[self.channelRef child:@"typingIndicator"] child:_channelId];
    }
    
    return _userIsTypingRef;
}

- (NSMutableArray *)messages {
    if (!_messages) {
        _messages = [NSMutableArray new];
    }
    
    return _messages;
}

- (id<JSQMessageBubbleImageDataSource>)incomingBubbleImageView {
    if (!_incomingBubbleImageView) {
        _incomingBubbleImageView = [self setupIncomingBubble];
    }
    
    return _incomingBubbleImageView;
}

- (id<JSQMessageBubbleImageDataSource>)outgoingBubbleImageView {
    if (!_outgoingBubbleImageView) {
        _outgoingBubbleImageView = [self setupOutgoingBubble];
    }
    
    return _outgoingBubbleImageView;
}

#pragma mark - Initialization

- (void)jsq_configureMessagesViewController
{
    self.view.backgroundColor = [UIColor whiteColor];

    self.toolbarHeightConstraint.constant = self.inputToolbar.preferredDefaultHeight;

    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;

    self.inputToolbar.delegate = self;
    self.inputToolbar.contentView.textView.placeHolder = [NSBundle jsq_localizedStringForKey:@"new_message"];
    self.inputToolbar.contentView.textView.accessibilityLabel = [NSBundle jsq_localizedStringForKey:@"new_message"];
    self.inputToolbar.contentView.textView.delegate = self;
    self.inputToolbar.contentView.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [self.inputToolbar removeFromSuperview];

    self.automaticallyScrollsToMostRecentMessage = YES;

    self.outgoingCellIdentifier = [JSQMessagesCollectionViewCellOutgoing cellReuseIdentifier];
    self.outgoingMediaCellIdentifier = [JSQMessagesCollectionViewCellOutgoing mediaCellReuseIdentifier];

    self.incomingCellIdentifier = [JSQMessagesCollectionViewCellIncoming cellReuseIdentifier];
    self.incomingMediaCellIdentifier = [JSQMessagesCollectionViewCellIncoming mediaCellReuseIdentifier];

    // NOTE: let this behavior be opt-in for now
    // [JSQMessagesCollectionViewCell registerMenuAction:@selector(delete:)];

    self.showTypingIndicator = NO;

    self.showLoadEarlierMessagesHeader = NO;

    self.additionalContentInset = UIEdgeInsetsZero;

    [self jsq_updateCollectionViewInsets];
}

#pragma mark - send messages

- (void)addMessage:(NSString *)senderId name:(NSString *)name text:(NSString *)text {
    JSQMessage *message = [[JSQMessage alloc] initWithSenderId:senderId
                                             senderDisplayName:name
                                                          date:[NSDate new]
                                                          text:text];
    [self.messages addObject:message];
}

- (void)addPhotoMessage:(NSString *)senderId key:(NSString *)key mediaItem:(JSQPhotoMediaItem *)mediaItem {
    JSQMessage *message = [[JSQMessage alloc] initWithSenderId:senderId
                                             senderDisplayName:@""
                                                          date:[NSDate new]
                                                         media:mediaItem];
    [self.messages addObject:message];
    
    if (mediaItem.image == nil) {
        [self.photoMessageMap setObject:mediaItem forKey:key];
    }
    
    [_collectionView reloadData];
}

- (NSString *)sendPhotoMessage {
    FIRDatabaseReference *itemRef = [self.messageRef childByAutoId];
    NSDictionary *messageItem = @{@"photoURL" : imageURLNotSetKey,
                                  @"senderId" : self.senderId};
    
    [itemRef setValue:messageItem];
    [self finishSendingMessage];
    
    return itemRef.key;
}

- (void)setImageURL:(NSString *)url forMessageWithKey:(NSString *)key {
    FIRDatabaseReference *itemRef = [self.messageRef child:key];
    [itemRef updateChildValues:@{@"photoURL" : url}];
}


#pragma mark - Setters

- (void)setShowTypingIndicator:(BOOL)showTypingIndicator
{
    if (_showTypingIndicator == showTypingIndicator) {
        return;
    }

    _showTypingIndicator = showTypingIndicator;
    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
    [self.collectionView.collectionViewLayout invalidateLayout];
}

- (void)setShowLoadEarlierMessagesHeader:(BOOL)showLoadEarlierMessagesHeader
{
    if (_showLoadEarlierMessagesHeader == showLoadEarlierMessagesHeader) {
        return;
    }

    _showLoadEarlierMessagesHeader = showLoadEarlierMessagesHeader;
    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
}

- (void)setAdditionalContentInset:(UIEdgeInsets)additionalContentInset
{
    _additionalContentInset = additionalContentInset;
    [self jsq_updateCollectionViewInsets];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    [[[self class] nib] instantiateWithOwner:self options:nil];

    [self jsq_configureMessagesViewController];
    [self jsq_registerForNotifications:YES];
    
    _collectionView.collectionViewLayout.incomingAvatarViewSize = CGSizeMake(32, 32);
    _collectionView.collectionViewLayout.outgoingAvatarViewSize = CGSizeMake(32, 32);
    [self setup];
}

- (void)setup {
    __weak typeof(self) weakSelf = self;
    
    dispatch_group_t group = dispatch_group_create();
    
    dispatch_group_enter(group);
    [FIRApp configure];
    [[FIRAuth auth] signInAnonymouslyWithCompletion:^(FIRUser * _Nullable user, NSError * _Nullable error) {
        if (error) {
            //handle the error
        }
        
        dispatch_group_leave(group);
    }];
    
    if (self.ownAvatarURL) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSURL *url = [NSURL URLWithString:self.ownAvatarURL];
            NSData *data = [NSData dataWithContentsOfURL:url];
            UIImage *img = [[UIImage alloc] initWithData:data];
            weakSelf.ownAvatarImage = img;
            
            dispatch_group_leave(group);
        });
    }
    else if (!self.ownAvatarImage) {
        self.ownAvatarImage = [UIImage imageNamed:@"chat_placeholder"];
    }
    
    if (self.senderAvatarURL) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSURL *url = [NSURL URLWithString:self.senderAvatarURL];
            NSData *data = [NSData dataWithContentsOfURL:url];
            UIImage *img = [[UIImage alloc] initWithData:data];
            weakSelf.senderAvatarImage = img;
            
            dispatch_group_leave(group);
        });
    }
    else if (!self.senderAvatarImage) {
        self.senderAvatarImage = [UIImage imageNamed:@"chat_placeholder"];
    }
    
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf observeMessages];
            [weakSelf observeTyping];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.inputToolbar.contentView.textView.hasText) {
        self.toolbarHeightConstraint.constant = self.inputToolbar.preferredDefaultHeight;
    }
    [self.view layoutIfNeeded];
    [self.collectionView.collectionViewLayout invalidateLayout];

    if (self.automaticallyScrollsToMostRecentMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scrollToBottomAnimated:NO];
            [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
        });
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    self.collectionView.collectionViewLayout.springinessEnabled = NO;
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
}

#pragma mark - View rotation

- (BOOL)shouldAutorotate
{
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        return UIInterfaceOrientationMaskAllButUpsideDown;
    }
    return UIInterfaceOrientationMaskAll;
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    [super willRotateToInterfaceOrientation:toInterfaceOrientation duration:duration];
    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation
{
    [super didRotateFromInterfaceOrientation:fromInterfaceOrientation];
    if (self.showTypingIndicator) {
        self.showTypingIndicator = NO;
        self.showTypingIndicator = YES;
        [self.collectionView reloadData];
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self jsq_resetLayoutAndCaches];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self jsq_resetLayoutAndCaches];
}

- (void)jsq_resetLayoutAndCaches
{
    JSQMessagesCollectionViewFlowLayoutInvalidationContext *context = [JSQMessagesCollectionViewFlowLayoutInvalidationContext context];
    context.invalidateFlowLayoutMessagesCache = YES;
    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:context];
}

#pragma mark - Messages view controller

- (void)didPressSendButton:(UIButton *)button
           withMessageText:(NSString *)text
                  senderId:(NSString *)senderId
         senderDisplayName:(NSString *)senderDisplayName
                      date:(NSDate *)date
{
    FIRDatabaseReference *itemRef = [self.messageRef childByAutoId];
    NSDictionary *messageDict = @{@"senderId" : senderId,
                                  @"senderName" : senderDisplayName,
                                  @"text" : text};
    
    [itemRef setValue:messageDict];
    [self finishSendingMessage];
    
    self.isTyping = false;
}

- (void)didPressAccessoryButton:(UIButton *)sender
{
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    
    if ([UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        picker.sourceType = UIImagePickerControllerSourceTypeCamera;
    }
    else {
        picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    }
    
    [self presentViewController:picker animated:YES completion:NULL];
}

- (void)finishSendingMessage
{
    [self finishSendingMessageAnimated:YES];
}

- (void)finishSendingMessageAnimated:(BOOL)animated {

    UITextView *textView = self.inputToolbar.contentView.textView;
    textView.text = nil;
    [textView.undoManager removeAllActions];

    [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification object:textView];

    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
    [self.collectionView reloadData];

    if (self.automaticallyScrollsToMostRecentMessage) {
        [self scrollToBottomAnimated:animated];
    }
}

- (void)finishReceivingMessage
{
    [self finishReceivingMessageAnimated:YES];
}

- (void)finishReceivingMessageAnimated:(BOOL)animated {

    self.showTypingIndicator = NO;

    [self.collectionView.collectionViewLayout invalidateLayoutWithContext:[JSQMessagesCollectionViewFlowLayoutInvalidationContext context]];
    [self.collectionView reloadData];

    if (self.automaticallyScrollsToMostRecentMessage && ![self jsq_isMenuVisible]) {
        [self scrollToBottomAnimated:animated];
    }

    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSBundle jsq_localizedStringForKey:@"new_message_received_accessibility_announcement"]);
}

- (void)scrollToBottomAnimated:(BOOL)animated
{
    if ([self.collectionView numberOfSections] == 0) {
        return;
    }

    NSIndexPath *lastCell = [NSIndexPath indexPathForItem:([self.collectionView numberOfItemsInSection:0] - 1) inSection:0];
    [self scrollToIndexPath:lastCell animated:animated];
}


- (void)scrollToIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated
{
    if ([self.collectionView numberOfSections] <= indexPath.section) {
        return;
    }

    NSInteger numberOfItems = [self.collectionView numberOfItemsInSection:indexPath.section];
    if (numberOfItems == 0) {
        return;
    }

    CGFloat collectionViewContentHeight = [self.collectionView.collectionViewLayout collectionViewContentSize].height;
    BOOL isContentTooSmall = (collectionViewContentHeight < CGRectGetHeight(self.collectionView.bounds));

    if (isContentTooSmall) {
        //  workaround for the first few messages not scrolling
        //  when the collection view content size is too small, `scrollToItemAtIndexPath:` doesn't work properly
        //  this seems to be a UIKit bug, see #256 on GitHub
        [self.collectionView scrollRectToVisible:CGRectMake(0.0, collectionViewContentHeight - 1.0f, 1.0f, 1.0f)
                                        animated:animated];
        return;
    }

    NSInteger item = MAX(MIN(indexPath.item, numberOfItems - 1), 0);
    indexPath = [NSIndexPath indexPathForItem:item inSection:0];

    //  workaround for really long messages not scrolling
    //  if last message is too long, use scroll position bottom for better appearance, else use top
    //  possibly a UIKit bug, see #480 on GitHub
    CGSize cellSize = [self.collectionView.collectionViewLayout sizeForItemAtIndexPath:indexPath];
    CGFloat maxHeightForVisibleMessage = CGRectGetHeight(self.collectionView.bounds)
    - self.collectionView.contentInset.top
    - self.collectionView.contentInset.bottom
    - CGRectGetHeight(self.inputToolbar.bounds);
    UICollectionViewScrollPosition scrollPosition = (cellSize.height > maxHeightForVisibleMessage) ? UICollectionViewScrollPositionBottom : UICollectionViewScrollPositionTop;

    [self.collectionView scrollToItemAtIndexPath:indexPath
                                atScrollPosition:scrollPosition
                                        animated:animated];
}

- (BOOL)isOutgoingMessage:(id<JSQMessageData>)messageItem
{
    NSString *messageSenderId = [messageItem senderId];
    NSParameterAssert(messageSenderId != nil);

    return [messageSenderId isEqualToString:[self.collectionView.dataSource senderId]];
}

#pragma mark - JSQMessages collection view data source

- (NSString *)senderDisplayName
{
    return _senderDisplayName;
}

- (NSString *)senderId
{
    return _senderId;
}

- (id<JSQMessageData>)collectionView:(JSQMessagesCollectionView *)collectionView messageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return self.messages[indexPath.row];
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView didDeleteMessageAtIndexPath:(NSIndexPath *)indexPath
{
    NSAssert(NO, @"ERROR: required method not implemented: %s", __PRETTY_FUNCTION__);
}

- (id<JSQMessageBubbleImageDataSource>)collectionView:(JSQMessagesCollectionView *)collectionView messageBubbleImageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    JSQMessage *message  = self.messages[indexPath.row];
    
    if ([[message senderId] isEqualToString:_senderId]) {
        return self.outgoingBubbleImageView;
    }
    else {
        return self.incomingBubbleImageView;
    }
}

- (id<JSQMessageAvatarImageDataSource>)collectionView:(JSQMessagesCollectionView *)collectionView avatarImageDataForItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSUInteger index = indexPath.item;
    NSString *previous = index == 0 ? @"" : ((JSQMessage *)(self.messages[index - 1])).senderId;
    NSString *current = ((JSQMessage *)self.messages[index]).senderId;
    
    JSQMessage *message = self.messages[indexPath.row];
    
    if ([message.senderId isEqualToString:_senderId]) {
        return [previous isEqualToString:current] ? nil : [self.avatarImageFactory avatarImageWithImage:self.ownAvatarImage];
    }
    else {
        return [previous isEqualToString:current] ? nil : [self.avatarImageFactory avatarImageWithImage:self.senderAvatarImage];
    }
}

- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForCellTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForMessageBubbleTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

- (NSAttributedString *)collectionView:(JSQMessagesCollectionView *)collectionView attributedTextForCellBottomLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

#pragma mark - Collection view data source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self.messages.count;
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return 1;
}

- (UICollectionViewCell *)collectionView:(JSQMessagesCollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    id<JSQMessageData> messageItem = [collectionView.dataSource collectionView:collectionView messageDataForItemAtIndexPath:indexPath];
    NSParameterAssert(messageItem != nil);

    BOOL isOutgoingMessage = [self isOutgoingMessage:messageItem];
    BOOL isMediaMessage = [messageItem isMediaMessage];

    NSString *cellIdentifier = nil;
    if (isMediaMessage) {
        cellIdentifier = isOutgoingMessage ? self.outgoingMediaCellIdentifier : self.incomingMediaCellIdentifier;
    }
    else {
        cellIdentifier = isOutgoingMessage ? self.outgoingCellIdentifier : self.incomingCellIdentifier;
    }

    JSQMessagesCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:cellIdentifier forIndexPath:indexPath];
    cell.accessibilityIdentifier = [NSString stringWithFormat:@"(%ld, %ld)", (long)indexPath.section, (long)indexPath.row];
    cell.delegate = collectionView;

    if (!isMediaMessage) {
        cell.textView.text = [messageItem text];
        NSParameterAssert(cell.textView.text != nil);

        id<JSQMessageBubbleImageDataSource> bubbleImageDataSource = [collectionView.dataSource collectionView:collectionView messageBubbleImageDataForItemAtIndexPath:indexPath];
        cell.messageBubbleImageView.image = [bubbleImageDataSource messageBubbleImage];
        cell.messageBubbleImageView.highlightedImage = [bubbleImageDataSource messageBubbleHighlightedImage];
    }
    else {
        id<JSQMessageMediaData> messageMedia = [messageItem media];
        cell.mediaView = [messageMedia mediaView] ?: [messageMedia mediaPlaceholderView];
        NSParameterAssert(cell.mediaView != nil);
    }

    BOOL needsAvatar = YES;
    if (isOutgoingMessage && CGSizeEqualToSize(collectionView.collectionViewLayout.outgoingAvatarViewSize, CGSizeZero)) {
        needsAvatar = NO;
    }
    else if (!isOutgoingMessage && CGSizeEqualToSize(collectionView.collectionViewLayout.incomingAvatarViewSize, CGSizeZero)) {
        needsAvatar = NO;
    }

    id<JSQMessageAvatarImageDataSource> avatarImageDataSource = nil;
    if (needsAvatar) {
        avatarImageDataSource = [collectionView.dataSource collectionView:collectionView avatarImageDataForItemAtIndexPath:indexPath];
        if (avatarImageDataSource != nil) {

            UIImage *avatarImage = [avatarImageDataSource avatarImage];
            if (avatarImage == nil) {
                cell.avatarImageView.image = [avatarImageDataSource avatarPlaceholderImage];
                cell.avatarImageView.highlightedImage = nil;
            }
            else {
                cell.avatarImageView.image = avatarImage;
                cell.avatarImageView.highlightedImage = [avatarImageDataSource avatarHighlightedImage];
            }
        }
    }

    cell.cellTopLabel.attributedText = [collectionView.dataSource collectionView:collectionView attributedTextForCellTopLabelAtIndexPath:indexPath];
    cell.messageBubbleTopLabel.attributedText = [collectionView.dataSource collectionView:collectionView attributedTextForMessageBubbleTopLabelAtIndexPath:indexPath];
    cell.cellBottomLabel.attributedText = [collectionView.dataSource collectionView:collectionView attributedTextForCellBottomLabelAtIndexPath:indexPath];

    CGFloat bubbleTopLabelInset = (avatarImageDataSource != nil) ? 60.0f : 15.0f;

    if (isOutgoingMessage) {
        cell.messageBubbleTopLabel.textInsets = UIEdgeInsetsMake(0.0f, 0.0f, 0.0f, bubbleTopLabelInset);
    }
    else {
        cell.messageBubbleTopLabel.textInsets = UIEdgeInsetsMake(0.0f, bubbleTopLabelInset, 0.0f, 0.0f);
    }

    cell.textView.dataDetectorTypes = UIDataDetectorTypeAll;

    cell.backgroundColor = [UIColor clearColor];
    cell.layer.rasterizationScale = [UIScreen mainScreen].scale;
    cell.layer.shouldRasterize = YES;
    [self collectionView:collectionView accessibilityForCell:cell indexPath:indexPath message:messageItem];

    JSQMessage *message = self.messages[indexPath.row];
    
    if ([message.senderId isEqualToString:_senderId]) {
        cell.textView.textColor = [UIColor whiteColor];
    }
    else {
        cell.textView.textColor = [UIColor blackColor];
    }
    return cell;
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView
  accessibilityForCell:(JSQMessagesCollectionViewCell*)cell
             indexPath:(NSIndexPath *)indexPath
               message:(id<JSQMessageData>)messageItem
{
    const BOOL isMediaMessage = [messageItem isMediaMessage];
    cell.isAccessibilityElement = YES;
    if (!isMediaMessage) {
        cell.accessibilityLabel = [NSString stringWithFormat:[NSBundle jsq_localizedStringForKey:@"text_message_accessibility_label"],
                                   [messageItem senderDisplayName],
                                   [messageItem text]];
    }
    else {
        cell.accessibilityLabel = [NSString stringWithFormat:[NSBundle jsq_localizedStringForKey:@"media_message_accessibility_label"],
                                   [messageItem senderDisplayName]];
    }
}

- (UICollectionReusableView *)collectionView:(JSQMessagesCollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath
{
    if (self.showTypingIndicator && [kind isEqualToString:UICollectionElementKindSectionFooter]) {
        return [collectionView dequeueTypingIndicatorFooterViewForIndexPath:indexPath];
    }
    else if (self.showLoadEarlierMessagesHeader && [kind isEqualToString:UICollectionElementKindSectionHeader]) {
        return [collectionView dequeueLoadEarlierMessagesViewHeaderForIndexPath:indexPath];
    }

    return nil;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout referenceSizeForFooterInSection:(NSInteger)section
{
    if (!self.showTypingIndicator) {
        return CGSizeZero;
    }

    return CGSizeMake([collectionViewLayout itemWidth], kJSQMessagesTypingIndicatorFooterViewHeight);
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout referenceSizeForHeaderInSection:(NSInteger)section
{
    if (!self.showLoadEarlierMessagesHeader) {
        return CGSizeZero;
    }

    return CGSizeMake([collectionViewLayout itemWidth], kJSQMessagesLoadEarlierHeaderViewHeight);
}

#pragma mark - Collection view delegate

- (BOOL)collectionView:(JSQMessagesCollectionView *)collectionView shouldShowMenuForItemAtIndexPath:(NSIndexPath *)indexPath
{
    //  disable menu for media messages
    id<JSQMessageData> messageItem = [collectionView.dataSource collectionView:collectionView messageDataForItemAtIndexPath:indexPath];
    if ([messageItem isMediaMessage]) {

        if ([[messageItem media] respondsToSelector:@selector(mediaDataType)]) {
            return YES;
        }
        return NO;
    }

    self.selectedIndexPathForMenu = indexPath;

    //  textviews are selectable to allow data detectors
    //  however, this allows the 'copy, define, select' UIMenuController to show
    //  which conflicts with the collection view's UIMenuController
    //  temporarily disable 'selectable' to prevent this issue
    JSQMessagesCollectionViewCell *selectedCell = (JSQMessagesCollectionViewCell *)[collectionView cellForItemAtIndexPath:indexPath];
    selectedCell.textView.selectable = NO;
    
    //  it will reset the font and fontcolor when selectable is NO
    //  however, the actual font and fontcolor in textView do not get changed
    //  in order to preserve link colors, we need to re-assign the font and fontcolor when selectable is NO
    //  see GitHub issues #1675 and #1759
    selectedCell.textView.textColor = selectedCell.textView.textColor;
    selectedCell.textView.font = selectedCell.textView.font;

    return YES;
}

- (BOOL)collectionView:(UICollectionView *)collectionView canPerformAction:(SEL)action forItemAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
    if (action == @selector(copy:) || action == @selector(delete:)) {
        return YES;
    }

    return NO;
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView performAction:(SEL)action forItemAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender
{
    if (action == @selector(copy:)) {

        id<JSQMessageData> messageData = [self collectionView:collectionView messageDataForItemAtIndexPath:indexPath];

        if ([messageData isMediaMessage]) {
            id<JSQMessageMediaData> mediaData = [messageData media];
            if ([messageData conformsToProtocol:@protocol(JSQMessageData)]) {
                [[UIPasteboard generalPasteboard] setValue:[mediaData mediaData]
                                         forPasteboardType:[mediaData mediaDataType]];
            }
        } else {
            [[UIPasteboard generalPasteboard] setString:[messageData text]];
        }
    }
    else if (action == @selector(delete:)) {
        [collectionView.dataSource collectionView:collectionView didDeleteMessageAtIndexPath:indexPath];

        [collectionView deleteItemsAtIndexPaths:@[indexPath]];
        [collectionView.collectionViewLayout invalidateLayout];
    }
}

#pragma mark - Collection view delegate flow layout

- (CGSize)collectionView:(JSQMessagesCollectionView *)collectionView
                  layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [collectionViewLayout sizeForItemAtIndexPath:indexPath];
}

- (CGFloat)collectionView:(JSQMessagesCollectionView *)collectionView
                   layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout heightForCellTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return 0.0f;
}

- (CGFloat)collectionView:(JSQMessagesCollectionView *)collectionView
                   layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout heightForMessageBubbleTopLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return 0.0f;
}

- (CGFloat)collectionView:(JSQMessagesCollectionView *)collectionView
                   layout:(JSQMessagesCollectionViewFlowLayout *)collectionViewLayout heightForCellBottomLabelAtIndexPath:(NSIndexPath *)indexPath
{
    return 0.0f;
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView
 didTapAvatarImageView:(UIImageView *)avatarImageView
           atIndexPath:(NSIndexPath *)indexPath { }

- (void)collectionView:(JSQMessagesCollectionView *)collectionView didTapMessageBubbleAtIndexPath:(NSIndexPath *)indexPath {
    JSQMessage *message = [self.messages objectAtIndex:indexPath.row];
    
    if (message.isMediaMessage) {
        id<JSQMessageMediaData> mediaItem = message.media;
        
        if ([mediaItem isKindOfClass:[JSQPhotoMediaItem class]]) {
            
            NSLog(@"Tapped photo message bubble!");
            
            JSQPhotoMediaItem *photoItem = (JSQPhotoMediaItem *)mediaItem;
            UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
            [self popupImage:photoItem.image cell:cell];
        }
    }
}

- (void)collectionView:(JSQMessagesCollectionView *)collectionView
 didTapCellAtIndexPath:(NSIndexPath *)indexPath
         touchLocation:(CGPoint)touchLocation { }

#pragma mark - full screen image

- (void)popupImage: (UIImage*)image cell:(UICollectionViewCell *)cell{
    // Create image info
    JTSImageInfo *imageInfo = [[JTSImageInfo alloc] init];
    imageInfo.image = image;
    imageInfo.referenceRect = cell.frame;
    imageInfo.referenceView = self.collectionView;
    
    // Setup view controller
    JTSImageViewController *imageViewer = [[JTSImageViewController alloc]
                                           initWithImageInfo:imageInfo
                                           mode:JTSImageViewControllerMode_Image
                                           backgroundStyle:JTSImageViewControllerBackgroundOption_None];
    
    // Present the view controller.
    [imageViewer showFromViewController:self transition:JTSImageViewControllerTransition_FromOriginalPosition];
}

#pragma mark - Input toolbar delegate

- (void)messagesInputToolbar:(JSQMessagesInputToolbar *)toolbar didPressLeftBarButton:(UIButton *)sender
{
    if (toolbar.sendButtonLocation == JSQMessagesInputSendButtonLocationLeft) {
        [self didPressSendButton:sender
                 withMessageText:[self jsq_currentlyComposedMessageText]
                        senderId:[self.collectionView.dataSource senderId]
               senderDisplayName:[self.collectionView.dataSource senderDisplayName]
                            date:[NSDate date]];
    }
    else {
        [self didPressAccessoryButton:sender];
    }
}

- (void)messagesInputToolbar:(JSQMessagesInputToolbar *)toolbar didPressRightBarButton:(UIButton *)sender
{
    if (toolbar.sendButtonLocation == JSQMessagesInputSendButtonLocationRight) {
        [self didPressSendButton:sender
                 withMessageText:[self jsq_currentlyComposedMessageText]
                        senderId:[self.collectionView.dataSource senderId]
               senderDisplayName:[self.collectionView.dataSource senderDisplayName]
                            date:[NSDate date]];
    }
    else {
        [self didPressAccessoryButton:sender];
    }
}

- (NSString *)jsq_currentlyComposedMessageText
{
    //  auto-accept any auto-correct suggestions
    [self.inputToolbar.contentView.textView.inputDelegate selectionWillChange:self.inputToolbar.contentView.textView];
    [self.inputToolbar.contentView.textView.inputDelegate selectionDidChange:self.inputToolbar.contentView.textView];

    return [self.inputToolbar.contentView.textView.text jsq_stringByTrimingWhitespace];
}

#pragma mark - Input

- (UIView *)inputAccessoryView
{
    return self.inputToolbar;
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

#pragma mark - Text view delegate

- (void)textViewDidBeginEditing:(UITextView *)textView
{
    if (textView != self.inputToolbar.contentView.textView) {
        return;
    }

    [textView becomeFirstResponder];

    if (self.automaticallyScrollsToMostRecentMessage) {
        [self scrollToBottomAnimated:YES];
    }
}

- (void)textViewDidChange:(UITextView *)textView
{
    if (textView != self.inputToolbar.contentView.textView) {
        return;
    }
    
    self.isTyping = textView.text.length > 0;
}

- (void)textViewDidEndEditing:(UITextView *)textView
{
    if (textView != self.inputToolbar.contentView.textView) {
        return;
    }

    [textView resignFirstResponder];
}

#pragma mark - Notifications

- (void)didReceiveMenuWillShowNotification:(NSNotification *)notification
{
    if (!self.selectedIndexPathForMenu) {
        return;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIMenuControllerWillShowMenuNotification
                                                  object:nil];

    UIMenuController *menu = [notification object];
    [menu setMenuVisible:NO animated:NO];

    JSQMessagesCollectionViewCell *selectedCell = (JSQMessagesCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:self.selectedIndexPathForMenu];
    CGRect selectedCellMessageBubbleFrame = [selectedCell convertRect:selectedCell.messageBubbleContainerView.frame toView:self.view];

    [menu setTargetRect:selectedCellMessageBubbleFrame inView:self.view];
    [menu setMenuVisible:YES animated:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(didReceiveMenuWillShowNotification:)
                                                 name:UIMenuControllerWillShowMenuNotification
                                               object:nil];
}

- (void)didReceiveMenuWillHideNotification:(NSNotification *)notification
{
    if (!self.selectedIndexPathForMenu) {
        return;
    }

    //  per comment above in 'shouldShowMenuForItemAtIndexPath:'
    //  re-enable 'selectable', thus re-enabling data detectors if present
    JSQMessagesCollectionViewCell *selectedCell = (JSQMessagesCollectionViewCell *)[self.collectionView cellForItemAtIndexPath:self.selectedIndexPathForMenu];
    selectedCell.textView.selectable = YES;
    self.selectedIndexPathForMenu = nil;
}

- (void)preferredContentSizeChanged:(NSNotification *)notification
{
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView setNeedsLayout];
}

#pragma mark - Collection view utilities

- (void)jsq_updateCollectionViewInsets
{
    const CGFloat top = self.additionalContentInset.top;
    const CGFloat bottom = CGRectGetMaxY(self.collectionView.frame) - CGRectGetMinY(self.inputToolbar.frame) + self.additionalContentInset.bottom;
    [self jsq_setCollectionViewInsetsTopValue:top bottomValue:bottom];
}

- (void)jsq_setCollectionViewInsetsTopValue:(CGFloat)top bottomValue:(CGFloat)bottom
{
    UIEdgeInsets insets = UIEdgeInsetsMake(self.topLayoutGuide.length + top, 0.0f, bottom, 0.0f);
    self.collectionView.contentInset = insets;
    self.collectionView.scrollIndicatorInsets = insets;
}

- (BOOL)jsq_isMenuVisible
{
    //  check if cell copy menu is showing
    //  it is only our menu if `selectedIndexPathForMenu` is not `nil`
    return self.selectedIndexPathForMenu != nil && [[UIMenuController sharedMenuController] isMenuVisible];
}

#pragma mark - Utilities

- (void)jsq_registerForNotifications:(BOOL)registerForNotifications
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    if (registerForNotifications) {
        [center addObserver:self
                   selector:@selector(jsq_didReceiveKeyboardWillChangeFrameNotification:)
                       name:UIKeyboardWillChangeFrameNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(didReceiveMenuWillShowNotification:)
                       name:UIMenuControllerWillShowMenuNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(didReceiveMenuWillHideNotification:)
                       name:UIMenuControllerWillHideMenuNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(preferredContentSizeChanged:)
                       name:UIContentSizeCategoryDidChangeNotification
                     object:nil];
    }
    else {
        [center removeObserver:self
                          name:UIKeyboardWillChangeFrameNotification
                        object:nil];

        [center removeObserver:self
                          name:UIMenuControllerWillShowMenuNotification
                        object:nil];

        [center removeObserver:self
                          name:UIMenuControllerWillHideMenuNotification
                        object:nil];

        [center removeObserver:self
                          name:UIContentSizeCategoryDidChangeNotification
                        object:nil];
    }
}

- (void)jsq_didReceiveKeyboardWillChangeFrameNotification:(NSNotification *)notification
{
    NSDictionary *userInfo = [notification userInfo];

    CGRect keyboardEndFrame = [userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];

    if (CGRectIsNull(keyboardEndFrame)) {
        return;
    }

    UIViewAnimationCurve animationCurve = [userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    NSInteger animationCurveOption = (animationCurve << 16);

    double animationDuration = [userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];

    [UIView animateWithDuration:animationDuration
                          delay:0.0
                        options:animationCurveOption
                     animations:^{
                         const UIEdgeInsets insets = self.additionalContentInset;
                         [self jsq_setCollectionViewInsetsTopValue:insets.top
                                                       bottomValue:CGRectGetHeight(keyboardEndFrame) + insets.bottom];
                     }
                     completion:nil];
}

#pragma mark - syncing the messages

- (void)observeMessages {
    self.channelRef = [[[[FIRDatabase database] reference] child:@"channels"] child:_channelId];
    self.messageRef = [self.channelRef child:@"messages"];
    
    __weak  typeof(self) weakSelf = self;
    FIRDatabaseQuery *messageQuery = [self.messageRef queryLimitedToLast:25];
    
    self.newMessageRefHandle = [messageQuery observeEventType:FIRDataEventTypeChildAdded withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        
        [weakSelf fireChatLoaded];
        
        NSDictionary *messageData = snapshot.value;
        
        NSString *senderId = messageData[@"senderId"];
        NSString *senderName = messageData[@"senderName"];
        NSString *text = messageData[@"text"];
        
        if (senderId && senderName && text && text.length > 0) {
            [weakSelf addMessage:senderId
                        name:senderName
                        text:text];
            [weakSelf finishReceivingMessage];
            
        }
        else if (senderId){
            NSString *photoURL = messageData[@"photoURL"];
            JSQPhotoMediaItem *mediaItem = [[JSQPhotoMediaItem alloc] initWithMaskAsOutgoing: [senderId isEqualToString:weakSelf.senderId]];
            
            [weakSelf addPhotoMessage:senderId key:snapshot.key mediaItem:mediaItem];
            
            if ([photoURL hasPrefix:@"gs://"]) {
                [weakSelf fetchImageDataAtURL:photoURL
                             forMediaItem:mediaItem clearsPhotoMessageMapOnSuccessForKey:nil
                                indexPath:[NSIndexPath indexPathForRow:weakSelf.messages.count-1 inSection:0]];
            }
            
            [weakSelf finishSendingMessage];
        }
        else {
            NSError *error = [NSError errorWithDomain:CHAT_ERROR_DOMAIN
                                                 code:-1
                                             userInfo:@{@"error" : @"senderId not idenitified"}];
            [weakSelf fireError:error];
        }
    }];
    
    self.updatedMessageRefHandle = [self.messageRef observeEventType:FIRDataEventTypeChildChanged withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        NSString *key = snapshot.key;
        NSDictionary *messageDict = snapshot.value;
        
        NSString *photoURL = messageDict[@"photoURL"];
        
        if (photoURL) {
            JSQPhotoMediaItem *mediaItem = [self.photoMessageMap objectForKey:key];
            if (mediaItem) {
                [weakSelf fetchImageDataAtURL:photoURL
                             forMediaItem:mediaItem clearsPhotoMessageMapOnSuccessForKey:key
                                indexPath:nil];
            }
        }
        else {
            NSError *error = [NSError errorWithDomain:CHAT_ERROR_DOMAIN
                                                 code:-1
                                             userInfo:@{@"error" : @"photoURL not identified"}];
            [weakSelf fireError:error];
        }
    }];
}

- (void)observeTyping {
    __weak  typeof(self) weakSelf = self;
    
    FIRDatabaseReference *typingIndicatorRef = [self.channelRef child:@"typingIndicator"];
    self.userIsTypingRef = [typingIndicatorRef child:_senderId];
    [self.userIsTypingRef onDisconnectRemoveValue];
    
    [self.userIsTypingQuery observeEventType:FIRDataEventTypeValue withBlock:^(FIRDataSnapshot * _Nonnull snapshot) {
        if (snapshot.childrenCount == 1 && weakSelf.isTyping) {
            return;
        }
        
        weakSelf.showTypingIndicator = snapshot.childrenCount > 0;
        [weakSelf scrollToBottomAnimated:YES];
    }];
}

- (BOOL)isTyping {
    return _localTyping;
}

- (void)setIsTyping:(BOOL)isTyping {
    _localTyping = isTyping;
    
    if (isTyping)
        [self.userIsTypingRef setValue:@(1)];
    else
        [self.userIsTypingRef setValue:@(0)];
}

- (void)fetchImageDataAtURL:(NSString *)photoURL forMediaItem:(JSQPhotoMediaItem *)mediaItem clearsPhotoMessageMapOnSuccessForKey:(NSString *)key indexPath:(NSIndexPath *)indexPath{
    
    __weak typeof(self) weakSelf = self;
    [[PINCache sharedCache]
     objectForKey:photoURL
            block:^(PINCache * _Nonnull cache, NSString * _Nonnull key, id  _Nullable object) {
                    if (object) {
                        UIImage *image = (UIImage *)object;
                        mediaItem.image = image;
                        
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (indexPath)
                                [weakSelf.collectionView reloadItemsAtIndexPaths:@[indexPath]];
                            else
                                [weakSelf.collectionView reloadData];
                        });
                        
                        [weakSelf.photoMessageMap removeObjectForKey:key];
                    }
                    else {
                        [weakSelf downloadPhoto:photoURL
                                   forMediaItem:mediaItem clearsPhotoMessageMapOnSuccessForKey:key];
                    }
    }];
}

- (void)downloadPhoto:(NSString *)photoURL forMediaItem:(JSQPhotoMediaItem *)mediaItem clearsPhotoMessageMapOnSuccessForKey:(NSString *)key  {
    FIRStorageReference *storageRef = [[FIRStorage storage] referenceForURL:photoURL];
    
    __weak typeof(self) weakSelf = self;
    [storageRef dataWithMaxSize:INT64_MAX completion:^(NSData * _Nullable data, NSError * _Nullable error) {
        if (error) {
            [weakSelf fireError:error];
            return;
        }
        
        [storageRef metadataWithCompletion:^(FIRStorageMetadata * _Nullable metadata, NSError * _Nullable error) {
            if (error) {
                [weakSelf fireError:error];
                return;
            }
            if ([metadata.contentType isEqualToString:@"image/gif"]) {
                mediaItem.image = [UIImage animatedImageWithAnimatedGIFData:data];
            }
            else {
                mediaItem.image = [[UIImage alloc] initWithData:data];
            }
            [[PINCache sharedCache] setObject:mediaItem.image forKey:photoURL];
            [weakSelf.collectionView reloadData];
            
            if (key == nil) {
                return;
            }
            
            [weakSelf.photoMessageMap removeObjectForKey:key];
        }];
    }];

}

#pragma mark - UIPickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<NSString *,id> *)info {
    
    [picker dismissViewControllerAnimated:YES completion:NULL];
    
    NSURL *photoReferenceUrl = info[UIImagePickerControllerReferenceURL];
    if (photoReferenceUrl) {
        PHFetchResult *assets = [PHAsset fetchAssetsWithALAssetURLs:@[photoReferenceUrl] options:nil];
        
        PHAsset *asset =  assets.firstObject;
        
        NSString *key = [self sendPhotoMessage];
        
        if (key) {
            [asset requestContentEditingInputWithOptions:nil completionHandler:^(PHContentEditingInput * _Nullable contentEditingInput, NSDictionary * _Nonnull info) {
                NSURL *imageFileURL = contentEditingInput.fullSizeImageURL;
                
                NSString *path = [NSString stringWithFormat:@"%@/%ld/%@", [FIRAuth auth].currentUser.uid,(long)([NSDate timeIntervalSinceReferenceDate] * 1000), photoReferenceUrl.lastPathComponent];
                
                __weak typeof(self) weakSelf = self;
                [[self.storageRef child:path] putFile:imageFileURL metadata:nil completion:^(FIRStorageMetadata * _Nullable metadata, NSError * _Nullable error) {
                    if (error) {
                        [weakSelf fireError:error];
                        return;
                    }
                    [weakSelf setImageURL:[weakSelf.storageRef child:metadata.path].description forMessageWithKey:key];
                    
                }];
            }];
        }
    }
    else {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        
        NSString *key = [self sendPhotoMessage];
        
        if (key) {
            NSData *imageData = UIImageJPEGRepresentation(image, 1.0);
            
            NSString *imagePath = [NSString stringWithFormat:@"%@/%ld.jpg", [FIRAuth auth].currentUser.uid, (long)[NSDate timeIntervalSinceReferenceDate] * 100];
            
            FIRStorageMetadata *metadata = [FIRStorageMetadata new];
            metadata.contentType = @"image/jpeg";
            
            __weak typeof(self) weakSelf = self;
            [[self.storageRef child:imagePath] putData:imageData metadata:metadata completion:^(FIRStorageMetadata * _Nullable metadata, NSError * _Nullable error) {
                if (error) {
                    [weakSelf fireError:error];
                    return;
                }
                
                [weakSelf setImageURL:[weakSelf.storageRef child:metadata.path].description forMessageWithKey:key];
            }];
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:NULL];
}

#pragma mark - error

- (void)fireError:(NSError *)error {
    if (self.onError) {
        self.onError(error);
    }
}

#pragma mark - onChatLoaded

- (void)fireChatLoaded {
    if (!self.alreadyLoaded) {
        if (self.onChatDidLoad) {
            self.onChatDidLoad();
        }
        
        self.alreadyLoaded = true;
    }
}

#pragma mark - dealloc

- (void)dealloc
{
    if (self.newMessageRefHandle) {
        [self.messageRef removeObserverWithHandle:self.newMessageRefHandle];
    }
    
    if (self.updatedMessageRefHandle) {
        [self.messageRef removeObserverWithHandle:self.updatedMessageRefHandle];
    }
    
    [self jsq_registerForNotifications:NO];
    
    _collectionView.dataSource = nil;
    _collectionView.delegate = nil;
    
    _inputToolbar.contentView.textView.delegate = nil;
    _inputToolbar.delegate = nil;
}

@end
