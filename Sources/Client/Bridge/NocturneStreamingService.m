#import "NocturneStreamingService.h"
#import "NocturnePairingTrust.h"
#import "NocturneStreamLifecycle.h"
#import "DiscoveryManager.h"
#import "DataManager.h"
#import "PairManager.h"
#import "CryptoManager.h"
#import "IdManager.h"
#import "ConnectionHelper.h"
#import "ServerInfoResponse.h"
#import "StreamFrameViewController.h"
#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#define SDL_MAIN_HANDLED
#import <SDL.h>
#include <Limelight.h>

@interface StreamFrameViewController (DarkLifecycle)
- (void)returnToMainFrame;
- (void)nocturneStopWithCompletion:(void (^)(void))completion;
@end

@interface MDStreamController : StreamFrameViewController
@property (nonatomic, copy) void (^onExit)(void);
@property (nonatomic) BOOL cleanedUp;
@property (nonatomic) CGSize lastControlSize;
- (void)shutdown;
@end
@implementation MDStreamController
- (void)returnToMainFrame { if (!self.cleanedUp && self.onExit) self.onExit(); }
- (void)launchFailed:(NSString *)message { if (!self.cleanedUp) [super launchFailed:message]; }
- (void)connectionTerminated:(int)errorCode { if (!self.cleanedUp) [super connectionTerminated:errorCode]; }
- (void)shutdown {
    if (self.cleanedUp) return;
    self.cleanedUp = YES;
    [self updatePreferredDisplayMode:NO];
    [super willMoveToParentViewController:nil];
}
- (void)willMoveToParentViewController:(UIViewController *)parent {
    if (parent == nil) [self shutdown]; else [super willMoveToParentViewController:parent];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Follow the actual scene bounds, including iPad Split View and Duo display transitions.
    for (UIView *view in self.view.subviews) {
        if ([view isKindOfClass:StreamView.class] || [view isKindOfClass:UIScrollView.class]) {
            view.frame = self.view.bounds;
            [self resizeVideoLayerInView:view];
            for (UIView *child in view.subviews) {
                if ([child isKindOfClass:StreamView.class]) { child.frame = view.bounds; [self resizeVideoLayerInView:child]; }
            }
        }
    }
}
- (void)resizeVideoLayerInView:(UIView *)view {
    if ([view isKindOfClass:StreamView.class] && !CGSizeEqualToSize(self.lastControlSize, view.bounds.size)) {
        if (!CGSizeEqualToSize(self.lastControlSize, CGSizeZero)) [(StreamView *)view showOnScreenControls];
        self.lastControlSize = view.bounds.size;
    }
    CGFloat ratio = (CGFloat)self.streamConfig.width / MAX(1, self.streamConfig.height);
    CGFloat width = MIN(view.bounds.size.width, view.bounds.size.height * ratio);
    CGSize size = CGSizeMake(width, width / ratio);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:AVSampleBufferDisplayLayer.class]) {
            layer.bounds = (CGRect){CGPointZero, size}; layer.position = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
        }
    }
    [CATransaction commit];
}
@end

// Each callback belongs to one selected host. A forgotten or superseded attempt
// must never authorize a new selection when a delayed network response arrives.
@interface NocturnePairingAttempt : NSObject <PairCallback>
@property (nonatomic, weak) NocturneStreamingService *service;
@property TemporaryHost *host;
@property NSString *hostID;
@property NSData *clientCertificate;
@end

@interface NocturneStreamingService () <DiscoveryCallback>
@property DiscoveryManager *discovery;
@property NSMutableDictionary<NSString *, TemporaryHost *> *hosts;
@property NSOperationQueue *operations;
@property NocturnePairingTrust *pairingTrust;
@property NocturnePairingAttempt *pairingAttempt;
@property NSTimer *hostRefreshTimer;
- (void)startPairing:(NSString *)PIN attempt:(NocturnePairingAttempt *)attempt;
- (void)pairSuccessful:(NSData *)serverCert attempt:(NocturnePairingAttempt *)attempt;
- (void)pairFailed:(NSString *)message attempt:(NocturnePairingAttempt *)attempt;
- (void)alreadyPaired:(NocturnePairingAttempt *)attempt;
@end

@implementation NocturnePairingAttempt
- (void)startPairing:(NSString *)PIN { [self.service startPairing:PIN attempt:self]; }
- (void)pairSuccessful:(NSData *)certificate { [self.service pairSuccessful:certificate attempt:self]; }
- (void)pairFailed:(NSString *)message { [self.service pairFailed:message attempt:self]; }
- (void)alreadyPaired { [self.service alreadyPaired:self]; }
@end

