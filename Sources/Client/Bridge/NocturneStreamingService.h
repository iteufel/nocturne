#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface NocturneStreamingService : NSObject
@property (nonatomic, copy, nullable) void (^hostsChanged)(NSArray<NSDictionary *> *hosts);
@property (nonatomic, copy, nullable) void (^appsChanged)(NSString *hostID, NSArray<NSDictionary *> *apps);
@property (nonatomic, copy, nullable) void (^addressDiscovered)(NSString *hostID, NSString *address);
// These callbacks run on the main queue. Only an authenticated QR workspace may
// authorize a new video handshake; the protocol's challenge is never displayed.
@property (nonatomic, copy, nullable) BOOL (^canPairHost)(NSString *hostID);
@property (nonatomic, copy, nullable) void (^authorizePairing)(NSString *hostID, NSString *challenge, void (^completion)(BOOL approved));
@property (nonatomic, copy, nullable) void (^pairingRequired)(void);
@property (nonatomic, copy, nullable) void (^pairingFinished)(void);
@property (nonatomic, copy, nullable) void (^failed)(NSString *message);
@property (nonatomic, copy, nullable) void (^streamStarted)(UIViewController *controller);
- (NSData *)workspaceCertificate;
- (nullable NSData *)workspacePrivateKey;
- (NSData *)signWorkspaceChallenge:(NSData *)challenge;
- (void)start;
- (void)pause;
- (void)addAddress:(NSString *)address;
- (void)updateHostAddress:(NSString *)hostID address:(NSString *)address NS_SWIFT_NAME(updateHostAddress(_:address:));
- (void)clearTemporaryAddress:(NSString *)hostID;
- (void)selectHost:(NSString *)hostID;
- (void)cancelPairing;
- (BOOL)forgetHost:(NSString *)hostID;
- (nullable UIViewController *)streamHost:(NSString *)hostID app:(NSString *)appID settings:(NSDictionary *)settings onExit:(void (^)(void))onExit;
- (void)setTouchMode:(BOOL)absolute controller:(UIViewController *)controller NS_SWIFT_NAME(setTouchMode(_:controller:));
- (void)stopController:(UIViewController *)controller NS_SWIFT_NAME(stopController(_:));
- (void)stopController:(UIViewController *)controller completion:(void (^)(void))completion NS_SWIFT_NAME(stopController(_:completion:));
@end
NS_ASSUME_NONNULL_END
