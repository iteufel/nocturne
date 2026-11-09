#import "SimulatorBridge.h"
#import <dlfcn.h>
#import <xpc/xpc.h>
#import <stdatomic.h>
#import <math.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>

// DTUHID/CoreDevice wire contracts and simulator XPC construction are adapted
// from Meta idb (MIT), revision 291575b7dbcf85525a7900b8f752f1c8175fa1ae.
// See THIRD_PARTY_NOTICES.md. No private framework is linked into the iOS app.
@interface NSObject (NCSimulatorPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)directory error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (NSUInteger)state;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (id)screenProperties;
- (NSString *)uniqueId;
- (id)framebufferSurface;
- (void)enumerateScreensWithCompletionQueue:(dispatch_queue_t)queue completionHandler:(void (^)(NSArray *))handler;
- (mach_port_t)lookup:(NSString *)service error:(NSError **)error;
@end

static NSString *const NCDigitizer = @"com.apple.coredevice.feature.remote.hid.digitizer";
static NSString *const NCDisplay = @"com.apple.coredevice.feature.getdisplayinfo";
static NSString *const NCTouchscreens = @"com.apple.coredevice.feature.remote.universalhidservice";
static BOOL NCFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"app.nocturne.simulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

// NSNumber canonicalizes small unsigned values as signed ints. Preserve the wire
// distinction explicitly: dtuhidd rejects a signed eventType/state/target.
@interface NCUnsigned : NSObject
@property(nonatomic) uint64_t value;
@end
@implementation NCUnsigned
@end
static NCUnsigned *NCUInt(uint64_t value) { NCUnsigned *number = [NCUnsigned new]; number.value = value; return number; }

static xpc_object_t NCEncode(id value) {
    if ([value isKindOfClass:NCUnsigned.class]) return xpc_uint64_create(((NCUnsigned *)value).value);
    if ([value isKindOfClass:NSString.class]) return xpc_string_create([value UTF8String]);
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return xpc_bool_create([value boolValue]);
        const char *type = [value objCType];
        if (strchr("fd", type[0])) return xpc_double_create([value doubleValue]);
        if (strchr("QILSC", type[0])) return xpc_uint64_create([value unsignedLongLongValue]);
        return xpc_int64_create([value longLongValue]);
    }
    if ([value isKindOfClass:NSArray.class]) {
        xpc_object_t array = xpc_array_create(NULL, 0);
        for (id item in value) xpc_array_append_value(array, NCEncode(item));
        return array;
    }
    xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
    for (NSString *key in value) xpc_dictionary_set_value(dictionary, key.UTF8String, NCEncode(value[key]));
    return dictionary;
}
static id NCDecode(xpc_object_t value, NSUInteger depth) {
    if (!value || depth > 12) return nil;
    xpc_type_t type = xpc_get_type(value);
    if (type == XPC_TYPE_STRING) {
        if (xpc_string_get_length(value) > 4096) return nil;
        return [NSString stringWithUTF8String:xpc_string_get_string_ptr(value)];
    }
    if (type == XPC_TYPE_BOOL) return @(xpc_bool_get_value(value));
    if (type == XPC_TYPE_UINT64) return @(xpc_uint64_get_value(value));
    if (type == XPC_TYPE_INT64) return @(xpc_int64_get_value(value));
    if (type == XPC_TYPE_DOUBLE) return @(xpc_double_get_value(value));
    if (type == XPC_TYPE_ARRAY) {
        if (xpc_array_get_count(value) > 256) return nil;
        NSMutableArray *array = [NSMutableArray array];
        for (NSUInteger i = 0; i < xpc_array_get_count(value); i++) {
            id item = NCDecode(xpc_array_get_value(value, i), depth + 1);
            if (!item) return nil;
            [array addObject:item];
        }
        return array;
    }
    if (type == XPC_TYPE_DICTIONARY) {
        if (xpc_dictionary_get_count(value) > 256) return nil;
        NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
        __block BOOL valid = YES;
        xpc_dictionary_apply(value, ^bool(const char *key, xpc_object_t item) {
            id decoded = NCDecode(item, depth + 1);
            if (!decoded || strlen(key) > 1024) { valid = NO; return false; }
            dictionary[@(key)] = decoded;
            return true;
        });
        return valid ? dictionary : nil;
    }
    return nil;
}