@implementation NocturneStreamingService
- (instancetype)init {
    if ((self = [super init])) {
        // The Swift app delegate replaces the upstream main(), which normally
        // marks SDL ready before its audio subsystem can initialize.
        static dispatch_once_t mediaRuntimeOnce;
        dispatch_once(&mediaRuntimeOnce, ^{ SDL_SetMainReady(); });
        _hosts = [NSMutableDictionary dictionary];
        _pairingTrust = [[NocturnePairingTrust alloc] initWithService:@"app.nocturne.streaming-approval"];
        _operations = [NSOperationQueue new]; _operations.maxConcurrentOperationCount = 1;
        [CryptoManager generateKeyPairUsingSSL]; [IdManager getUniqueId];
        NSArray *saved = [[DataManager new] getHosts];
        for (TemporaryHost *host in saved) {
            host.activeAddress = host.address ?: host.localAddress ?: host.externalAddress ?: host.ipv6Address;
            if (host.uuid) _hosts[host.uuid] = host;
        }
        _discovery = [[DiscoveryManager alloc] initWithHosts:saved andCallback:self];
    }
    return self;
}
- (NSData *)workspaceCertificate { return [CryptoManager pemToDer:[CryptoManager readCertFromFile]]; }
- (NSData *)signWorkspaceChallenge:(NSData *)challenge {
    return [[CryptoManager new] signData:challenge withKey:[CryptoManager readKeyFromFile]];
}
- (void)start {
    [self.discovery startDiscovery];
    // Upstream discovery updates host objects in place; its callback only
    // announces changes to the host list. Refresh the Swift value snapshots too.
    if (!self.hostRefreshTimer) {
        __weak typeof(self) weakSelf = self;
        self.hostRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            [weakSelf publishHosts];
        }];
    }
    [self publishHosts];
}
- (void)pause {
    [self.hostRefreshTimer invalidate]; self.hostRefreshTimer = nil;
    [self.discovery stopDiscovery];
}
- (void)updateAllHosts:(NSArray *)hosts {
    NSArray *snapshot = [hosts copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (TemporaryHost *host in snapshot) if (host.uuid) {
            if (host.address.length) host.activeAddress = host.address;
            self.hosts[host.uuid] = host;
        }
        [self publishHosts];
    });
}
- (void)publishHosts {
    NSMutableArray *items = [NSMutableArray array];
    for (TemporaryHost *host in self.hosts.allValues) {
        [items addObject:@{@"id":host.uuid ?: @"", @"name":host.name ?: @"Computer", @"address":host.activeAddress ?: host.localAddress ?: @"",
                          @"online":@(host.state == StateOnline), @"paired":@(host.pairState == PairStatePaired && [self hasApprovalForHost:host]), @"runningApp":host.currentGame ?: @"0"}];
    }
    [items sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(localizedStandardCompare:)]]];
    if (self.hostsChanged) self.hostsChanged(items);
}
- (BOOL)hasApprovalForHost:(TemporaryHost *)host {
    return host && [self.pairingTrust isApprovedHost:host.uuid serverCertificate:host.serverCert
                                 clientCertificate:[CryptoManager readCertFromFile]];
}
- (void)addAddress:(NSString *)address {
    [self.operations addOperationWithBlock:^{
        // Resolve the server UUID directly. Upstream discoverHost reports an already-known
        // host as a nil result ("Host information updated"), which is not a connection failure.
        HttpManager *manager = [[HttpManager alloc] initWithAddress:address httpsPort:0 serverCert:nil];
        ServerInfoResponse *info = [ServerInfoResponse new];
        [manager executeRequestSynchronously:[HttpRequest requestForResponse:info withUrlRequest:[manager newServerInfoRequest:NO]
                                                             fallbackError:401 fallbackRequest:[manager newHttpServerInfoRequest]]];
        if (![info isStatusOk]) { [self pairFailed:@"Cannot reach this computer. Check its address and that Nocturne Server is running."]; return; }
        TemporaryHost *resolved = [TemporaryHost new];
        resolved.activeAddress = resolved.address = address; resolved.state = StateOnline;
        [info populateHost:resolved];
        if (!resolved.uuid.length) { [self pairFailed:@"The streaming server did not return a valid identifier."]; return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            // Preserve the saved certificate and pairing state when re-adding an existing host.
            TemporaryHost *host = self.hosts[resolved.uuid] ?: resolved;
            host.address = host.activeAddress = address; host.localAddress = resolved.localAddress;
            host.httpsPort = resolved.httpsPort; host.state = StateOnline; host.name = resolved.name;
            self.hosts[host.uuid] = host;
            [self.discovery addHostToDiscovery:host]; [[DataManager new] updateHost:host]; [self publishHosts];
            if (self.pairingFinished) self.pairingFinished();
            if (self.addressDiscovered) self.addressDiscovered(host.uuid, address);
        });
    }];
}
- (void)selectHost:(NSString *)hostID {
    TemporaryHost *host = self.hosts[hostID]; if (!host) return;
    NocturnePairingAttempt *attempt = [NocturnePairingAttempt new];
    attempt.service = self; attempt.host = host; attempt.hostID = [hostID copy];
    attempt.clientCertificate = [CryptoManager readCertFromFile];
    self.pairingAttempt = attempt;
    if (host.address.length) host.activeAddress = host.address;
    [self.operations addOperationWithBlock:^{
        if (self.pairingAttempt != attempt) return;
        [self.discovery pauseDiscoveryForHost:host];
        // Cached transport credentials and discovery's PairStatus are not consent.
        // Without a receipt, start a fresh PIN handshake using public server info.
        HttpManager *manager = [[HttpManager alloc] initWithAddress:host.activeAddress httpsPort:host.httpsPort
                                                       serverCert:[self hasApprovalForHost:host] ? host.serverCert : nil];
        ServerInfoResponse *info = [ServerInfoResponse new];
        [manager executeRequestSynchronously:[HttpRequest requestForResponse:info withUrlRequest:[manager newServerInfoRequest:NO]
                                                             fallbackError:401 fallbackRequest:[manager newHttpServerInfoRequest]]];
        [self.discovery resumeDiscoveryForHost:host];
        if (self.pairingAttempt != attempt) return;
        if (![info isStatusOk]) { [attempt pairFailed:info.statusMessage ?: @"Cannot reach this computer. Check that Nocturne Server is running."]; return; }
        if (![[[info getStringTag:TAG_UNIQUE_ID] trim] isEqualToString:attempt.hostID]) {
            [attempt pairFailed:@"This address belongs to a different computer. Add it again to pair securely."]; return;
        }
        [info populateHost:host];
        if (host.pairState == PairStatePaired && [self hasApprovalForHost:host]) [attempt alreadyPaired];
        else {
            [self.discovery stopDiscoveryBlocking];
            PairManager *pair = [[PairManager alloc] initWithManager:manager clientCert:attempt.clientCertificate callback:attempt];
            [pair start];
        }
    }];
}
- (void)startPairing:(NSString *)PIN attempt:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt == attempt && self.pairingPIN) self.pairingPIN(PIN);
    });
}
- (void)pairSuccessful:(NSData *)serverCert attempt:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt) return;
        NSError *error;
        if (![self.pairingTrust approveHost:attempt.hostID serverCertificate:serverCert
                         clientCertificate:attempt.clientCertificate error:&error]) {
            [self pairFailed:error.localizedDescription attempt:attempt]; return;
        }
        attempt.host.serverCert = serverCert; attempt.host.pairState = PairStatePaired;
        [[DataManager new] updateHost:attempt.host];
        [self alreadyPaired:attempt];
    });
}
- (void)pairFailed:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.discovery startDiscovery]; if (self.failed) self.failed(message ?: @"Pairing failed.");
    });
}
- (void)pairFailed:(NSString *)message attempt:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt) return;
        self.pairingAttempt = nil;
        [self.discovery startDiscovery]; [self publishHosts];
        if (self.failed) self.failed(message ?: @"Pairing failed.");
    });
}
- (void)alreadyPaired:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt) return;
        if (![self hasApprovalForHost:attempt.host]) {
            [self pairFailed:@"Approve the pairing PIN on this computer before connecting." attempt:attempt]; return;
        }
        [self.operations addOperationWithBlock:^{ [self loadAppsForAttempt:attempt]; }];
    });
}
- (void)loadAppsForAttempt:(NocturnePairingAttempt *)attempt {
    if (self.pairingAttempt != attempt || ![self hasApprovalForHost:attempt.host]) return;
    TemporaryHost *host = attempt.host;
    AppListResponse *response = [ConnectionHelper getAppListForHost:host];
    if (![response isStatusOk]) { [self pairFailed:@"The computer did not return its app library. Try connecting again." attempt:attempt]; return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt || ![self hasApprovalForHost:host]) return;
        host.appList = [response getAppList];
        NSMutableArray *apps = [NSMutableArray array];
        for (TemporaryApp *app in host.appList) {
            app.host = host;
            [apps addObject:@{@"id":app.id ?: @"", @"name":app.name ?: @"App", @"hdr":@(app.hdrSupported)}];
        }
        [[DataManager new] updateHost:host]; [[DataManager new] updateAppsForExistingHost:host];
        self.pairingAttempt = nil;
        [self.discovery startDiscovery]; [self publishHosts];
        if (self.appsChanged) self.appsChanged(host.uuid, apps);
        if (self.pairingFinished) self.pairingFinished();
    });
}
- (BOOL)forgetHost:(NSString *)hostID {
    if ([self.pairingAttempt.hostID isEqualToString:hostID]) self.pairingAttempt = nil;
    NSError *error;
    if (![self.pairingTrust forgetHost:hostID error:&error]) {
        if (self.failed) self.failed(error.localizedDescription); return NO;
    }
    TemporaryHost *host = self.hosts[hostID];
    if (host) {
        host.serverCert = nil; host.pairState = PairStateUnpaired; host.appList = [NSSet set];
        [self.discovery removeHostFromDiscovery:host]; [[DataManager new] removeHost:host];
    }
    [self.hosts removeObjectForKey:hostID]; [self publishHosts];
    return YES;
}
- (UIViewController *)streamHost:(NSString *)hostID app:(NSString *)appID settings:(NSDictionary *)settings onExit:(void (^)(void))onExit {
    TemporaryHost *host = self.hosts[hostID];
    TemporaryApp *chosen = nil;
    for (TemporaryApp *app in host.appList) if ([app.id isEqualToString:appID]) chosen = app;
    if (!host || !chosen || host.pairState != PairStatePaired || ![self hasApprovalForHost:host]) return nil;
    int width = [settings[@"width"] intValue], height = [settings[@"height"] intValue];
    int fps = [settings[@"fps"] intValue], bitrate = [settings[@"bitrate"] intValue] * 1000;
    BOOL hdr = [settings[@"hdr"] boolValue], pacing = [settings[@"pacing"] boolValue];
    BOOL multi = [settings[@"multi"] boolValue];
    [[DataManager new] saveSettingsWithBitrate:bitrate framerate:fps height:height width:width audioConfig:2
        onscreenControls:[settings[@"touch"] boolValue] ? OnScreenControlsLevelAuto : OnScreenControlsLevelOff
        optimizeGames:NO multiController:multi swapABXYButtons:NO audioOnPC:NO preferredCodec:CODEC_PREF_AUTO
        useFramePacing:pacing enableHdr:hdr btMouseSupport:YES absoluteTouchMode:[settings[@"absolute"] boolValue]
        statsOverlay:[settings[@"statistics"] boolValue]];
    StreamConfiguration *config = [StreamConfiguration new];
    config.host = host.activeAddress; config.httpsPort = host.httpsPort; config.serverCert = host.serverCert;
    config.appID = chosen.id; config.appName = chosen.name; config.serverCodecModeSupport = host.serverCodecModeSupport;
    config.width = width; config.height = height; config.frameRate = MIN(fps, (int)UIScreen.mainScreen.maximumFramesPerSecond);
    config.bitRate = bitrate; config.useFramePacing = pacing; config.multiController = multi;
    config.gamepadMask = [ControllerSupport getConnectedGamepadMask:config]; config.audioConfiguration = AUDIO_CONFIGURATION_STEREO;
    config.supportedVideoFormats = VIDEO_FORMAT_H264;
    if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        config.supportedVideoFormats |= VIDEO_FORMAT_H265;
        if (hdr && (AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10)) config.supportedVideoFormats |= VIDEO_FORMAT_H265_MAIN10;
    }
    MDStreamController *controller = [MDStreamController new]; controller.streamConfig = config; controller.onExit = onExit;
    [self pause];
    return controller;
}
- (void)stopController:(UIViewController *)controller { if ([controller isKindOfClass:MDStreamController.class]) [(MDStreamController *)controller shutdown]; }
- (void)stopController:(UIViewController *)controller completion:(void (^)(void))completion {
    [self stopController:controller];
    if ([controller isKindOfClass:MDStreamController.class]) [(MDStreamController *)controller nocturneStopWithCompletion:completion];
    else completion();
}
@end
