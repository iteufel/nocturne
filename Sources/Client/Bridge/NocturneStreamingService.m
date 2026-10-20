#import "NocturneStreamingService.h"
#import "NocturnePairingTrust.h"
#import "NocturneStreamLifecycle.h"
#import "NocturneStreamInput.h"
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
#import <openssl/pem.h>
#define SDL_MAIN_HANDLED
#import <SDL.h>
#include <Limelight.h>

NSNotificationName const NocturneStreamControlsRequestedNotification = @"NocturneStreamControlsRequested";

@interface StreamFrameViewController (DarkLifecycle)
- (void)returnToMainFrame;
- (void)nocturneStopWithCompletion:(void (^)(void))completion;
@end

@interface MDStreamController : StreamFrameViewController
@property (nonatomic, copy) void (^onExit)(void);
@property (nonatomic, copy) void (^onStarted)(UIViewController *controller);
@property (nonatomic, copy) void (^onFailure)(UIViewController *controller, NSString *message);
@property (nonatomic) BOOL cleanedUp;
@property (nonatomic) CGSize lastControlSize;
@property (nonatomic) BOOL absoluteTouchMode;
@property (nonatomic) BOOL fillEntireScreen;
@property (nonatomic) BOOL pointerCaptureEnabled;
- (void)shutdown;
@end
@implementation MDStreamController
- (BOOL)prefersPointerLocked { return self.pointerCaptureEnabled && !self.cleanedUp && [super prefersPointerLocked]; }
- (void)setPointerCaptureEnabled:(BOOL)enabled {
    BOOL changed = _pointerCaptureEnabled != enabled;
    _pointerCaptureEnabled = enabled;
    if (!enabled && self.isViewLoaded) [self nocturneReleaseInput];
    if (enabled && changed && self.isViewLoaded) [self nocturneFocusInput];
    [self setNeedsUpdateOfPrefersPointerLocked];
}
- (void)setFillEntireScreen:(BOOL)fill {
    _fillEntireScreen = fill;
    if (self.isViewLoaded) {
        [self nocturneReleaseInput];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    }
}
- (void)setAbsoluteTouchMode:(BOOL)absolute {
    _absoluteTouchMode = absolute;
    if (self.isViewLoaded) [self nocturneSetAbsoluteTouchMode:absolute];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self nocturneSetAbsoluteTouchMode:self.absoluteTouchMode];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pointerLockChanged:)
        name:UIPointerLockStateDidChangeNotification object:nil];
}
- (void)pointerLockChanged:(NSNotification *)notification {
    if (notification.userInfo[UIPointerLockStateSceneUserInfoKey] == self.view.window.windowScene) [self nocturneReleaseInput];
}
- (void)returnToMainFrame { if (!self.cleanedUp && self.onExit) self.onExit(); }
- (void)connectionStarted {
    [super connectionStarted];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.cleanedUp && self.onStarted) self.onStarted(self); });
}
- (void)reportFailure:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cleanedUp && self.onFailure) self.onFailure(self, message);
    });
}
- (void)launchFailed:(NSString *)message { [self reportFailure:message ?: @"Screen sharing could not start."]; }
- (void)stageFailed:(const char *)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    [self reportFailure:[NSString stringWithFormat:@"Screen sharing failed at %s (error %d). Check the host and network, then try again.", stageName, errorCode]];
}
- (void)connectionTerminated:(int)errorCode {
    if (errorCode == ML_ERROR_GRACEFUL_TERMINATION) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self returnToMainFrame]; });
    } else if (errorCode == ML_ERROR_NO_VIDEO_TRAFFIC || errorCode == ML_ERROR_NO_VIDEO_FRAME) {
        [self reportFailure:@"The host connected but no video arrived. Check screen capture on the host and your network, then try again."];
    } else {
        [self reportFailure:[NSString stringWithFormat:@"Screen sharing ended unexpectedly (error %d). Reconnect to try again.", errorCode]];
    }
}
- (void)shutdown {
    if (self.cleanedUp) return;
    self.cleanedUp = YES;
    self.pointerCaptureEnabled = NO;
    if (self.isViewLoaded) [self nocturneReleaseInput];
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
    if ([view isKindOfClass:StreamView.class]) ((StreamView *)view).nocturneFillEntireScreen = self.fillEntireScreen;
    if ([view isKindOfClass:StreamView.class] && !CGSizeEqualToSize(self.lastControlSize, view.bounds.size)) {
        if (!CGSizeEqualToSize(self.lastControlSize, CGSizeZero)) [(StreamView *)view showOnScreenControls];
        self.lastControlSize = view.bounds.size;
    }
    CGFloat ratio = (CGFloat)self.streamConfig.width / MAX(1, self.streamConfig.height);
    CGSize size = NocturneVideoAreaSize(view.bounds.size, ratio, self.fillEntireScreen);
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
@property BOOL qrAuthorized;
@property BOOL workspaceApproved;
@property BOOL approvalRecorded;
@property NSData *pendingServerCertificate;
@end

@interface NocturneStreamingService () <DiscoveryCallback>
@property DiscoveryManager *discovery;
@property NSMutableDictionary<NSString *, TemporaryHost *> *hosts;
@property NSMutableDictionary<NSString *, NSString *> *addressOverrides;
@property NSOperationQueue *operations;
@property NocturnePairingTrust *pairingTrust;
@property NocturnePairingAttempt *pairingAttempt;
@property NSUUID *addressRequest;
@property NSTimer *hostRefreshTimer;
- (void)startPairing:(NSString *)PIN attempt:(NocturnePairingAttempt *)attempt;
- (void)pairSuccessful:(NSData *)serverCert attempt:(NocturnePairingAttempt *)attempt;
- (void)pairFailed:(NSString *)message attempt:(NocturnePairingAttempt *)attempt;
- (void)alreadyPaired:(NocturnePairingAttempt *)attempt;
- (void)completePairingIfReady:(NocturnePairingAttempt *)attempt;
- (void)requireQRPairing;
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
        _addressOverrides = [NSMutableDictionary dictionary];
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
- (NSData *)workspacePrivateKey {
    NSData *pem = [CryptoManager readKeyFromFile];
    BIO *bio = BIO_new_mem_buf(pem.bytes, (int)pem.length);
    if (!bio) return nil;
    EVP_PKEY *key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
    BIO_free(bio);
    if (!key) return nil;
    unsigned char *der = NULL;
    int length = i2d_PrivateKey(key, &der);
    NSData *result = length > 0 ? [NSData dataWithBytes:der length:(NSUInteger)length] : nil;
    OPENSSL_clear_free(der, length > 0 ? (size_t)length : 0);
    EVP_PKEY_free(key);
    return result;
}
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
            self.hosts[host.uuid] = host;
        }
        [self publishHosts];
    });
}
- (void)publishHosts {
    NSMutableArray *items = [NSMutableArray array];
    for (TemporaryHost *host in self.hosts.allValues) {
        if (self.addressOverrides[host.uuid]) {
            host.activeAddress = self.addressOverrides[host.uuid]; host.state = StateOnline;
        }
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
- (void)updateHostAddress:(NSString *)hostID address:(NSString *)address {
    // Called only after the linked workspace authenticates at this address.
    // Retain the UUID, pinned certificates, and explicit pairing approval.
    TemporaryHost *host = self.hosts[hostID];
    if (!host || !address.length) return;
    if ([address isEqualToString:@"127.0.0.1"]) {
        // The tunnel address is valid only in this app process. Preserve the real LAN address.
        self.addressOverrides[hostID] = address; host.activeAddress = address;
        [self.discovery pauseDiscoveryForHost:host];
    } else {
        BOOL wasRemote = self.addressOverrides[hostID] != nil;
        [self.addressOverrides removeObjectForKey:hostID];
        host.address = host.localAddress = host.activeAddress = address;
        if (wasRemote) [self.discovery resumeDiscoveryForHost:host];
        [[DataManager new] updateHost:host];
    }
    [self publishHosts];
}
- (void)clearTemporaryAddress:(NSString *)hostID {
    if (!self.addressOverrides[hostID]) return;
    [self.addressOverrides removeObjectForKey:hostID];
    TemporaryHost *host = self.hosts[hostID];
    if (host) {
        host.activeAddress = host.address ?: host.localAddress; host.state = StateOffline;
        [self.discovery resumeDiscoveryForHost:host];
    }
    [self publishHosts];
}
- (void)addAddress:(NSString *)address {
    NSUUID *request = NSUUID.UUID;
    self.addressRequest = request;
    [self.operations addOperationWithBlock:^{
        if (self.addressRequest != request) return;
        // Resolve the server UUID directly. Upstream discoverHost reports an already-known
        // host as a nil result ("Host information updated"), which is not a connection failure.
        HttpManager *manager = [[HttpManager alloc] initWithAddress:address httpsPort:0 serverCert:nil];
        ServerInfoResponse *info = [ServerInfoResponse new];
        [manager executeRequestSynchronously:[HttpRequest requestForResponse:info withUrlRequest:[manager newServerInfoRequest:NO]
                                                             fallbackError:401 fallbackRequest:[manager newHttpServerInfoRequest]]];
        if (![info isStatusOk]) {
            Log(LOG_W, @"Screen sharing lookup failed for %@ (%d): %@", address, info.statusCode, info.statusMessage);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.addressRequest != request) return;
                self.addressRequest = nil;
                if (self.failed) self.failed(@"Cannot reach screen sharing on this host. Check that Nocturne Server is running, then try again.");
            });
            return;
        }
        TemporaryHost *resolved = [TemporaryHost new];
        resolved.activeAddress = resolved.address = address; resolved.state = StateOnline;
        [info populateHost:resolved];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.addressRequest != request) return;
            self.addressRequest = nil;
            if (!resolved.uuid.length) {
                if (self.failed) self.failed(@"The streaming server did not return a valid identifier.");
                return;
            }
            // Preserve the saved certificate and pairing state when re-adding an existing host.
            TemporaryHost *host = self.hosts[resolved.uuid] ?: resolved;
            host.activeAddress = address; host.localAddress = resolved.localAddress;
            if ([address isEqualToString:@"127.0.0.1"]) {
                host.address = resolved.localAddress; self.addressOverrides[resolved.uuid] = address;
            } else { host.address = address; [self.addressOverrides removeObjectForKey:resolved.uuid]; }
            host.httpsPort = resolved.httpsPort; host.state = StateOnline; host.name = resolved.name;
            self.hosts[host.uuid] = host;
            [self.discovery addHostToDiscovery:host]; [[DataManager new] updateHost:host]; [self publishHosts];
            if (self.addressOverrides[host.uuid]) [self.discovery pauseDiscoveryForHost:host];
            if (self.addressDiscovered) self.addressDiscovered(host.uuid, address);
        });
    }];
}
- (void)selectHost:(NSString *)hostID {
    TemporaryHost *host = self.hosts[hostID]; if (!host) return;
    if (self.addressOverrides[hostID]) host.activeAddress = self.addressOverrides[hostID];
    BOOL qrAuthorized = self.canPairHost && self.canPairHost(hostID);
    if (![self hasApprovalForHost:host] && !qrAuthorized) { [self requireQRPairing]; return; }
    NocturnePairingAttempt *attempt = [NocturnePairingAttempt new];
    attempt.service = self; attempt.host = host; attempt.hostID = [hostID copy];
    attempt.clientCertificate = [CryptoManager readCertFromFile];
    attempt.qrAuthorized = qrAuthorized;
    self.pairingAttempt = attempt;
    NSString *connectionAddress = [host.activeAddress copy];
    BOOL remote = self.addressOverrides[hostID] != nil;
    [self.operations addOperationWithBlock:^{
        if (self.pairingAttempt != attempt) return;
        [self.discovery pauseDiscoveryForHost:host];
        // Cached transport credentials and discovery's PairStatus are not consent.
        // Without a receipt, QR authorization is required for a fresh handshake.
        HttpManager *manager = [[HttpManager alloc] initWithAddress:connectionAddress httpsPort:host.httpsPort
                                                       serverCert:[self hasApprovalForHost:host] ? host.serverCert : nil];
        ServerInfoResponse *info = [ServerInfoResponse new];
        [manager executeRequestSynchronously:[HttpRequest requestForResponse:info withUrlRequest:[manager newServerInfoRequest:NO]
                                                             fallbackError:401 fallbackRequest:[manager newHttpServerInfoRequest]]];
        if (!remote) [self.discovery resumeDiscoveryForHost:host];
        if (self.pairingAttempt != attempt) return;
        if (![info isStatusOk]) { [attempt pairFailed:info.statusMessage ?: @"Cannot reach this computer. Check that Nocturne Server is running."]; return; }
        if (![[[info getStringTag:TAG_UNIQUE_ID] trim] isEqualToString:attempt.hostID]) {
            [attempt pairFailed:@"This address belongs to a different computer. Add it again to pair securely."]; return;
        }
        [info populateHost:host];
        if (host.pairState == PairStatePaired && [self hasApprovalForHost:host]) [attempt alreadyPaired];
        else {
            if (!attempt.qrAuthorized) {
                dispatch_async(dispatch_get_main_queue(), ^{ if (self.pairingAttempt == attempt) [self requireQRPairing]; });
                return;
            }
            [self.discovery stopDiscoveryBlocking];
            PairManager *pair = [[PairManager alloc] initWithManager:manager clientCert:attempt.clientCertificate callback:attempt];
            [pair start];
        }
    }];
}
- (void)startPairing:(NSString *)PIN attempt:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt) return;
        if (!attempt.qrAuthorized || !self.canPairHost || !self.canPairHost(attempt.hostID) || !self.authorizePairing) {
            [self requireQRPairing]; return;
        }
        __weak typeof(self) weakSelf = self;
        self.authorizePairing(attempt.hostID, PIN, ^(BOOL approved) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self = weakSelf;
                if (!self || self.pairingAttempt != attempt) return;
                if (!approved) { [self pairFailed:@"Screen sharing approval failed. Reconnect to the host and try again." attempt:attempt]; return; }
                attempt.workspaceApproved = YES;
                [self completePairingIfReady:attempt];
            });
        });
    });
}
- (void)pairSuccessful:(NSData *)serverCert attempt:(NocturnePairingAttempt *)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pairingAttempt != attempt) return;
        if (!attempt.qrAuthorized || !self.canPairHost || !self.canPairHost(attempt.hostID)) {
            [self pairFailed:@"Scan the QR code on your computer before pairing this computer." attempt:attempt]; return;
        }
        attempt.pendingServerCertificate = serverCert;
        [self completePairingIfReady:attempt];
    });
}
- (void)completePairingIfReady:(NocturnePairingAttempt *)attempt {
    if (self.pairingAttempt != attempt || attempt.approvalRecorded) return;
    if (!attempt.qrAuthorized || !self.canPairHost || !self.canPairHost(attempt.hostID)) {
        [self pairFailed:@"The host connection was lost before screen sharing finished. Reconnect and try again." attempt:attempt]; return;
    }
    // Either network callback may arrive first. Both must succeed before trust
    // is persisted or the app library opens.
    if (!attempt.workspaceApproved || !attempt.pendingServerCertificate.length) return;
    NSError *error;
    if (![self.pairingTrust approveHost:attempt.hostID serverCertificate:attempt.pendingServerCertificate
                         clientCertificate:attempt.clientCertificate error:&error]) {
        [self pairFailed:error.localizedDescription attempt:attempt]; return;
    }
    attempt.approvalRecorded = YES;
    attempt.host.serverCert = attempt.pendingServerCertificate; attempt.host.pairState = PairStatePaired;
    [[DataManager new] updateHost:attempt.host];
    [self alreadyPaired:attempt];
}
- (void)cancelPairing { self.pairingAttempt = nil; self.addressRequest = nil; }
- (void)requireQRPairing {
    [self cancelPairing]; [self.discovery startDiscovery]; [self publishHosts];
    if (self.pairingRequired) self.pairingRequired();
    else if (self.failed) self.failed(@"Scan the QR code in Nocturne Server to pair this computer.");
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
            [self pairFailed:@"Scan the QR code on this computer before connecting." attempt:attempt]; return;
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
    [self.addressOverrides removeObjectForKey:hostID];
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
    config.host = self.addressOverrides[hostID] ?: host.activeAddress; config.httpsPort = host.httpsPort; config.serverCert = host.serverCert;
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
    controller.absoluteTouchMode = [settings[@"absolute"] boolValue];
    controller.fillEntireScreen = [settings[@"fill"] boolValue];
    controller.onStarted = self.streamStarted;
    controller.onFailure = self.streamFailed;
    [self pause];
    return controller;
}
- (void)setTouchMode:(BOOL)absolute controller:(UIViewController *)controller {
    if ([controller isKindOfClass:MDStreamController.class] && !((MDStreamController *)controller).cleanedUp) {
        ((MDStreamController *)controller).absoluteTouchMode = absolute;
    }
}
- (void)setFillEntireScreen:(BOOL)fill controller:(UIViewController *)controller {
    if ([controller isKindOfClass:MDStreamController.class] && !((MDStreamController *)controller).cleanedUp) {
        ((MDStreamController *)controller).fillEntireScreen = fill;
    }
}
- (void)setPointerCapture:(BOOL)enabled controller:(UIViewController *)controller {
    if ([controller isKindOfClass:MDStreamController.class]) ((MDStreamController *)controller).pointerCaptureEnabled = enabled;
}
- (void)stopController:(UIViewController *)controller { if ([controller isKindOfClass:MDStreamController.class]) [(MDStreamController *)controller shutdown]; }
- (void)stopController:(UIViewController *)controller completion:(void (^)(void))completion {
    [self stopController:controller];
    if ([controller isKindOfClass:MDStreamController.class]) [(MDStreamController *)controller nocturneStopWithCompletion:completion];
    else completion();
}
@end
