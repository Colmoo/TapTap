/*
 * tap_accel.c — IOKit HID accelerometer reader for Apple Silicon MacBooks.
 *
 * Precision improvements matching olvvier/apple-silicon-accelerometer:
 *
 *  1. Driver wake — before registering callbacks, we set three IORegistry
 *     properties on the AppleSPUHIDDriver service that owns the device:
 *       SensorPropertyReportingState = 1  (enable continuous output)
 *       SensorPropertyPowerState     = 1  (keep sensor powered)
 *       ReportInterval               = 1000 (µs → 1 kHz)
 *     Without this the device goes silent at rest and polling reads stale data.
 *
 *  2. Event-driven callbacks — IOHIDDeviceRegisterInputReportWithTimeStampCallback
 *     delivers each pushed report with a mach_absolute_time timestamp the moment
 *     it arrives, replacing the coarse 5 ms poll timer as the primary data path.
 *
 *  3. Fallback poll timer — kept at 5 ms so tap detection still works on machines
 *     where the driver wake fails (e.g. SIP restrictions). The poll is skipped for
 *     any 5 ms window in which at least one push report arrived.
 */

#include "tap_accel.h"

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDValue.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

/* Apple Silicon accelerometer: vendor-specific usage (confirmed from Knock.app) */
#define kAppleAccelUsagePage 0xFF00u
#define kAppleAccelUsage     0x0003u

/* Apple Silicon gyroscope: same vendor page, next usage slot */
#define kAppleGyroUsagePage  0xFF00u
#define kAppleGyroUsage      0x0005u

/*
 * Report layout (22 bytes, confirmed by inspecting raw HID reports):
 *   Bytes 0–1  : uint16 LE sequence counter  (discard)
 *   Bytes 2–5  : zeros / padding             (discard)
 *   Bytes 6–9  : int32 LE  axis X   Q16.16 fixed-point (÷65536 → g)
 *   Bytes 10–13: int32 LE  axis Y   Q16.16
 *   Bytes 14–17: int32 LE  axis Z   Q16.16  ← gravity axis (~±1 g at rest)
 *   Bytes 18–21: other fields — ignored
 */
#define ACCEL_SCALE          65536.0
#define ACCEL_OFFSET         6          /* byte offset of first int32 axis */
#define REPORT_INTERVAL_US   1000       /* 1 ms → 1 kHz driver report rate */
#define POLL_INTERVAL        0.005      /* 5 ms → ~200 Hz fallback poll */
#define REPORT_ID            0          /* request report ID 0 (default) */

/* ── Module-level state ───────────────────────────────────────────────────── */
static IOHIDManagerRef   s_mgr         = NULL;
static IOHIDDeviceRef    s_device      = NULL;
static TapAccelCallback  s_callback    = NULL;
static void             *s_ctx         = NULL;
static CFRunLoopTimerRef s_timer       = NULL;
static bool              s_push_active = false; /* true if push delivered this interval */

/* Separate buffers so poll and push never alias */
static uint8_t s_poll_buf[512];
static uint8_t s_push_buf[512];

/* ── Helper: read a little-endian Int32 ───────────────────────────────────── */
static int32_t read_le32(const uint8_t *p)
{
    return (int32_t)( (uint32_t)p[0]
                    | ((uint32_t)p[1] << 8)
                    | ((uint32_t)p[2] << 16)
                    | ((uint32_t)p[3] << 24) );
}

/* ── Parse and dispatch one report buffer ────────────────────────────────── */
static void dispatch_report(const uint8_t *report, CFIndex len)
{
    if (!s_callback || len < ACCEL_OFFSET + 12) return;

    double x = (double)read_le32(report + ACCEL_OFFSET + 0) / ACCEL_SCALE;
    double y = (double)read_le32(report + ACCEL_OFFSET + 4) / ACCEL_SCALE;
    double z = (double)read_le32(report + ACCEL_OFFSET + 8) / ACCEL_SCALE;

    s_callback(x, y, z, s_ctx);
}

