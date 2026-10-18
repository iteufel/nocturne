#import "DisplayBridge.h"
#import <dlfcn.h>

// Private CoreGraphics interfaces are isolated here and resolved at runtime.
// Apple does not offer a public virtual-monitor creation API.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, retain) dispatch_queue_t queue;
@property(nonatomic, retain) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum, serialNumber;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, retain) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static BOOL NDFail(NSError **error, NSString *message, NSInteger code) {
    if (error) *error = [NSError errorWithDomain:@"app.nocturne.display" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
typedef CGError (*NDSetEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static NDSetEnabled NDEnableFunction(void) {
    static NDSetEnabled function; static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (NDSetEnabled)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
        if (!function) {
            void *library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
            if (library) function = (NDSetEnabled)dlsym(library, "SLSConfigureDisplayEnabled");
        }
    });
    return function;
}
static NSArray<NSNumber *> *NDOnline(void) {
    CGDirectDisplayID displays[64]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(64, displays, &count) != kCGErrorSuccess) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (uint32_t i = 0; i < count; i++) [result addObject:@(displays[i])];
    return result;
}
static BOOL NDSameMode(CGDisplayModeRef a, CGDisplayModeRef b) {
    return a && b && CGDisplayModeGetWidth(a) == CGDisplayModeGetWidth(b) && CGDisplayModeGetHeight(a) == CGDisplayModeGetHeight(b) &&
        CGDisplayModeGetPixelWidth(a) == CGDisplayModeGetPixelWidth(b) && CGDisplayModeGetPixelHeight(a) == CGDisplayModeGetPixelHeight(b) &&
        fabs(CGDisplayModeGetRefreshRate(a) - CGDisplayModeGetRefreshRate(b)) < 1;
}
static CFUUIDRef NDDisplayUUID(CGDirectDisplayID display) {
    typedef CFUUIDRef (*CopyUUID)(CGDirectDisplayID);
    CopyUUID copy = (CopyUUID)dlsym(RTLD_DEFAULT, "CGDisplayCreateUUIDFromDisplayID");
    return copy ? copy(display) : NULL;
}
static CGDirectDisplayID NDDisplayForUUID(CFUUIDRef uuid, CGDirectDisplayID fallback) {
    typedef CGDirectDisplayID (*LookupUUID)(CFUUIDRef);
    LookupUUID lookup = (LookupUUID)dlsym(RTLD_DEFAULT, "CGDisplayGetDisplayIDFromUUID");
    return lookup && uuid ? lookup(uuid) : fallback;
}

@implementation NDVirtualDisplay {
    CGVirtualDisplay *_display;
    NSUInteger _width, _height;
}
+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
        NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
}
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(NSUInteger)rate error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (![NDDisplayLayout isSessionAvailable]) { NDFail(error, @"Unlock this Mac before configuring its streaming display.", 12); return nil; }
    if (![NDVirtualDisplay isSupported]) { NDFail(error, @"Virtual displays are unavailable on this version of macOS. Select a connected display in Settings.", 1); return nil; }
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = @"Nocturne Display"; descriptor.queue = dispatch_get_main_queue();
    descriptor.maxPixelsWide = 4096; descriptor.maxPixelsHigh = 4096;
    descriptor.vendorID = 0x4E43;
    // WindowServer caches advertised timings for a display's lifetime and stores
    // preferences by product. A new size gets a fresh display before the old one
    // is released, so a headless Mac always retains an active framebuffer.
    descriptor.productID = (unsigned int)((width * 31 + height * 17 + rate) % 65534) + 1;
    descriptor.serialNum = arc4random_uniform(65534) + 1;
    if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = descriptor.serialNum;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 220, height * 25.4 / 220);
    descriptor.redPrimary = CGPointMake(0.64, 0.33); descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06); descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) { NDFail(error, @"macOS could not create Nocturne Display.", 2); return nil; }
    if (![self resizeToWidth:width height:height refreshRate:rate error:error]) return nil;
    return self;
}
- (CGDirectDisplayID)displayID { return _display.displayID; }
- (BOOL)resizeToWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(NSUInteger)rate error:(NSError **)error {
    if (width < 320 || height < 320 || width > 4096 || height > 4096 || width % 2 || height % 2 ||
        (rate != 30 && rate != 60 && rate != 120)) return NDFail(error, @"Unsupported display dimensions or refresh rate.", 3);
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    settings.modes = @[
        [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:rate],
        [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width / 2 height:height / 2 refreshRate:rate]
    ];
    if (![_display applySettings:settings]) return NDFail(error, @"macOS could not resize Nocturne Display.", 4);
    _width = width; _height = height;
    return YES;
}
- (BOOL)selectRequestedModeWithError:(NSError **)error {
    if (![NDDisplayLayout isSessionAvailable]) return NDFail(error, @"Unlock this Mac before configuring its streaming display.", 12);
    NSUInteger width = _width, height = _height;
    // Select the Retina mode explicitly; never accept a silently scaled desktop.
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(self.displayID,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES}));
    for (id value in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)value;
        if (CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height &&
            CGDisplayModeGetWidth(mode) == width / 2 && CGDisplayModeGetHeight(mode) == height / 2) {
            CGDisplayConfigRef config; CGError result = CGBeginDisplayConfiguration(&config);
            if (result != kCGErrorSuccess) return NDFail(error, @"macOS refused the display configuration.", result);
            result = CGConfigureDisplayWithDisplayMode(config, self.displayID, mode, NULL);
            if (result != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return NDFail(error, @"macOS refused the Retina display mode.", result); }
            result = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
            if (result != kCGErrorSuccess) return NDFail(error, @"macOS could not apply the Retina display mode.", result);
            CGDisplayModeRef actual = CGDisplayCopyDisplayMode(self.displayID);
            BOOL matches = actual && CGDisplayModeGetPixelWidth(actual) == width && CGDisplayModeGetPixelHeight(actual) == height;
            if (actual) CFRelease(actual);
            if (!matches) return NDFail(error, @"Waiting for macOS to finish resizing Nocturne Display.", 10);
            return YES;
        }
    }
    return NDFail(error, @"The requested Retina display mode is unavailable.", 5);
}
@end

