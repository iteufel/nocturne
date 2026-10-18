#import <XCTest/XCTest.h>
#import "NocturneStreamingService.h"
#import "NocturnePairingTrust.h"
#import "CryptoManager.h"
#import "TemporaryHost.h"
#import "TemporaryApp.h"

@interface PairingAuthorizationTests : XCTestCase
@property NocturneStreamingService *engine;
@property NocturnePairingTrust *trust;
@property TemporaryHost *host;
@property TemporaryApp *desktop;
@end

@interface NocturneStreamingService (PairingTests)
- (void)publishHosts;
- (void)updateAllHosts:(NSArray *)hosts;
- (void)pairSuccessful:(NSData *)certificate attempt:(id)attempt;
- (void)alreadyPaired:(id)attempt;
- (void)startPairing:(NSString *)challenge attempt:(id)attempt;
- (void)loadAppsForAttempt:(id)attempt;
@end

// Exercise real authorization/callback ordering without contacting a streaming
// host or starting capture. Only the final app-list HTTP request is substituted.
@interface QRPairingTestService : NocturneStreamingService
@property (nonatomic, copy) void (^libraryRequested)(void);
@end
@implementation QRPairingTestService
- (void)loadAppsForAttempt:(id)attempt {
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.libraryRequested) self.libraryRequested(); });
}
@end