/* ── Driver wake ─────────────────────────────────────────────────────────── */
/*
 * Mirrors the Python technique from olvvier/apple-silicon-accelerometer:
 * get the underlying io_service_t from the HID device and set the three
 * AppleSPUHIDDriver properties that enable continuous 1 kHz output.
 */
static void wake_spu_driver(IOHIDDeviceRef device)
{
    io_service_t svc = IOHIDDeviceGetService(device);
    if (!svc) {
        fprintf(stderr, "[tap_accel]   → IOHIDDeviceGetService returned NULL, skipping driver wake\n");
        return;
    }

    struct { const char *key; int32_t val; } props[] = {
        { "SensorPropertyReportingState", 1                  },
        { "SensorPropertyPowerState",     1                  },
        { "ReportInterval",               REPORT_INTERVAL_US },
    };

    for (int i = 0; i < 3; i++) {
        CFStringRef cfKey = CFStringCreateWithCString(
            kCFAllocatorDefault, props[i].key, kCFStringEncodingUTF8);
        CFNumberRef cfVal = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt32Type, &props[i].val);
        IOReturn r = IORegistryEntrySetCFProperty(svc, cfKey, cfVal);
        fprintf(stderr, "[tap_accel]   → set %s=%d → 0x%x\n",
                props[i].key, props[i].val, r);
        CFRelease(cfKey);
        CFRelease(cfVal);
    }
}

/* ── Event-driven push callback (with mach timestamp) ───────────────────── */
/*
 * Delivered by IOHIDDeviceRegisterInputReportWithTimeStampCallback each time
 * the SPU pushes a new report (up to 1 kHz after driver wake).
 */
static void push_report_cb(void            *context,
                            IOReturn         result,
                            void            *sender,
                            IOHIDReportType  type,
                            uint32_t         reportID,
                            uint8_t         *report,
                            CFIndex          reportLength,
                            uint64_t         timestamp)
{
    (void)context; (void)sender; (void)type; (void)reportID; (void)timestamp;
    if (result != kIOReturnSuccess) return;
    s_push_active = true;
    dispatch_report(report, reportLength);
}

/* ── Fallback poll timer ─────────────────────────────────────────────────── */
/*
 * Fires every 5 ms but is a no-op when the push callback is delivering data.
 * Provides continuity on machines where the driver wake fails.
 */
static void poll_timer_cb(CFRunLoopTimerRef timer, void *info)
{
    (void)timer; (void)info;

    if (s_push_active) {
        s_push_active = false; /* reset sentinel for next interval */
        return;
    }

    if (!s_device) return;

    CFIndex len = (CFIndex)sizeof(s_poll_buf);
    memset(s_poll_buf, 0, sizeof(s_poll_buf));

    IOReturn ret = IOHIDDeviceGetReport(s_device,
                                        kIOHIDReportTypeInput,
                                        REPORT_ID,
                                        s_poll_buf,
                                        &len);
    if (ret != kIOReturnSuccess) return;
    dispatch_report(s_poll_buf, len);
}

