//
//  PrivateDisplayAPIs.h
//  HiDPI Display Manager
//
//  Objective-C bridging header exposing private WindowServer display APIs to Swift:
//
//   1. CGS display-mode functions (SkyLight / CoreGraphics). These enumerate and apply
//      every mode WindowServer knows about, including scaled HiDPI modes that are hidden
//      from the public CGDisplayCopyAllDisplayModes() list.
//      They are resolved dynamically at runtime (dlopen/dlsym) so the app links cleanly
//      against any SDK and degrades gracefully if Apple removes a symbol.
//
//   2. CGVirtualDisplay Objective-C classes (private, shipped inside CoreGraphics since
//      macOS 11). Used to spawn a virtual 5K HiDPI canvas that a physical 4K panel can
//      mirror, forcing crisp 2560x1440 @2x rendering.
//
//  This header is passed to swiftc via `-import-objc-header` (CLI) or set as
//  SWIFT_OBJC_BRIDGING_HEADER (Xcode).
//

#ifndef PrivateDisplayAPIs_h
#define PrivateDisplayAPIs_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CGS Display Mode Description

/// Layout of the mode description record filled in by
/// CGSGetDisplayModeDescriptionOfLength(). Reverse-engineered layout used by
/// RDM / displayplacer; stable from macOS 10.8 through current releases.
typedef struct {
    uint32_t modeNumber;     /* 0x00  IOKit display mode ID                       */
    uint32_t flags;          /* 0x04  IODisplayModeFlags (interlaced, native ...)  */
    uint32_t width;          /* 0x08  Logical width in points                      */
    uint32_t height;         /* 0x0C  Logical height in points                     */
    uint32_t depth;          /* 0x10  Bits per pixel / depth code                  */
    uint32_t reserved0[42];  /* 0x14  Opaque                                       */
    uint16_t reserved1;      /* 0xBC  Opaque                                       */
    uint16_t refreshRate;    /* 0xBE  Refresh rate in Hz (0 = default/unknown)     */
    uint32_t reserved2[4];   /* 0xC0  Opaque                                       */
    float    density;        /* 0xD0  Backing scale factor (2.0 == HiDPI)          */
    uint8_t  tailPadding[8]; /* 0xD4  Safety padding; never written by WindowServer */
} CGSDisplayModeDescription;

/// Number of bytes WindowServer is asked to write into a CGSDisplayModeDescription.
#define HDM_CGS_MODE_DESCRIPTION_LENGTH 0xD4

_Static_assert(offsetof(CGSDisplayModeDescription, refreshRate) == 0xBE, "CGS refreshRate offset mismatch");
_Static_assert(offsetof(CGSDisplayModeDescription, density) == 0xD0, "CGS density offset mismatch");
_Static_assert(sizeof(CGSDisplayModeDescription) == 0xDC, "CGSDisplayModeDescription size mismatch");

#pragma mark - CGS Canonical Prototypes (private, exported by SkyLight)

typedef int32_t CGSConnectionID;

/// Canonical prototypes, declared weak so that merely including this header never
/// creates a hard link-time dependency. Swift code should call the HDM* wrappers
/// below, which resolve the symbols dynamically.
extern CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern void CGSGetCurrentDisplayMode(CGDirectDisplayID display, int32_t *modeNumber) __attribute__((weak_import));
extern void CGSGetNumberOfDisplayModes(CGDirectDisplayID display, int32_t *modeCount) __attribute__((weak_import));
extern void CGSGetDisplayModeDescriptionOfLength(CGDirectDisplayID display,
                                                 int32_t modeIndex,
                                                 CGSDisplayModeDescription *description,
                                                 int32_t length) __attribute__((weak_import));
extern void CGSConfigureDisplayMode(CGDisplayConfigRef config,
                                    CGDirectDisplayID display,
                                    int32_t modeIndex) __attribute__((weak_import));

#pragma mark - Dynamic Resolution (SkyLight / CoreDisplay)

