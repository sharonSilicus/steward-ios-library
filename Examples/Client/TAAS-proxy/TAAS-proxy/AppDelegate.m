//
//  AppDelegate.m
//  TAAS-proxy
//
//  TOTP example originally created by Alasdair Allan on 29/01/2014.
//  Copyright (c) 2014 The Thing System. All rights reserved.
//

#import "AppDelegate.h"
#import "RootController.h"
#import "HTTPServer.h"
#import "TAASConnection.h"
#import "DDLog.h"
#import "DDTTYLogger.h"


// Log levels: off, error, warn, info, verbose
// Other flags: trace
static const int ddLogLevel = LOG_LEVEL_VERBOSE;


@interface AppDelegate ()

@property (        nonatomic) UIBackgroundTaskIdentifier backgroundTaskID;
@property (        nonatomic) UIBackgroundTaskIdentifier notifyTaskID;
@property (strong, nonatomic) HTTPServer                *httpServer;
@property (strong, nonatomic) AVAudioSession            *audioSession;

@end


@implementation AppDelegate

#define kDocumentRoot    @"Web"


-           (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [DDLog addLogger:[DDTTYLogger sharedInstance]];

    DDLogVerbose(@"didFinishLaunchingWithOptions: %@", launchOptions);

    // should NEVER happen, as we are always running (voip)
    if ([launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey] != nil) return YES;

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.rootController = [[RootController alloc] initWithNibName:@"RootController" bundle:nil];
    self.window.backgroundColor = [UIColor whiteColor];
    self.window.rootViewController = self.rootController;

    self.httpServer = [[HTTPServer alloc] init];
    [self.httpServer setConnectionClass:[TAASConnection class]];
    [self.httpServer setPort:8884];

    NSString *documentRoot;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if ([paths count] > 0) documentRoot = [[paths objectAtIndex:0] stringByAppendingPathComponent:kDocumentRoot];
    DDLogVerbose(@"Document Root %@", documentRoot);
    if (documentRoot != nil) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:documentRoot]) {
            NSError *error = nil;
            if (![[NSFileManager defaultManager]
                       copyItemAtPath:[[[NSBundle mainBundle] bundlePath]
                                             stringByAppendingPathComponent:kDocumentRoot]
                               toPath:documentRoot
                                error:&error]) {
              DDLogVerbose(@"created %@", documentRoot);
            } else {
              DDLogError(@"%s: %@", __FUNCTION__, error);
            }
        }

        [self.httpServer setDocumentRoot:documentRoot];
    }

    NSError *error = nil;
    if (![self.httpServer start:&error]) {
        DDLogError(@"%s: error starting HTTP Server: %@", __FUNCTION__, error);
        self.httpServer = nil;
    }

    self.audioSession = [AVAudioSession sharedInstance];
    error = nil;
    [self.audioSession setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (error != nil) {
      DDLogError(@"%s: error setting audio session category to playback: %@", __FUNCTION__, error);
    } else {
      [self.audioSession setActive:YES error:&error];
      if (error) {
        DDLogError(@"%s: error setting audio session active: %@", __FUNCTION__, error);
      }
    }

    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];

    BOOL backgroundSupported = NO;
    UIDevice *device = [UIDevice currentDevice];
    if ([device respondsToSelector:@selector(isMultitaskingSupported)]) {
      backgroundSupported = device.multitaskingSupported;
    }
    if (!backgroundSupported) DDLogError(@"%s: background processing not supported", __FUNCTION__);
    self.backgroundTaskID = UIBackgroundTaskInvalid;
    self.notifyTaskID = UIBackgroundTaskInvalid;

    if (application.applicationState == UIApplicationStateBackground) {
        self.backgroundTaskID = [application beginBackgroundTaskWithExpirationHandler:^{
            DDLogVerbose(@"expiration of background task");
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskID];
            self.backgroundTaskID = UIBackgroundTaskInvalid;
        }];

      return YES;
    }

    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    DDLogVerbose(@"applicationWillEnterBackground");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    DDLogVerbose(@"applicationWillEnterForeground");

    application.applicationIconBadgeNumber = 0;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    DDLogVerbose(@"applicationDidBecomeActive");
}

- (void)applicationWillResignActive:(UIApplication *)application {
    DDLogVerbose(@"applicationDidResignActive");

    application.applicationIconBadgeNumber = 0;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    DDLogVerbose(@"applicationWillTerminate");

    if (self.httpServer != nil) [self.httpServer stop:NO];
}

-         (void)application:(UIApplication *)application
didReceiveLocalNotification:(UILocalNotification *)notification {
    DDLogVerbose(@"didReceiveLocalNotication");

    application.applicationIconBadgeNumber = 0;
}


#pragma mark - keep-alive

- (void)keepAlive:(UIApplication *)application
            onoff:(BOOL)onoff {
    if (self.backgroundTaskID != UIBackgroundTaskInvalid) {
        if (onoff) return;

        [application endBackgroundTask:self.backgroundTaskID];
        self.backgroundTaskID = UIBackgroundTaskInvalid;
    }
    if (!onoff) return;

    self.backgroundTaskID = [application beginBackgroundTaskWithExpirationHandler:^{
        [self keepAlive:application onoff:YES];
    }];
    if (self.backgroundTaskID == UIBackgroundTaskInvalid) {
        DDLogError(@"%s: unable to create background task", __FUNCTION__);
        return;
    }

    DDLogVerbose(@"remaining background time: %f", application.backgroundTimeRemaining);
}


#pragma mark - notifications

- (void)backgroundNotify:(NSString *)message
                andTitle:(NSString *)title {
    if (self.notifyTaskID != UIBackgroundTaskInvalid) return;

    UIApplication *application = [UIApplication sharedApplication];

    self.notifyTaskID = [application beginBackgroundTaskWithExpirationHandler: ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [application endBackgroundTask:self.notifyTaskID];
            self.notifyTaskID = UIBackgroundTaskInvalid;
        });
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        while ([application backgroundTimeRemaining] > 1.0) {
            UILocalNotification *localNotification = [[UILocalNotification alloc] init];
            if (localNotification == nil) break;

            localNotification.alertBody = message;
            localNotification.alertAction = title;
            localNotification.soundName = UILocalNotificationDefaultSoundName;
            localNotification.applicationIconBadgeNumber = 1;
            [application presentLocalNotificationNow:localNotification];
            break;
        }

        [application endBackgroundTask:self.notifyTaskID];
        self.notifyTaskID = UIBackgroundTaskInvalid;
    });
}

@end
