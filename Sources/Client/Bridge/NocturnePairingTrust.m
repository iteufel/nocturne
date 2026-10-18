#import "NocturnePairingTrust.h"
#import <Security/Security.h>

@implementation NocturnePairingTrust {
    NSString *_service;
}
- (instancetype)initWithService:(NSString *)service {
    if ((self = [super init])) _service = [service copy];
    return self;
}
- (NSDictionary *)queryForHost:(NSString *)hostID {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:_service, (__bridge id)kSecAttrAccount:hostID};
}
- (BOOL)isApprovedHost:(NSString *)hostID serverCertificate:(NSData *)serverCertificate clientCertificate:(NSData *)clientCertificate {
    if (!hostID.length || !serverCertificate.length || !clientCertificate.length) return NO;
    NSMutableDictionary *query = [[self queryForHost:hostID] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    NSData *data = CFBridgingRelease(result);
    if (status != errSecSuccess || ![data isKindOfClass:NSData.class]) return NO;
    id record = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    return [record isKindOfClass:NSDictionary.class] && [record[@"server"] isEqual:serverCertificate] && [record[@"client"] isEqual:clientCertificate];
}
- (BOOL)approveHost:(NSString *)hostID serverCertificate:(NSData *)serverCertificate clientCertificate:(NSData *)clientCertificate error:(NSError **)error {
    if (!hostID.length || !serverCertificate.length || !clientCertificate.length) return [self fail:errSecParam error:error];
    NSData *record = [NSPropertyListSerialization dataWithPropertyList:@{@"server":serverCertificate,@"client":clientCertificate}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!record) return NO;
    NSDictionary *query = [self queryForHost:hostID];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:record});
    if (status == errSecItemNotFound) {
        NSMutableDictionary *attributes = [query mutableCopy];
        attributes[(__bridge id)kSecValueData] = record;
        attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    }
    return status == errSecSuccess || [self fail:status error:error];
}
- (BOOL)forgetHost:(NSString *)hostID error:(NSError **)error {
    if (!hostID.length) return [self fail:errSecParam error:error];
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self queryForHost:hostID]);
    return status == errSecSuccess || status == errSecItemNotFound || [self fail:status error:error];
}
- (BOOL)fail:(OSStatus)status error:(NSError **)error {
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:@{
        NSLocalizedDescriptionKey:@"Nocturne could not update its secure pairing approval. Unlock this device and try again."
    }];
    return NO;
}
@end