typedef CGSConnectionID (*HDMCGSMainConnectionIDFn)(void);
typedef void (*HDMCGSGetCurrentDisplayModeFn)(CGDirectDisplayID, int32_t *);
typedef void (*HDMCGSGetNumberOfDisplayModesFn)(CGDirectDisplayID, int32_t *);
typedef void (*HDMCGSGetDisplayModeDescriptionOfLengthFn)(CGDirectDisplayID, int32_t, CGSDisplayModeDescription *, int32_t);
typedef void (*HDMCGSConfigureDisplayModeFn)(CGDisplayConfigRef, CGDirectDisplayID, int32_t);

/// Looks a symbol up in SkyLight first, then CoreDisplay, then the global namespace
/// (CoreGraphics re-exports many CGS symbols). Frameworks are opened exactly once.
static inline void * _Nullable HDMResolvePrivateSymbol(const char *symbolName) {
    static void *skyLightHandle = NULL;
    static void *coreDisplayHandle = NULL;
    static bool didOpenFrameworks = false;

    if (!didOpenFrameworks) {
        didOpenFrameworks = true;
        skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
        coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
    }

    void *symbol = NULL;
    if (skyLightHandle != NULL) {
        symbol = dlsym(skyLightHandle, symbolName);
    }
    if (symbol == NULL && coreDisplayHandle != NULL) {
        symbol = dlsym(coreDisplayHandle, symbolName);
    }
    if (symbol == NULL) {
        symbol = dlsym(RTLD_DEFAULT, symbolName);
    }
    return symbol;
}

static inline HDMCGSMainConnectionIDFn _Nullable HDMLoadCGSMainConnectionID(void) {
    static HDMCGSMainConnectionIDFn function = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        function = (HDMCGSMainConnectionIDFn)HDMResolvePrivateSymbol("CGSMainConnectionID");
    }
    return function;
}

static inline HDMCGSGetCurrentDisplayModeFn _Nullable HDMLoadCGSGetCurrentDisplayMode(void) {
    static HDMCGSGetCurrentDisplayModeFn function = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        function = (HDMCGSGetCurrentDisplayModeFn)HDMResolvePrivateSymbol("CGSGetCurrentDisplayMode");
    }
    return function;
}

static inline HDMCGSGetNumberOfDisplayModesFn _Nullable HDMLoadCGSGetNumberOfDisplayModes(void) {
    static HDMCGSGetNumberOfDisplayModesFn function = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        function = (HDMCGSGetNumberOfDisplayModesFn)HDMResolvePrivateSymbol("CGSGetNumberOfDisplayModes");
    }
    return function;
}

static inline HDMCGSGetDisplayModeDescriptionOfLengthFn _Nullable HDMLoadCGSGetDisplayModeDescriptionOfLength(void) {
    static HDMCGSGetDisplayModeDescriptionOfLengthFn function = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        function = (HDMCGSGetDisplayModeDescriptionOfLengthFn)HDMResolvePrivateSymbol("CGSGetDisplayModeDescriptionOfLength");
    }
    return function;
}

static inline HDMCGSConfigureDisplayModeFn _Nullable HDMLoadCGSConfigureDisplayMode(void) {
    static HDMCGSConfigureDisplayModeFn function = NULL;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        function = (HDMCGSConfigureDisplayModeFn)HDMResolvePrivateSymbol("CGSConfigureDisplayMode");
    }
    return function;
}

#pragma mark - Swift-Facing Safe Wrappers

/// True when every CGS function required for hidden-mode enumeration and switching resolved.
static inline bool HDMPrivateCGSAvailable(void) {
    return HDMLoadCGSGetNumberOfDisplayModes() != NULL
        && HDMLoadCGSGetDisplayModeDescriptionOfLength() != NULL
        && HDMLoadCGSConfigureDisplayMode() != NULL
        && HDMLoadCGSGetCurrentDisplayMode() != NULL;
}

