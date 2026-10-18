#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface NocturneStreamingService : NSObject
@property (nonatomic, copy, nullable) void (^hostsChanged)(NSArray<NSDictionary *> *hosts);
@property (nonatomic, copy, nullable) void (^appsChanged)(NSString *hostID, NSArray<NSDictionary *> *apps);
@property (nonatomic, copy, nullable) void (^addressDiscovered)(NSString *hostID, NSString *address);
@property (nonatomic, copy, nullable) void (^pairingPIN)(NSString *pin);
@property (nonatomic, copy, nullable) void (^pairingFinished)(void);
@property (nonatomic, copy, nullable) void (^failed)(NSString *message);
- (NSData *)workspaceCertificate;
- (NSData *)signWorkspaceChallenge:(NSData *)challenge;
- (void)start;
- (void)pause;
- (void)addAddress:(NSString *)address;
- (void)selectHost:(NSString *)hostID;
- (BOOL)forgetHost:(NSString *)hostID;
- (nullable UIViewController *)streamHost:(NSString *)hostID app:(NSString *)appID settings:(NSDictionary *)settings onExit:(void (^)(void))onExit;
- (void)setTouchMode:(BOOL)absolute controller:(UIViewController *)controller NS_SWIFT_NAME(setTouchMode(_:controller:));
- (void)stopController:(UIViewController *)controller NS_SWIFT_NAME(stopController(_:));
- (void)stopController:(UIViewController *)controller completion:(void (^)(void))completion NS_SWIFT_NAME(stopController(_:completion:));
@end
NS_ASSUME_NONNULL_END
