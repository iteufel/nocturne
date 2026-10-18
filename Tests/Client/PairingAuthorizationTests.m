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
- (void)pairSuccessful:(NSData *)certificate attempt:(id)attempt;
- (void)alreadyPaired:(id)attempt;
@end

@implementation PairingAuthorizationTests
- (void)setUp {
    [super setUp];
    self.engine = [NocturneStreamingService new];
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
    [self.engine pause];
    NSError *error;
    XCTAssertTrue([self.trust forgetHost:self.host.uuid error:&error], @"%@", error);
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
@end
