//
// Copyright (c) 2018 deltaDNA Ltd. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "DDNATrackingSdk.h"
#import "DDNASDK.h"
#import "DDNAUserManager.h"
#import "DDNASettings.h"
#import "DDNAEvent.h"
#import "DDNAEngagement.h"
#import "DDNALog.h"
#import "DDNAPlayerPrefs.h"
#import "DDNAClientInfo.h"
#import "DDNAUtils.h"
#import "NSString+DeltaDNA.h"
#import "NSDictionary+DeltaDNA.h"
#import <CommonCrypto/CommonDigest.h>

#import "DDNAPersistentEventStore.h"
#import "DDNAVolatileEventStore.h"
#import "DDNAEngageService.h"
#import "DDNAInstanceFactory.h"
#import "DDNACollectService.h"
#import "DDNAEngageFactory.h"

#import <UIKit/UIKit.h>

@interface DDNATrackingSdk ()

@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) dispatch_queue_t taskQueue;

@property (nonatomic, weak) DDNASDK *sdk;
@property (nonatomic, weak) DDNAInstanceFactory *instanceFactory;
@property (nonatomic, strong) id<DDNAEventStoreProtocol> eventStore;
@property (nonatomic, strong) DDNAEngageService *engageService;
@property (nonatomic, strong) DDNACollectService *collectService;
@property (nonatomic, assign) BOOL reset;
@property (nonatomic, strong) NSDate *lastActiveDate;
@property (nonatomic, strong) DDNAEngageFactory *engageFactory;

@property (nonatomic, assign, readwrite) BOOL started;
@property (nonatomic, assign, readwrite) BOOL uploading;

@end

static NSString *const EV_KEY_NAME = @"eventName";
static NSString *const EV_KEY_USER_ID = @"userID";
static NSString *const EV_KEY_SESSION_ID = @"sessionID";
static NSString *const EV_KEY_TIMESTAMP = @"eventTimestamp";
static NSString *const EV_KEY_PARAMS = @"eventParams";

static NSString *const EP_KEY_PLATFORM = @"platform";
static NSString *const EP_KEY_SDK_VERSION = @"sdkVersion";

static NSString *const PP_KEY_FIRST_RUN = @"DDSDK_FIRST_RUN";
static NSString *const PP_KEY_USER_ID = @"DDSDK_USER_ID";
static NSString *const PP_KEY_HASH_SECRET = @"DDSDK_HASH_SECRET";
static NSString *const PP_KEY_CLIENT_VERSION = @"DDSDK_CLIENT_VERSION";
static NSString *const PP_KEY_PUSH_NOTIFICATION_TOKEN = @"DDSDK_PUSH_NOTIFICATION_TOKEN";

static NSString *const DD_EVENT_STARTED = @"DDNASDKStarted";
static NSString *const DD_EVENT_NEW_SESSION = @"DDNASDKNewSession";

@implementation DDNATrackingSdk

- (instancetype)initWithSdk:(DDNASDK *)sdk instanceFactory:(DDNAInstanceFactory *)instanceFactory
{
    if ((self = [super init])) {
        self.sdk = sdk;
        self.instanceFactory = instanceFactory;
        
        self.reset = NO;
        self.uploading = NO;
        
        self.taskQueue = dispatch_queue_create("com.deltadna.TaskQueue", NULL);
        dispatch_suspend(self.taskQueue);
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidReceiveNotification:) name:DD_EVENT_STARTED object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        
        if (self.sdk.settings.useEventStore) {
            DDNALogDebug(@"Using persistent event store for session.");
            NSString *path = [DDNA_EVENT_STORAGE_PATH stringByReplacingOccurrencesOfString:@"{persistent_path}" withString:[DDNASettings getPrivateSettingsDirectoryPath]];
            self.eventStore = [[DDNAPersistentEventStore alloc] initWithPath:path sizeBytes:DDNA_MAX_EVENT_STORE_BYTES clean:self.reset];
        } else {
            DDNALogDebug(@"Using volatile event store for session.");
            self.eventStore = [[DDNAVolatileEventStore alloc] initWithSizeBytes:DDNA_MAX_EVENT_STORE_BYTES];
        }
        
    }
    return self;
}

- (void)dealloc
{
    dispatch_resume(self.taskQueue);    // doesn't like deallocing suspended queues!
}