/// Returns the main WindowServer connection, or 0 when unavailable.
static inline CGSConnectionID HDMCGSMainConnection(void) {
    HDMCGSMainConnectionIDFn function = HDMLoadCGSMainConnectionID();
    return function != NULL ? function() : 0;
}

/// Writes the number of CGS modes for `display` into `outCount`. Returns false if unavailable.
static inline bool HDMCGSGetNumberOfDisplayModes(CGDirectDisplayID display, int32_t *outCount) {
    HDMCGSGetNumberOfDisplayModesFn function = HDMLoadCGSGetNumberOfDisplayModes();
    *outCount = 0;
    if (function == NULL) {
        return false;
    }
    function(display, outCount);
    return true;
}

/// Fills `outDescription` for the CGS mode at `modeIndex`. Returns false if unavailable.
static inline bool HDMCGSGetDisplayModeDescription(CGDirectDisplayID display,
                                                   int32_t modeIndex,
                                                   CGSDisplayModeDescription *outDescription) {
    HDMCGSGetDisplayModeDescriptionOfLengthFn function = HDMLoadCGSGetDisplayModeDescriptionOfLength();
    memset(outDescription, 0, sizeof(CGSDisplayModeDescription));
    if (function == NULL) {
        return false;
    }
    function(display, modeIndex, outDescription, (int32_t)HDM_CGS_MODE_DESCRIPTION_LENGTH);
    return true;
}

/// Writes the active CGS mode index for `display` into `outModeIndex`. Returns false if unavailable.
static inline bool HDMCGSGetCurrentDisplayMode(CGDirectDisplayID display, int32_t *outModeIndex) {
    HDMCGSGetCurrentDisplayModeFn function = HDMLoadCGSGetCurrentDisplayMode();
    *outModeIndex = -1;
    if (function == NULL) {
        return false;
    }
    function(display, outModeIndex);
    return true;
}

/// Queues a CGS mode change inside an open CGBeginDisplayConfiguration transaction.
static inline bool HDMCGSConfigureDisplayMode(CGDisplayConfigRef config,
                                              CGDirectDisplayID display,
                                              int32_t modeIndex) {
    HDMCGSConfigureDisplayModeFn function = HDMLoadCGSConfigureDisplayMode();
    if (function == NULL) {
        return false;
    }
    function(config, display, modeIndex);
    return true;
}

#pragma mark - CGVirtualDisplay (private CoreGraphics classes, macOS 11+)

@class CGVirtualDisplay;

/// A single mode advertised by a virtual display (expressed in pixels).
@interface CGVirtualDisplayMode : NSObject

@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;

- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;

@end

/// Settings applied to a live virtual display.
@interface CGVirtualDisplaySettings : NSObject

@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
/// 1 = expose HiDPI (@2x) variants of the advertised modes, 0 = 1x only.
@property (nonatomic) unsigned int hiDPI;

- (instancetype)init;

@end

/// Hardware-identity description used to instantiate a virtual display.
@interface CGVirtualDisplayDescriptor : NSObject

@property (retain, nonatomic, nullable) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id display, CGVirtualDisplay *virtualDisplay);

- (instancetype)init;
- (nullable dispatch_queue_t)dispatchQueue;
- (void)setDispatchQueue:(dispatch_queue_t)queue;

@end

/// A live virtual display. The display exists for exactly as long as this object is retained.
@interface CGVirtualDisplay : NSObject

@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic, nullable) id terminationHandler;
@property (readonly, nonatomic, nullable) dispatch_queue_t queue;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int vendorID;
@property (readonly, nonatomic) CGPoint whitePoint;
@property (readonly, nonatomic) CGPoint redPrimary;
@property (readonly, nonatomic) CGPoint greenPrimary;
@property (readonly, nonatomic) CGPoint bluePrimary;

- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings NS_SWIFT_NAME(apply(_:));

@end

NS_ASSUME_NONNULL_END

#endif /* PrivateDisplayAPIs_h */