/* ── Device matched ───────────────────────────────────────────────────────── */
static void device_matching_cb(void        *context,
                                IOReturn     result,
                                void        *sender,
                                IOHIDDeviceRef device)
{
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;

    CFStringRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char prod[128] = "<unnamed>";
    if (product) CFStringGetCString(product, prod, sizeof(prod), kCFStringEncodingUTF8);
    fprintf(stderr, "[tap_accel] matched: \"%s\"\n", prod);

    /* Skip the keyboard/trackpad composite device — we want the pure sensor */
    if (strstr(prod, "Keyboard") || strstr(prod, "Trackpad")) {
        fprintf(stderr, "[tap_accel]   → skipped (keyboard/trackpad)\n");
        return;
    }

    /* Keep the first matching sensor device */
    if (s_device) {
        fprintf(stderr, "[tap_accel]   → already have a device, skipping\n");
        return;
    }

    IOReturn openRet = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[tap_accel]   → IOHIDDeviceOpen result=0x%x (%s)\n",
            openRet, openRet == kIOReturnSuccess ? "ok" : "FAILED");
    if (openRet != kIOReturnSuccess) return;

    s_device = device;

    /* 1. Wake the SPU driver for continuous 1 kHz output */
    wake_spu_driver(device);

    /* 2. Register event-driven push callback (primary data path) */
    IOHIDDeviceRegisterInputReportWithTimeStampCallback(
        device, s_push_buf, (CFIndex)sizeof(s_push_buf),
        push_report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    /* 3. Start fallback poll timer (skipped when push is active) */
    CFRunLoopTimerContext ctx = { 0, NULL, NULL, NULL, NULL };
    s_timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                   CFAbsoluteTimeGetCurrent() + POLL_INTERVAL,
                                   POLL_INTERVAL,
                                   0, 0,
                                   poll_timer_cb,
                                   &ctx);
    CFRunLoopAddTimer(CFRunLoopGetMain(), s_timer, kCFRunLoopDefaultMode);
    fprintf(stderr, "[tap_accel]   → event-driven (1 kHz) + fallback poll (%.0f ms)\n",
            POLL_INTERVAL * 1000.0);
}

static void device_removal_cb(void        *context,
                               IOReturn     result,
                               void        *sender,
                               IOHIDDeviceRef device)
{
    (void)context; (void)result; (void)sender;
    fprintf(stderr, "[tap_accel] device removed\n");
    if (device == s_device) {
        s_device = NULL;
        if (s_timer) {
            CFRunLoopTimerInvalidate(s_timer);
            CFRelease(s_timer);
            s_timer = NULL;
        }
    }
}

/* ── Public API ───────────────────────────────────────────────────────────── */

