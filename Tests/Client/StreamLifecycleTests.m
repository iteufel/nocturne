#import <XCTest/XCTest.h>
#import "NocturneStreamLifecycle.h"

@interface StreamLifecycleTests : XCTestCase
@end

@implementation StreamLifecycleTests
- (void)testCancelledQueuedLaunchCompletesBeforeAnotherStreamStarts {
    XCTestExpectation *finished = [self expectationWithDescription:@"Cancelled launch drained"];
    StreamManager *manager = [[StreamManager alloc] initWithConfig:[StreamConfiguration new] renderView:[UIView new] connectionCallbacks:nil];
    NSOperationQueue *queue = [NSOperationQueue new]; queue.suspended = YES;
    [queue addOperation:manager];
    [manager nocturneStopWithCompletion:^{
        XCTAssertTrue(manager.finished);
        XCTAssertTrue(manager.cancelled);
        XCTAssertTrue(NSThread.isMainThread);
        [finished fulfill];
    }];
    queue.suspended = NO;
    [self waitForExpectations:@[finished] timeout:5];
}
- (void)testRepeatedStopAndLateCompletionAreIdempotent {
    XCTestExpectation *finished = [self expectationWithDescription:@"All stop callers completed"];
    finished.expectedFulfillmentCount = 3;
    StreamManager *manager = [[StreamManager alloc] initWithConfig:[StreamConfiguration new] renderView:[UIView new] connectionCallbacks:nil];
    NSOperationQueue *queue = [NSOperationQueue new]; queue.suspended = YES;
    [queue addOperation:manager];
    [manager nocturneStopWithCompletion:^{
        [finished fulfill];
        [manager nocturneStopWithCompletion:^{ [finished fulfill]; }];
    }];
    [manager nocturneStopWithCompletion:^{ [finished fulfill]; }];
    queue.suspended = NO;
    [self waitForExpectations:@[finished] timeout:5];
}
@end