@implementation NCSimulatorBridge {
    id _device;
    NSString *_deviceID;
    NSMutableDictionary<NSString *, id> *_channels;
    dispatch_queue_t _replies;
    atomic_bool _invalid;
    BOOL _touching;
    NSDictionary *_lastTouch;
}
- (instancetype)initWithDevice:(NSString *)device developerDirectory:(NSString *)directory error:(NSError **)error {
    if (!(self = [super init])) return nil;
    atomic_init(&_invalid, false);
    _channels = [NSMutableDictionary dictionary];
    _replies = dispatch_queue_create("app.nocturne.simulator.replies", DISPATCH_QUEUE_SERIAL);
    if (![[NSUUID alloc] initWithUUIDString:device] || ![directory hasSuffix:@"/Contents/Developer"] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:directory]) {
        NCFail(error, @"Select a full Xcode installation and a running iOS simulator."); return nil;
    }
    static void *framework; static dispatch_once_t once;
    dispatch_once(&once, ^{ framework = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_LOCAL); });
    Class contextClass = NSClassFromString(@"SimServiceContext");
    NSString *version = [NSBundle bundleForClass:NSClassFromString(@"SimDevice") ?: NSObject.class].infoDictionary[@"CFBundleVersion"];
    if (!framework || ![contextClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)] ||
        !version || [version compare:@"1155.4" options:NSNumericSearch] == NSOrderedAscending) {
        NCFail(error, @"Simulator touch requires Xcode 27 or newer."); return nil;
    }
    @try {
        id context = [contextClass sharedServiceContextForDeveloperDir:directory error:NULL];
        id set = [context defaultDeviceSetWithError:NULL];
        for (id candidate in [set availableDevices]) {
            if ([[candidate UDID].UUIDString caseInsensitiveCompare:device] == NSOrderedSame) { _device = candidate; break; }
        }
        if (!_device || [_device state] != 3 || ![_device respondsToSelector:@selector(lookup:error:)]) {
            NCFail(error, @"Start the selected iOS simulator in Xcode first."); return nil;
        }
        _deviceID = device;
        NSDictionary *probe = @{@"messageType":@"IndigoKeyboardButtonEvent", @"isBarrier":@YES,
            @"featureIdentifier":NCDigitizer, @"payload":@{@"usageCode":NCUInt(0), @"state":NCUInt(2)}};
        if (![self request:probe service:NCDigitizer error:error]) return nil;
        // The liveness reply precedes device-open on a cold dtuhidd connection.
        [NSThread sleepForTimeInterval:0.2];
    } @catch (NSException *exception) {
        NCFail(error, @"This Xcode version does not provide compatible simulator touch services."); return nil;
    }
    return self;
}
- (xpc_connection_t)channel:(NSString *)service error:(NSError **)error {
    if (atomic_load(&_invalid) || [_device state] != 3) { NCFail(error, @"Simulator input connection ended. Reopen the simulator stream."); return nil; }
    xpc_connection_t existing = _channels[service];
    if (existing) return existing;
    typedef xpc_endpoint_t (*Endpoint)(mach_port_t, uint64_t, uint64_t);
    typedef void (*Enable)(xpc_connection_t);
    Endpoint endpointFromPort = (Endpoint)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    Enable enable = (Enable)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!endpointFromPort || !enable) { NCFail(error, @"Simulator input is unavailable with this macOS version."); return nil; }
    mach_port_t port = [_device lookup:service error:NULL];
    if (port == MACH_PORT_NULL) { NCFail(error, @"The selected runtime does not provide simulator touch services."); return nil; }
    xpc_endpoint_t endpoint = endpointFromPort(port, 0, 0);
    if (!endpoint) { mach_port_deallocate(mach_task_self(), port); NCFail(error, @"Could not connect to simulator input."); return nil; }
    xpc_connection_t channel = xpc_connection_create_from_endpoint(endpoint);
    if (!channel) { NCFail(error, @"Could not connect to simulator input."); return nil; }
    enable(channel);
    xpc_connection_set_target_queue(channel, _replies);
    __weak NCSimulatorBridge *weakSelf = self;
    xpc_connection_set_event_handler(channel, ^(xpc_object_t event) {
        NCSimulatorBridge *owner = weakSelf;
        if (owner && xpc_get_type(event) == XPC_TYPE_ERROR) atomic_store(&owner->_invalid, true);
    });
    xpc_connection_resume(channel);
    _channels[service] = channel;
    return channel;
}
- (NSDictionary *)request:(NSDictionary *)payload service:(NSString *)service error:(NSError **)error {
    xpc_connection_t channel = [self channel:service error:error];
    if (!channel) return nil;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block xpc_object_t response;
    xpc_connection_send_message_with_reply(channel, NCEncode(payload), _replies, ^(xpc_object_t reply) {
        response = reply; dispatch_semaphore_signal(ready);
    });
    if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC))) {
        atomic_store(&_invalid, true); NCFail(error, @"Simulator input service did not respond. Reopen the stream after the simulator finishes starting."); return nil;
    }
    id result = NCDecode(response, 0);
    if (![result isKindOfClass:NSDictionary.class]) { NCFail(error, @"Simulator returned an unsupported input-service response."); return nil; }
    return result;
}
- (NSDictionary *)displayInfoWithError:(NSError **)error {
    NSString *version = [NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"].infoDictionary[@"CFBundleVersion"];
    NSMutableArray *components = [NSMutableArray array];
    for (NSString *part in [version componentsSeparatedByString:@"."]) {
        if (!part.length || [part rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
            NCFail(error, @"Unsupported CoreDevice version."); return nil;
        }
        [components addObject:NCUInt(part.longLongValue)];
    }
    if (!components.count) { NCFail(error, @"CoreDevice metadata is unavailable."); return nil; }
    NSDictionary *reply = [self request:@{@"CoreDevice.actionIdentifier":@"com.apple.coredevice.action.displayinfo",
        @"CoreDevice.deviceIdentifier":_deviceID, @"CoreDevice.invocationIdentifier":NSUUID.UUID.UUIDString,
        @"CoreDevice.CoreDeviceDDIProtocolVersion":@((int64_t)1),
        @"CoreDevice.coreDeviceVersion":@{@"components":components, @"originalComponentsCount":@((int64_t)components.count), @"stringValue":version},
        @"CoreDevice.input":@{}} service:NCDisplay error:error];
    if (!reply) return nil;
    id output = reply[@"CoreDevice.output"];
    if (reply[@"CoreDevice.error"] || ![output isKindOfClass:NSDictionary.class]) { NCFail(error, @"Simulator display geometry is unavailable."); return nil; }
    return output;
}
- (NSData *)framebufferPNGForDisplay:(NSString *)display rotation:(NSUInteger)rotation error:(NSError **)error {
    if (rotation > 3 || atomic_load(&_invalid)) { NCFail(error, @"Simulator display is unavailable."); return nil; }
    @try {
        NSMutableArray *matches = [NSMutableArray array];
        for (id port in [[_device io] ioPorts]) {
            id descriptor = [port descriptor];
            if (![descriptor respondsToSelector:@selector(enumerateScreensWithCompletionQueue:completionHandler:)]) continue;
            dispatch_semaphore_t ready = dispatch_semaphore_create(0);
            __block NSArray *screens;
            [descriptor enumerateScreensWithCompletionQueue:_replies completionHandler:^(NSArray *value) { screens = value; dispatch_semaphore_signal(ready); }];
            if (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC))) { NCFail(error, @"Simulator display enumeration timed out."); return nil; }
            for (id screen in screens) {
                if ([[[screen screenProperties] uniqueId] isEqualToString:display]) [matches addObject:screen];
            }
        }
        if (matches.count != 1) { NCFail(error, @"The simulator display has no unique framebuffer."); return nil; }
        id surface = [matches.firstObject framebufferSurface];
        if (!surface || CFGetTypeID((__bridge CFTypeRef)surface) != IOSurfaceGetTypeID()) { NCFail(error, @"Wait for the simulator display to finish starting."); return nil; }
        IOSurfaceRef buffer = (__bridge IOSurfaceRef)surface;
        size_t width = IOSurfaceGetWidth(buffer), height = IOSurfaceGetHeight(buffer);
        if (!width || !height || width > 8192 || height > 8192 || width * height > 33554432) { NCFail(error, @"Unsupported simulator framebuffer size."); return nil; }
        // Capture precisely this panel, then apply its reported interface rotation.
        // Touches use the inverse of this transform, never the Mac window's size.
        uint32_t seed = 0;
        if (IOSurfaceLock(buffer, kIOSurfaceLockReadOnly, &seed) != kIOReturnSuccess) { NCFail(error, @"Simulator framebuffer is busy."); return nil; }
        CIImage *image = [CIImage imageWithIOSurface:buffer];
        int orientations[] = {1, 6, 3, 8};
        image = [image imageByApplyingOrientation:orientations[rotation]];
        CGImageRef rendered = [[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}] createCGImage:image fromRect:image.extent];
        IOSurfaceUnlock(buffer, kIOSurfaceLockReadOnly, &seed);
        if (!rendered) { NCFail(error, @"Could not read the simulator framebuffer."); return nil; }
        NSMutableData *data = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
        if (destination) CGImageDestinationAddImage(destination, rendered, NULL);
        BOOL written = destination && CGImageDestinationFinalize(destination);
        if (destination) CFRelease(destination);
        CGImageRelease(rendered);
        if (!written || data.length > 33554432) { NCFail(error, @"Could not encode the simulator framebuffer."); return nil; }
        return data;
    } @catch (NSException *exception) {
        NCFail(error, @"This Xcode version does not provide compatible simulator display services."); return nil;
    }
}
- (NSDictionary *)touchscreensWithError:(NSError **)error {
    return [self request:@{@"isBarrier":@NO, @"payload":@{@"connectedServices":@{}}} service:NCTouchscreens error:error];
}
- (BOOL)sendTouchPhase:(NSUInteger)phase x:(double)x y:(double)y target:(NSUInteger)target edge:(NSUInteger)edge error:(NSError **)error {
    if (phase > 2 || !isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1 || target > 255 || edge > 4 ||
        (phase == 0 ? _touching : !_touching)) return NCFail(error, @"Invalid simulator touch sequence.");
    xpc_connection_t channel = [self channel:NCDigitizer error:error];
    if (!channel) return NO;
    NSDictionary *payload = @{@"pointOne":@{@"x":@(x), @"y":@(y)}, @"eventType":NCUInt(phase), @"edge":NCUInt(edge), @"target":NCUInt(target)};
    xpc_connection_send_message(channel, NCEncode(@{@"messageType":@"IndigoDigitizerEvent", @"isBarrier":@NO, @"featureIdentifier":NCDigitizer, @"payload":payload}));
    _touching = phase != 2; _lastTouch = payload;
    return YES;
}
- (void)cancelTouch {
    if (!_touching) return;
    xpc_connection_t channel = _channels[NCDigitizer];
    if (channel) {
        NSMutableDictionary *payload = [_lastTouch mutableCopy]; payload[@"eventType"] = NCUInt(2);
        xpc_connection_send_message(channel, NCEncode(@{@"messageType":@"IndigoDigitizerEvent", @"isBarrier":@NO, @"featureIdentifier":NCDigitizer, @"payload":payload}));
        [NSThread sleepForTimeInterval:0.08];
    }
    _touching = NO; _lastTouch = nil;
}
- (void)close {
    [self cancelTouch];
    // Even an already ended contact may still have its final event queued.
    if (_channels[NCDigitizer]) [NSThread sleepForTimeInterval:0.08];
    for (xpc_connection_t channel in _channels.allValues) xpc_connection_cancel(channel);
    [_channels removeAllObjects]; atomic_store(&_invalid, true);
}
- (void)dealloc { [self close]; }
@end
