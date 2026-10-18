#import "StreamManager.h"

@interface Connection (NocturneStop)
- (void)nocturneTerminateWithCompletion:(void (^)(void))completion;
@end
@interface StreamManager (NocturneStop)
- (void)nocturneStopWithCompletion:(void (^)(void))completion;
@end