@implementation NDDisplayLayout {
    NSArray<NSDictionary *> *_screens;
    NSMutableSet<NSNumber *> *_disabled;
    BOOL _changed;
}
+ (BOOL)isSessionAvailable {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return session && [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue] &&
        [session[(__bridge NSString *)kCGSessionLoginDoneKey] boolValue] && ![session[@"CGSSessionScreenIsLocked"] boolValue];
}
+ (BOOL)canDisableDisplays { return NDEnableFunction() != NULL; }
+ (BOOL)hasActiveDisplayOtherThan:(CGDirectDisplayID)excluded {
    for (NSNumber *number in NDOnline()) {
        CGDirectDisplayID display = number.unsignedIntValue;
        // WindowServer's headless placeholder is not a usable capture monitor.
        if (display != excluded && CGDisplayIsActive(display) == 1 && CGDisplayModelNumber(display) != 0x76697274) return YES;
    }
    return NO;
}
- (instancetype)init { return [self initExcludingDisplay:0]; }
- (instancetype)initExcludingDisplay:(CGDirectDisplayID)excluded {
    if ((self = [super init])) {
        _disabled = [NSMutableSet set];
        NSMutableArray *screens = [NSMutableArray array];
        for (NSNumber *number in NDOnline()) {
            CGDirectDisplayID display = number.unsignedIntValue;
            // A headless startup framebuffer belongs to Nocturne and will be
            // replaced. It must never be treated as a monitor to restore.
            if (display == excluded || CGDisplayModelNumber(display) == 0x76697274) continue;
            if (!CGDisplayIsActive(display) && !CGDisplayIsInMirrorSet(display)) continue;
            CGRect bounds = CGDisplayBounds(display);
            id uuid = CFBridgingRelease(NDDisplayUUID(display));
            id mode = CFBridgingRelease(CGDisplayCopyDisplayMode(display));
            NSMutableDictionary *screen = [@{@"id":number, @"x":@(bounds.origin.x), @"y":@(bounds.origin.y),
                @"mirror":@(CGDisplayMirrorsDisplay(display))} mutableCopy];
            if (uuid) screen[@"uuid"] = uuid;
            if (mode) screen[@"mode"] = mode;
            [screens addObject:screen];
        }
        _screens = screens;
    }
    return self;
}
- (BOOL)makePrimary:(CGDirectDisplayID)display disableOthers:(BOOL)disableOthers error:(NSError **)error {
    if (![NDDisplayLayout isSessionAvailable]) return NDFail(error, @"Unlock this Mac before configuring its streaming display.", 12);
    if (!CGDisplayIsActive(display)) return NDFail(error, @"Nocturne Display is not ready for capture.", 6);
    NDSetEnabled enable = NDEnableFunction();
    if (disableOthers && !enable) return NDFail(error, @"Turning off connected displays is unavailable on this version of macOS.", 7);
    CGDisplayConfigRef config; CGError result = CGBeginDisplayConfiguration(&config);
    if (result != kCGErrorSuccess) return NDFail(error, @"macOS refused the display configuration.", result);
    CGPoint origin = CGDisplayBounds(display).origin;
    for (NSNumber *number in NDOnline()) {
        CGDirectDisplayID current = number.unsignedIntValue;
        if (!CGDisplayIsActive(current) && !CGDisplayIsInMirrorSet(current)) continue;
        CGPoint previous = CGDisplayBounds(current).origin;
        result = CGConfigureDisplayMirrorOfDisplay(config, current, kCGNullDirectDisplay);
        if (result == kCGErrorSuccess) result = CGConfigureDisplayOrigin(config, current, previous.x - origin.x, previous.y - origin.y);
        if (result == kCGErrorSuccess && disableOthers && current != display) {
            [_disabled addObject:number];
            result = enable(config, current, false);
        }
        if (result != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return NDFail(error, @"macOS could not switch to Nocturne Display.", result); }
    }
    _changed = YES;
    result = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    if (result != kCGErrorSuccess) return NDFail(error, @"macOS could not switch the active displays.", result);
    if (CGMainDisplayID() != display) return NDFail(error, @"Nocturne Display did not become the main display.", 8);
    if (disableOthers && [NDDisplayLayout hasActiveDisplayOtherThan:display]) return NDFail(error, @"A connected display could not be turned off. Your original display layout will be restored.", 9);
    return YES;
}
- (BOOL)restoreWithError:(NSError **)error {
    if (!_changed) return YES;
    NDSetEnabled enable = NDEnableFunction();
    // Enabling displays must complete before their saved modes/positions are applied.
    for (NSUInteger pass = 0; pass < 2; pass++) {
        CGDisplayConfigRef config; CGError result = CGBeginDisplayConfiguration(&config);
        if (result != kCGErrorSuccess) return NDFail(error, @"macOS could not begin restoring your displays.", result);
        for (NSDictionary *screen in _screens) {
            CGDirectDisplayID display = NDDisplayForUUID((__bridge CFUUIDRef)screen[@"uuid"], [screen[@"id"] unsignedIntValue]);
            if (!display) display = [screen[@"id"] unsignedIntValue];
            // Disabled displays disappear from the online list. Their saved IDs
            // must be re-enabled before querying modes or resolving their UUIDs.
            BOOL wasDisabled = [_disabled containsObject:screen[@"id"]];
            if (!wasDisabled && !CGDisplayIsOnline(display)) continue;
            if (pass == 0) {
                if (wasDisabled && enable && CGDisplayIsActive(display) != 1) result = enable(config, [screen[@"id"] unsignedIntValue], true);
            } else {
                CGDisplayModeRef original = (__bridge CGDisplayModeRef)screen[@"mode"];
                CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
                BOOL same = NDSameMode(current, original);
                if (current) CFRelease(current);
                if (original && !same) {
                    // Re-enabling a monitor invalidates its old mode objects. Resolve
                    // the original dimensions/rate against its newly published modes.
                    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display,
                        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES}));
                    CGDisplayModeRef restored = NULL;
                    for (id value in modes) if (NDSameMode((__bridge CGDisplayModeRef)value, original)) { restored = (__bridge CGDisplayModeRef)value; break; }
                    if (!restored) { CGCancelDisplayConfiguration(config); return NDFail(error, @"Waiting for your Mac’s display modes to return.", 11); }
                    result = CGConfigureDisplayWithDisplayMode(config, display, restored, NULL);
                }
                CGPoint currentOrigin = CGDisplayBounds(display).origin;
                if (result == kCGErrorSuccess && (currentOrigin.x != [screen[@"x"] intValue] || currentOrigin.y != [screen[@"y"] intValue]))
                    result = CGConfigureDisplayOrigin(config, display, [screen[@"x"] intValue], [screen[@"y"] intValue]);
                CGDirectDisplayID mirror = [screen[@"mirror"] unsignedIntValue];
                if (result == kCGErrorSuccess && CGDisplayMirrorsDisplay(display) != mirror && (!mirror || CGDisplayIsOnline(mirror)))
                    result = CGConfigureDisplayMirrorOfDisplay(config, display, mirror);
            }
            if (result != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return NDFail(error, @"A display could not be restored. Use Restore displays to try again.", result); }
        }
        result = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
        if (result != kCGErrorSuccess) return NDFail(error, @"macOS could not finish restoring your display layout.", result);
    }
    [_disabled removeAllObjects];
    _changed = NO;
    return YES;
}
@end