int tap_accel_start(TapAccelCallback callback, void *ctx)
{
    if (s_mgr) return 0;

    s_callback    = callback;
    s_ctx         = ctx;
    s_push_active = false;

    s_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!s_mgr) return -1;

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int pg = (int)kAppleAccelUsagePage;
    int us = (int)kAppleAccelUsage;
    CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pg);
    CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &us);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), nPage);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey),     nUsage);
    CFRelease(nPage);
    CFRelease(nUsage);

    IOHIDManagerSetDeviceMatching(s_mgr, match);
    CFRelease(match);

    IOHIDManagerRegisterDeviceMatchingCallback(s_mgr, device_matching_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(s_mgr, device_removal_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(s_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn ret = IOHIDManagerOpen(s_mgr, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[tap_accel] IOHIDManagerOpen result=0x%x (%s)\n",
            ret, ret == kIOReturnSuccess ? "ok" : "FAILED");

    if (ret != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(s_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(s_mgr);
        s_mgr = NULL;
        return -1;
    }
    return 0;
}

void tap_accel_stop(void)
{
    if (!s_mgr) return;

    if (s_timer) {
        CFRunLoopTimerInvalidate(s_timer);
        CFRelease(s_timer);
        s_timer = NULL;
    }

    if (s_device) {
        IOHIDDeviceClose(s_device, kIOHIDOptionsTypeNone);
        s_device = NULL;
    }

    IOHIDManagerClose(s_mgr, kIOHIDOptionsTypeNone);
    IOHIDManagerUnscheduleFromRunLoop(s_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(s_mgr);
    s_mgr         = NULL;
    s_callback    = NULL;
    s_ctx         = NULL;
    s_push_active = false;
}

/* ══════════════════════════════════════════════════════════════════════════════
 * Gyroscope — same SPU, same report layout, usage 0x0005
 * ══════════════════════════════════════════════════════════════════════════════
 *
 * At rest all three angular-velocity axes read ~0 rad/s.
 * During whole-laptop movement the magnitude typically exceeds 0.3–0.5 rad/s.
 */

static IOHIDManagerRef   s_gyro_mgr      = NULL;
static IOHIDDeviceRef    s_gyro_device   = NULL;
static TapGyroCallback   s_gyro_callback = NULL;
static void             *s_gyro_ctx      = NULL;
static uint8_t           s_gyro_buf[512];

static void gyro_push_cb(void *context, IOReturn result, void *sender,
                         IOHIDReportType type, uint32_t reportID,
                         uint8_t *report, CFIndex len, uint64_t timestamp)
{
    (void)context; (void)sender; (void)type; (void)reportID; (void)timestamp;
    if (result != kIOReturnSuccess || !s_gyro_callback) return;
    if (len < ACCEL_OFFSET + 12) return;
    double rx = (double)read_le32(report + ACCEL_OFFSET + 0) / ACCEL_SCALE;
    double ry = (double)read_le32(report + ACCEL_OFFSET + 4) / ACCEL_SCALE;
    double rz = (double)read_le32(report + ACCEL_OFFSET + 8) / ACCEL_SCALE;
    s_gyro_callback(rx, ry, rz, s_gyro_ctx);
}

static void gyro_device_matching_cb(void *context, IOReturn result,
                                    void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;

    CFStringRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char prod[128] = "<unnamed>";
    if (product) CFStringGetCString(product, prod, sizeof(prod), kCFStringEncodingUTF8);
    fprintf(stderr, "[tap_gyro] matched: \"%s\"\n", prod);

    if (strstr(prod, "Keyboard") || strstr(prod, "Trackpad")) {
        fprintf(stderr, "[tap_gyro]   → skipped\n");
        return;
    }
    if (s_gyro_device) {
        fprintf(stderr, "[tap_gyro]   → already have a device, skipping\n");
        return;
    }

    IOReturn openRet = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[tap_gyro]   → IOHIDDeviceOpen result=0x%x (%s)\n",
            openRet, openRet == kIOReturnSuccess ? "ok" : "FAILED");
    if (openRet != kIOReturnSuccess) return;

    s_gyro_device = device;
    wake_spu_driver(device);

    IOHIDDeviceRegisterInputReportWithTimeStampCallback(
        device, s_gyro_buf, (CFIndex)sizeof(s_gyro_buf),
        gyro_push_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    fprintf(stderr, "[tap_gyro]   → event-driven gyroscope active\n");
}

static void gyro_device_removal_cb(void *context, IOReturn result,
                                   void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)result; (void)sender;
    fprintf(stderr, "[tap_gyro] device removed\n");
    if (device == s_gyro_device) s_gyro_device = NULL;
}

int tap_gyro_start(TapGyroCallback callback, void *ctx)
{
    if (s_gyro_mgr) return 0;

    s_gyro_callback = callback;
    s_gyro_ctx      = ctx;

    s_gyro_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!s_gyro_mgr) return -1;

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int pg = (int)kAppleGyroUsagePage;
    int us = (int)kAppleGyroUsage;
    CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pg);
    CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &us);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), nPage);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey),     nUsage);
    CFRelease(nPage);
    CFRelease(nUsage);

    IOHIDManagerSetDeviceMatching(s_gyro_mgr, match);
    CFRelease(match);

    IOHIDManagerRegisterDeviceMatchingCallback(s_gyro_mgr, gyro_device_matching_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(s_gyro_mgr, gyro_device_removal_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(s_gyro_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn ret = IOHIDManagerOpen(s_gyro_mgr, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[tap_gyro] IOHIDManagerOpen result=0x%x (%s)\n",
            ret, ret == kIOReturnSuccess ? "ok" : "FAILED");

    if (ret != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(s_gyro_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(s_gyro_mgr);
        s_gyro_mgr = NULL;
        return -1;
    }
    return 0;
}

void tap_gyro_stop(void)
{
    if (!s_gyro_mgr) return;

    if (s_gyro_device) {
        IOHIDDeviceClose(s_gyro_device, kIOHIDOptionsTypeNone);
        s_gyro_device = NULL;
    }

    IOHIDManagerClose(s_gyro_mgr, kIOHIDOptionsTypeNone);
    IOHIDManagerUnscheduleFromRunLoop(s_gyro_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRelease(s_gyro_mgr);
    s_gyro_mgr      = NULL;
    s_gyro_callback = NULL;
    s_gyro_ctx      = NULL;
}
