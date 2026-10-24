// Exercise the generated Moonlight Connection operation with the C transport
// replaced by counters. No iOS UI, sockets, renderer or global decoder is used.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
static NSLock *initLock;
static atomic_uint starts, stops, interrupts;
static void LiInterruptConnection(void) { atomic_fetch_add(&interrupts, 1); }
static void LiStopConnection(void) { atomic_fetch_add(&stops, 1); }
static void LiStartConnection(void *a, void *b, void *c, void *d, void *e,
                              void *f, int g, void *h, int i) { atomic_fetch_add(&starts, 1); }
@interface Connection : NSOperation {
    int _serverInfo, _streamConfig, _clCallbacks, _drCallbacks, _arCallbacks;
}
- (void)nocturneTerminateWithCompletion:(void (^)(void))completion;
@end
@implementation Connection
#include "connection-main.inc"
#include "connection-stop.inc"
@end
static void awaitCompletion(Connection *connection) {
    __block BOOL finished = NO;
    [connection nocturneTerminateWithCompletion:^{ finished = YES; }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!finished && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(finished);
}
int main(void) { @autoreleasepool {
    initLock = [NSLock new];
    for (unsigned attempt = 0; attempt < 32; ++attempt) {
        NSOperationQueue *queue = [NSOperationQueue new]; queue.suspended = YES;
        Connection *connection = [Connection new]; [queue addOperation:connection];
        awaitCompletion(connection);
        assert(connection.cancelled);
        queue.suspended = NO; [queue waitUntilAllOperationsAreFinished];
        assert(atomic_load(&starts) == 0);
        [connection release]; [queue release];

        // The operation may already be executing but still wait for the global
        // connection lock. It must check cancellation after acquiring the lock.
        [initLock lock];
        queue = [NSOperationQueue new]; connection = [Connection new];
        [queue addOperation:connection];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!connection.executing && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.001];
        assert(connection.executing);
        [connection cancel];
        [initLock unlock];
        [queue waitUntilAllOperationsAreFinished];
        assert(atomic_load(&starts) == 0);
        [connection release]; [queue release];
    }
    assert(atomic_load(&stops) == 32 && atomic_load(&interrupts) == 32);
    [initLock release];
    puts("PASS: a stopped queued or lock-blocked connection cannot start later");
    return 0;
} }