- (void)startWithNewPlayer:(DDNAUserManager *)userManager
{
    self.engageService = [self.instanceFactory buildEngageService];
    self.collectService = [self.instanceFactory buildCollectService];
    
    DDNALogDebug(@"Starting SDK with user id %@", self.sdk.userID);
    
    [[NSNotificationCenter defaultCenter] postNotificationName:DD_EVENT_STARTED object:self];
    _started = YES;
    [self.sdk newSession];
    
    // Once we're started, send default events.
    [self triggerDefaultEvents:userManager.isNewPlayer];
    userManager.newPlayer = NO;
    
    // Setup automated event uploads in the background.
    if (self.sdk.settings.backgroundEventUpload) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
        if (_timer) {
            uint64_t interval = self.sdk.settings.backgroundEventUploadRepeatRateSeconds * NSEC_PER_SEC;
            uint64_t leeway = 1ull * NSEC_PER_SEC;
            dispatch_source_set_timer(_timer, dispatch_walltime(NULL, 0), interval, leeway);
            dispatch_source_set_event_handler(_timer, ^{
                [self upload];
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.sdk.settings.backgroundEventUploadStartDelaySeconds * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                dispatch_resume(_timer);
            });
        }
    }
}

- (void) newSession
{
    DDNALogDebug(@"Starting new session %@", self.sdk.sessionID);
    [[NSNotificationCenter defaultCenter] postNotificationName:DD_EVENT_NEW_SESSION object:self];
}

- (void) stop
{
    DDNALogDebug(@"Stopping SDK");
    
    if (self.timer)
    {
        dispatch_source_cancel(self.timer);
    }
    
    [self.sdk recordEventWithName:@"gameEnded"];
    [self upload];
    
    if (self.started) {
        dispatch_suspend(self.taskQueue);
    }
    self.started = NO;
}

- (void)recordEvent:(DDNAEvent *)event
{
    if (!self.started) {
        @throw([NSException exceptionWithName:@"DDNANotStartedException" reason:@"The deltaDNA SDK must be started before it can record events." userInfo:nil]);
    }
    
    [event setParam:self.sdk.platform forKey:@"platform"];
    [event setParam:DDNA_SDK_VERSION forKey:@"sdkVersion"];
    
    NSMutableDictionary *eventSchema = [NSMutableDictionary dictionaryWithDictionary:[event dictionary]];
    [eventSchema setObject:self.sdk.userID forKey:@"userID"];
    [eventSchema setObject:self.sdk.sessionID forKey:@"sessionID"];
    [eventSchema setObject:[[NSUUID UUID] UUIDString] forKey:@"eventUUID"];
    [eventSchema setObject:[DDNAUtils getCurrentTimestamp] forKey:@"eventTimestamp"];
    
    [self.eventStore pushEvent:eventSchema];
}

- (void)requestEngagement:(DDNAEngagement *)engagement completionHandler:(void (^)(NSDictionary *, NSInteger, NSError *))completionHandler
{
    if (!self.started) {
        @throw([NSException exceptionWithName:@"DDNANotStartedException" reason:@"You must first start the deltaDNA SDK" userInfo:nil]);
    }
    
    if ([NSString stringIsNilOrEmpty:self.sdk.engageURL]) {
        @throw([NSException exceptionWithName:NSInvalidArgumentException reason:@"Engage URL not set" userInfo:nil]);
    }
    
    @try {
        
        NSDictionary *dict = [engagement dictionary];
        
        DDNAEngageRequest *engageRequest = [[DDNAEngageRequest alloc] initWithDecisionPoint:dict[@"decisionPoint"]
                                                                                     userId:self.sdk.userID
                                                                                  sessionId:self.sdk.sessionID];
        engageRequest.flavour = dict[@"flavour"];
        engageRequest.parameters = dict[@"parameters"];
        
        [self.engageService request:engageRequest handler:^(NSString *response, NSInteger statusCode, NSError *error) {
            if (error || statusCode != 200) {
                DDNALogWarn(@"Engagement for '%@' failed with %ld: %@",
                            engagement.decisionPoint, (long)statusCode, error ? error.localizedDescription : response);
            }
            if (completionHandler) {
                completionHandler([NSDictionary dictionaryWithJSONString:response], statusCode, error);
            }
        }];
    }
    @catch (NSException *exception) {
        DDNALogWarn(@"Engagement for '%@' failed: %@", engagement.decisionPoint, exception.reason);
    }
}

