#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Explicit pairing approval, bound to both identities and kept outside discovery's database.
@interface NocturnePairingTrust : NSObject
- (instancetype)initWithService:(NSString *)service;
- (BOOL)isApprovedHost:(NSString *)hostID serverCertificate:(nullable NSData *)serverCertificate clientCertificate:(nullable NSData *)clientCertificate;
- (BOOL)approveHost:(NSString *)hostID serverCertificate:(NSData *)serverCertificate clientCertificate:(NSData *)clientCertificate error:(NSError **)error;
- (BOOL)forgetHost:(NSString *)hostID error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