@implementation PairingAuthorizationTests
- (void)setUp {
    [super setUp];
    self.engine = [QRPairingTestService new];
    [self.engine pause];
    self.trust = [[NocturnePairingTrust alloc] initWithService:[@"app.nocturne.tests." stringByAppendingString:NSUUID.UUID.UUIDString]];
    [self.engine setValue:self.trust forKey:@"pairingTrust"];
    TemporaryHost *host = [TemporaryHost new];
    host.uuid = NSUUID.UUID.UUIDString;
    host.name = @"Unpaired regression computer";
    host.activeAddress = @"127.0.0.1";
    host.httpsPort = 47984;
    host.state = StateOnline;
    host.pairState = PairStatePaired;
    // A cached transport certificate is not a Nocturne pairing approval.
    host.serverCert = [@"cached-server-certificate" dataUsingEncoding:NSUTF8StringEncoding];
    TemporaryApp *desktop = [TemporaryApp new];
    desktop.id = @"1"; desktop.name = @"Desktop"; desktop.host = host;
    host.appList = [NSSet setWithObject:desktop];
    self.host = host; self.desktop = desktop;
    [self.engine setValue:[@{host.uuid:host} mutableCopy] forKey:@"hosts"];
}
- (void)tearDown {
    [self.engine cancelPairing];
    [self.engine pause];
    // Successful callbacks persist the fixture in Core Data as well as Keychain.
    XCTAssertTrue([self.engine forgetHost:self.host.uuid]);
    self.engine.canPairHost = nil; self.engine.authorizePairing = nil;
    ((QRPairingTestService *)self.engine).libraryRequested = nil;
    [super tearDown];
}
- (UIViewController *)streamController {
    return [self.engine streamHost:self.host.uuid app:self.desktop.id
        settings:@{@"width":@1920,@"height":@1080,@"fps":@60,@"bitrate":@20} onExit:^{}];
}
- (void)approveFixture {
    NSError *error;
    XCTAssertTrue([self.trust approveHost:self.host.uuid serverCertificate:self.host.serverCert
                      clientCertificate:[CryptoManager readCertFromFile] error:&error], @"%@", error);
}
- (id)pendingAttempt {
    id attempt = [NSClassFromString(@"NocturnePairingAttempt") new];
    [attempt setValue:self.engine forKey:@"service"];
    [attempt setValue:self.host forKey:@"host"];
    [attempt setValue:self.host.uuid forKey:@"hostID"];
    [attempt setValue:[CryptoManager readCertFromFile] forKey:@"clientCertificate"];
    [self.engine setValue:attempt forKey:@"pairingAttempt"];
    return attempt;
}
- (void)testCachedStreamingCertificateDoesNotAuthorizeComputer {

    __block NSDictionary *published;
    self.engine.hostsChanged = ^(NSArray<NSDictionary *> *hosts) { published = hosts.firstObject; };
    [self.engine publishHosts];
    XCTAssertFalse([published[@"paired"] boolValue], @"Discovery must not promote cached credentials into pairing approval");
    XCTAssertNil([self streamController], @"Selecting a computer must not bypass explicit pairing");
}
- (void)testApprovalPersistsAndBindsBothCertificatesAndHost {
    [self approveFixture];
    NSString *service = [self.trust valueForKey:@"service"];
    NocturnePairingTrust *reopened = [[NocturnePairingTrust alloc] initWithService:service];
    NSData *client = [CryptoManager readCertFromFile];
    NSData *other = [@"different-identity" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertTrue([reopened isApprovedHost:self.host.uuid serverCertificate:self.host.serverCert clientCertificate:client]);
    XCTAssertFalse([reopened isApprovedHost:NSUUID.UUID.UUIDString serverCertificate:self.host.serverCert clientCertificate:client]);
    XCTAssertFalse([reopened isApprovedHost:self.host.uuid serverCertificate:other clientCertificate:client]);
    XCTAssertFalse([reopened isApprovedHost:self.host.uuid serverCertificate:self.host.serverCert clientCertificate:other]);
    XCTAssertFalse([reopened isApprovedHost:self.host.uuid serverCertificate:nil clientCertificate:client]);
}
- (void)testRediscoveryAndSelectionKeepTheCurrentAddress {
    [self approveFixture];
    self.host.address = @"192.0.2.10";
    self.host.activeAddress = self.host.localAddress = @"192.0.2.20";
    [self.engine updateAllHosts:@[self.host]];
    [self drainPairingCallbacks];
    XCTAssertEqualObjects(self.host.activeAddress, @"192.0.2.20");

    NSOperationQueue *operations = [self.engine valueForKey:@"operations"];
    operations.suspended = YES;
    [self.engine selectHost:self.host.uuid];
    XCTAssertEqualObjects(self.host.activeAddress, @"192.0.2.20", @"Selection must not restore the obsolete QR address");
    [self.engine cancelPairing];
    [operations cancelAllOperations]; operations.suspended = NO;
}
- (void)testAuthenticatedAddressUpdatePreservesApprovalAndCannotApproveAnotherHost {
    [self approveFixture];
    NSData *certificate = self.host.serverCert;
    [self.engine updateHostAddress:self.host.uuid address:@"192.0.2.30"];
    XCTAssertEqualObjects(self.host.activeAddress, @"192.0.2.30");
    XCTAssertEqualObjects(self.host.address, @"192.0.2.30");
    XCTAssertEqualObjects(self.host.localAddress, @"192.0.2.30");
    XCTAssertEqualObjects(self.host.serverCert, certificate);
    XCTAssertNotNil([self streamController]);
    [self.engine updateHostAddress:NSUUID.UUID.UUIDString address:@"192.0.2.40"];
    XCTAssertEqualObjects(self.host.activeAddress, @"192.0.2.30");
    XCTAssertTrue([self.trust forgetHost:self.host.uuid error:nil]);
    [self.engine updateHostAddress:self.host.uuid address:@"192.0.2.50"];
    XCTAssertNil([self streamController], @"An address update must never grant pairing approval");
}
- (void)testApprovedHostCanStreamButRediscoveryAfterForgetCannot {
    [self approveFixture];
    XCTAssertNotNil([self streamController], @"A successfully approved computer remains usable");
    NSData *cachedCertificate = self.host.serverCert;
    XCTAssertTrue([self.engine forgetHost:self.host.uuid]);
    // Simulate a stale discovery callback or restored database after forgetting.
    self.host.serverCert = cachedCertificate; self.host.pairState = PairStatePaired;
    self.host.appList = [NSSet setWithObject:self.desktop];
    [self.engine setValue:[@{self.host.uuid:self.host} mutableCopy] forKey:@"hosts"];
    XCTAssertNil([self streamController]);
}
- (void)testChangedCertificateCannotLaunchEvenWithPairStatus {
    [self approveFixture];
    self.host.serverCert = [@"replacement-server" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertNil([self streamController]);
}
- (void)testAlreadyPairedCallbackCannotCreateApprovalOrOpenLibrary {
    XCTestExpectation *rejected = [self expectationWithDescription:@"Unapproved callback rejected"];
    self.engine.failed = ^(NSString *message) { [rejected fulfill]; };
    self.engine.appsChanged = ^(NSString *hostID, NSArray *apps) { XCTFail(@"Library opened without approval"); };
    [self.engine alreadyPaired:[self pendingAttempt]];
    [self waitForExpectations:@[rejected] timeout:2];
    XCTAssertNil([self streamController]);
}
- (void)testLatePairingSuccessCannotUndoForget {
    id attempt = [self pendingAttempt];
    NSData *certificate = self.host.serverCert;
    // The network callback is queued while Forget runs on the main thread.
    [self.engine pairSuccessful:certificate attempt:attempt];
    XCTAssertTrue([self.engine forgetHost:self.host.uuid]);
    XCTestExpectation *drained = [self expectationWithDescription:@"Queued callback processed"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:2];
    XCTAssertFalse([self.trust isApprovedHost:self.host.uuid serverCertificate:certificate
                          clientCertificate:[CryptoManager readCertFromFile]]);
    XCTAssertNil([self streamController]);
}
- (void)testUnapprovedComputerSelectionRequiresQRBeforeStartingHandshake {
    __block NSUInteger requests = 0;
    self.engine.pairingRequired = ^{ requests++; };
    self.engine.authorizePairing = ^(NSString *host, NSString *challenge, void (^completion)(BOOL)) {
        XCTFail(@"A computer selected without QR trust started a handshake");
    };
    [self.engine selectHost:self.host.uuid];
    XCTAssertEqual(requests, 1u);
    XCTAssertNil([self.engine valueForKey:@"pairingAttempt"]);
    XCTAssertNil([self streamController]);
}
- (void)testUnscannedHandshakeSuccessCannotCreateApproval {
    XCTestExpectation *rejected = [self expectationWithDescription:@"Unscanned handshake rejected"];
    self.engine.failed = ^(NSString *message) { [rejected fulfill]; };
    [self.engine pairSuccessful:self.host.serverCert attempt:[self pendingAttempt]];
    [self waitForExpectations:@[rejected] timeout:2];
    XCTAssertNil([self streamController]);
}
- (void)drainPairingCallbacks {
    XCTestExpectation *drained = [self expectationWithDescription:@"Pairing callbacks drained"];
    dispatch_async(dispatch_get_main_queue(), ^{ [drained fulfill]; });
    [self waitForExpectations:@[drained] timeout:2];
}
- (id)qrAttempt {
    NSString *hostID = self.host.uuid;
    self.engine.canPairHost = ^BOOL(NSString *host) { return [host isEqualToString:hostID]; };
    id attempt = [self pendingAttempt]; [attempt setValue:@YES forKey:@"qrAuthorized"];
    return attempt;
}
- (void)assertQRPairingWorkspaceFirst:(BOOL)workspaceFirst {
    id attempt = [self qrAttempt];
    XCTestExpectation *requested = [self expectationWithDescription:@"QR workspace approval requested"];
    XCTestExpectation *library = [self expectationWithDescription:@"Authorized library requested"];
    __block void (^authorize)(BOOL);
    NSString *expectedHost = self.host.uuid;
    self.engine.authorizePairing = ^(NSString *host, NSString *challenge, void (^completion)(BOOL)) {
        XCTAssertEqualObjects(host, expectedHost); XCTAssertEqualObjects(challenge, @"1234");
        authorize = [completion copy]; [requested fulfill];
    };
    ((QRPairingTestService *)self.engine).libraryRequested = ^{ [library fulfill]; };
    [self.engine startPairing:@"1234" attempt:attempt];
    [self waitForExpectations:@[requested] timeout:2];
    if (workspaceFirst) authorize(YES);
    else [self.engine pairSuccessful:self.host.serverCert attempt:attempt];
    [self drainPairingCallbacks];
    XCTAssertNil([self streamController], @"Both successful responses are required before trusting the host");
    if (workspaceFirst) [self.engine pairSuccessful:self.host.serverCert attempt:attempt];
    else authorize(YES);
    [self waitForExpectations:@[library] timeout:2];
    XCTAssertNotNil([self streamController]);
}
- (void)testQRApprovalBeforeVideoHandshakeCanPair { [self assertQRPairingWorkspaceFirst:YES]; }
- (void)testVideoHandshakeBeforeQRApprovalWaitsForAuthorization { [self assertQRPairingWorkspaceFirst:NO]; }
- (void)testFailedQRApprovalCannotFallBackToVideoHandshake {
    id attempt = [self qrAttempt];
    XCTestExpectation *rejected = [self expectationWithDescription:@"QR approval rejected"];
    self.engine.failed = ^(NSString *message) { [rejected fulfill]; };
    self.engine.authorizePairing = ^(NSString *host, NSString *challenge, void (^completion)(BOOL)) { completion(NO); };
    [self.engine pairSuccessful:self.host.serverCert attempt:attempt];
    [self.engine startPairing:@"1234" attempt:attempt];
    [self waitForExpectations:@[rejected] timeout:2];
    XCTAssertNil([self streamController]);
}
- (void)testLostQRConnectionInvalidatesLateApproval {
    id attempt = [self qrAttempt];
    XCTestExpectation *requested = [self expectationWithDescription:@"QR workspace approval requested"];
    XCTestExpectation *rejected = [self expectationWithDescription:@"Disconnected QR approval rejected"];
    __block void (^authorize)(BOOL);
    self.engine.failed = ^(NSString *message) { [rejected fulfill]; };
    self.engine.authorizePairing = ^(NSString *host, NSString *challenge, void (^completion)(BOOL)) {
        authorize = [completion copy]; [requested fulfill];
    };
    [self.engine startPairing:@"1234" attempt:attempt];
    [self waitForExpectations:@[requested] timeout:2];
    [self.engine pairSuccessful:self.host.serverCert attempt:attempt];
    [self drainPairingCallbacks];
    self.engine.canPairHost = ^BOOL(NSString *host) { return NO; };
    authorize(YES);
    [self waitForExpectations:@[rejected] timeout:2];
    XCTAssertNil([self streamController]);
}
@end