- (void)requestEngagement:(DDNAEngagement *)engagement engagementHandler:(void (^)(DDNAEngagement *))engagementHandler
{
    if (!self.started) {
        @throw([NSException exceptionWithName:@"DDNANotStartedException" reason:@"You must first start the deltaDNA SDK" userInfo:nil]);
    }
    
    if ([NSString stringIsNilOrEmpty:self.sdk.engageURL]) {
        @throw([NSException exceptionWithName:NSInvalidArgumentException reason:@"Engage URL not set" userInfo:nil]);
    }
    
    if (engagement == nil) {
        @throw([NSException exceptionWithName:NSInvalidArgumentException reason:@"engagement cannot be nil" userInfo:nil]);
    }
    
    if (engagementHandler == nil) {
        @throw([NSException exceptionWithName:NSInvalidArgumentException reason:@"engagementHandler cannot be nil" userInfo:nil]);
    }
    
    @try {
        
        NSDictionary *dict = [engagement dictionary];
        
        DDNAEngageRequest *engageRequest = [[DDNAEngageRequest alloc] initWithDecisionPoint:dict[@"decisionPoint"]
                                                                                     userId:self.sdk.userID
                                                                                  sessionId:self.sdk.sessionID];
        engageRequest.flavour = dict[@"flavour"];
        engageRequest.parameters = dict[@"parameters"];
        
        [self.engageService request:engageRequest handler:^(NSString *response, NSInteger statusCode, NSError *error) {
            if (error || statusCode != 200) {
                DDNALogWarn(@"Engagement for '%@' failed with %ld: %@",
                            engagement.decisionPoint, (long)statusCode, error ? error.localizedDescription : response);
            }
            engagement.raw = response;
            engagement.statusCode = statusCode;
            engagement.error = error;
            
            engagementHandler(engagement);
        }];
    }
    @catch (NSException *exception) {
        DDNALogWarn(@"Engagement for '%@' failed: %@", engagement.decisionPoint, exception.reason);
    }
}

- (void) recordPushNotification:(NSDictionary *)pushNotification didLaunch:(BOOL)didLaunch
{
    DDNALogDebug(@"Received push notification: %@", pushNotification);
    
    if (_started) {
        
        NSString *notificationId = pushNotification[@"_ddId"];
        NSString *notificationName = pushNotification[@"_ddName"];
        
        NSMutableDictionary *eventParams = [NSMutableDictionary dictionary];
        if (notificationId) {
            [eventParams setObject:[NSNumber numberWithInteger:[notificationId integerValue]] forKey:@"notificationId"];
        }
        if (notificationName) {
            [eventParams setObject:notificationName forKey:@"notificationName"];
        }
        
        NSString *campaignId = pushNotification[@"_ddCampaign"];
        NSString *cohortId = pushNotification[@"_ddCohort"];
        if (campaignId) {
            [eventParams setObject:[NSNumber numberWithLong:[campaignId longLongValue]] forKey:@"campaignId"];
        }
        if (cohortId) {
            [eventParams setObject:[NSNumber numberWithLong:[cohortId longLongValue]] forKey:@"cohortId"];
        }
        if (campaignId || cohortId) {
            [eventParams setObject:@"APPLE_NOTIFICATION" forKey:@"communicationSender"];
            [eventParams setObject:@"OPEN" forKey:@"communicationState"];
        }
        
        [eventParams setObject:[NSNumber numberWithBool:didLaunch] forKey:@"notificationLaunch"];
        
        [self.sdk recordEventWithName:@"notificationOpened" eventParams:eventParams];
    }
    else {
        // wait until the SDK has been started
        __typeof(self) __weak weakSelf = self;
        dispatch_async(_taskQueue, ^{
            [weakSelf recordPushNotification:pushNotification didLaunch:didLaunch];
        });
    }
}

- (void) upload
{
    @synchronized(self) {
        if (!self.started) {
            NSException *exception = [NSException exceptionWithName:@"DDNANotStartedException" reason:@"You must first start the deltaDNA SDK" userInfo:nil];
            @throw exception;
        }
        
        if (self.uploading) {
            DDNALogWarn(@"Event upload already in progress, try again later.");
            return;
        }
        
        @try {
            self.uploading = YES;
            [self.eventStore swapBuffers];
            
            NSArray *events = [self.eventStore readOut];
            if (events.count > 0) {
                DDNACollectRequest *request = [[DDNACollectRequest alloc] initWithEventList:events timeoutSeconds:self.sdk.settings.httpRequestCollectTimeoutSeconds retries:self.sdk.settings.httpRequestMaxTries retryDelaySeconds:self.sdk.settings.httpRequestRetryDelaySeconds];
                if (!request) {
                    DDNALogWarn(@"Event corruption detected, clearing out queue");
                    [self.eventStore clearOut];
                    self.uploading = NO;
                } else {
                    DDNALogDebug(@"Sending latest events to Collect: %@", request);
                    [self.collectService request:request handler:^(NSString *response, NSInteger statusCode, NSString *error) {
                        if (statusCode >= 200 && statusCode < 400) {
                            DDNALogDebug(@"Event upload completed successfully.");
                            [self.eventStore clearOut];
                        } else if (statusCode == 400) {
                            DDNALogWarn(@"Collect rejected invalid events.");
                            [self.eventStore clearOut];
                        } else {
                            DDNALogWarn(@"Event upload failed, try again later.");
                        }
                        self.uploading = NO;
                    }];
                }
            } else {
                self.uploading = NO;
            }
        }
        @catch (NSException *exception) {
            self.uploading = NO;
            DDNALogWarn(@"Event upload failed: %@", exception.reason);
        }
    }
}

- (void) setPushNotificationToken:(NSString *)pushNotificationToken
{
    if (_started) {
        NSString *token = [pushNotificationToken stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]];
        token = [token stringByReplacingOccurrencesOfString:@" " withString:@""];
        [self.sdk recordEventWithName:@"notificationServices" eventParams:@{
                @"pushNotificationToken": token
            }];
        self.sdk.pushNotificationToken = token;
    } else {
        __typeof(self) __weak weakSelf = self;
        dispatch_async(_taskQueue, ^{
            [weakSelf setPushNotificationToken:pushNotificationToken];
        });
    }
}

- (void)clearPersistentData
{
    [self.eventStore clearAll];
}


#pragma mark - Private Helpers

- (void) triggerDefaultEvents:(BOOL)newPlayer
{
    if (self.sdk.settings.onFirstRunSendNewPlayerEvent && newPlayer)
    {
        DDNALogDebug(@"Sending 'newPlayer' event");
        
        NSMutableDictionary *eventParams = [NSMutableDictionary dictionary];
        if ([DDNAClientInfo sharedInstance].countryCode!=nil) {
            [eventParams setObject:[DDNAClientInfo sharedInstance].countryCode forKey:@"userCountry"];
        }
        
        [self.sdk recordEventWithName:@"newPlayer" eventParams:eventParams];
    }
    
    if (self.sdk.settings.onStartSendGameStartedEvent)
    {
        DDNALogDebug(@"Sending 'gameStarted' event");
        
        NSMutableDictionary *eventParams = [NSMutableDictionary dictionary];
        if (self.sdk.clientVersion != nil)
        {
            [eventParams setObject:self.sdk.clientVersion forKey:@"clientVersion"];
        }
        
        if (self.sdk.pushNotificationToken != nil)
        {
            [eventParams setObject:self.sdk.pushNotificationToken forKey:@"pushNotificationToken"];
        }
        
        if ([DDNAClientInfo sharedInstance].locale != nil) {
            [eventParams setObject:[DDNAClientInfo sharedInstance].locale forKey:@"userLocale"];
        }
        
        [self.sdk recordEventWithName:@"gameStarted" eventParams:eventParams];
    }
    
    if (self.sdk.settings.onStartSendClientDeviceEvent)
    {
        DDNALogDebug(@"Sending 'clientDevice' event");
        
        NSMutableDictionary *eventParams = [NSMutableDictionary dictionary];
        [eventParams setObject:[DDNAClientInfo sharedInstance].deviceName forKey:@"deviceName"];
        [eventParams setObject:[DDNAClientInfo sharedInstance].deviceType forKey:@"deviceType"];
        if ([DDNAClientInfo sharedInstance].hardwareVersion!=nil) {
            [eventParams setObject:[DDNAClientInfo sharedInstance].hardwareVersion forKey:@"hardwareVersion"];
        }
        [eventParams setObject:[DDNAClientInfo sharedInstance].operatingSystem forKey:@"operatingSystem"];
        [eventParams setObject:[DDNAClientInfo sharedInstance].operatingSystemVersion forKey:@"operatingSystemVersion"];
        [eventParams setObject:[DDNAClientInfo sharedInstance].manufacturer forKey:@"manufacturer"];
        [eventParams setObject:[DDNAClientInfo sharedInstance].timezoneOffset forKey:@"timezoneOffset"];
        if ([DDNAClientInfo sharedInstance].languageCode!=nil) {
            [eventParams setObject:[DDNAClientInfo sharedInstance].languageCode forKey:@"userLanguage"];
        }
        
        [self.sdk recordEventWithName:@"clientDevice" eventParams:eventParams];
    }
}

- (void)appDidReceiveNotification:(NSNotification *)notification
{
    if ([[notification name] isEqualToString:DD_EVENT_STARTED])
    {
        DDNALogDebug(@"Received SDK started notification");
        if (!_started) {
            dispatch_resume(_taskQueue);
        }
    }
}

- (void)appWillResignActive:(NSNotification *)notification
{
    self.lastActiveDate = [NSDate date];
}

- (void)appWillEnterForeground:(NSNotification *)notification
{
    if (self.sdk.settings.sessionTimeoutSeconds > 0) {
        NSTimeInterval backgroundSeconds = [[NSDate date] timeIntervalSinceDate:self.lastActiveDate];
        if (backgroundSeconds > self.sdk.settings.sessionTimeoutSeconds) {
            self.lastActiveDate = nil;
            [self.sdk newSession];
        }
    }
}

@end
