/*
 * tap_accel.c — IOKit HID accelerometer/gyroscope reader for Apple Silicon.
 *
 * Device discovery pattern from github.com/olvvier/apple-silicon-accelerometer:
 *   1. Wake AppleSPUHIDDriver via IORegistryEntrySetCFProperty
 *      (SensorPropertyReportingState, SensorPropertyPowerState, ReportInterval)
 *   2. Enumerate AppleSPUHIDDevice services via IOServiceGetMatchingServices
 *   3. Create IOHIDDevice per service with IOHIDDeviceCreate + IOHIDDeviceOpen
 *   4. Register IOHIDDeviceRegisterInputReportWithTimeStampCallback
 *
 * On Apple Silicon Macs:
 *   Accelerometer: PrimaryUsagePage=0xFF00, PrimaryUsage=3
 *   Gyroscope:     PrimaryUsagePage=0xFF00, PrimaryUsage=9
 */

#include "tap_accel.h"

#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#define kAppleVendorUsagePage  0xFF00u
#define kAppleAccelUsage       3u
#define kAppleGyroUsage        9u   /* reference: USAGE_GYRO = 9, NOT 5 */

/*
 * Report layout (22 bytes):
 *   Bytes 6–9  : int32 LE  X  Q16.16 → ÷65536 = g (or rad/s for gyro)
 *   Bytes 10–13: int32 LE  Y
 *   Bytes 14–17: int32 LE  Z
 */
#define ACCEL_SCALE        65536.0
#define ACCEL_OFFSET       6
#define REPORT_BUFSZ       4096
#define REPORT_INTERVAL_US 1000    /* 1 ms = 1000 Hz; driver decimates to ~100 Hz */

/* ── Sensor state ─────────────────────────────────────────────────────────── */

static TapAccelCallback  s_accel_cb  = NULL;
static void             *s_accel_ctx = NULL;

static TapGyroCallback   s_gyro_cb   = NULL;
static void             *s_gyro_ctx  = NULL;

/* Opened devices — kept alive so callbacks stay registered */
#define MAX_DEVICES 8
static IOHIDDeviceRef s_accel_devs[MAX_DEVICES];
static int            s_accel_dev_count = 0;
static IOHIDDeviceRef s_gyro_devs[MAX_DEVICES];
static int            s_gyro_dev_count  = 0;

/* Per-device report buffers (must outlive the device) */
static uint8_t s_accel_bufs[MAX_DEVICES][REPORT_BUFSZ];
static uint8_t s_gyro_bufs[MAX_DEVICES][REPORT_BUFSZ];

/* ── Helper: little-endian int32 ──────────────────────────────────────────── */
static int32_t read_le32(const uint8_t *p)
{
    return (int32_t)((uint32_t)p[0]
                   | ((uint32_t)p[1] << 8)
                   | ((uint32_t)p[2] << 16)
                   | ((uint32_t)p[3] << 24));
}

/* ── CF helpers ───────────────────────────────────────────────────────────── */
static CFStringRef make_cfstr(const char *s)
{
    return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

static CFNumberRef make_cfnum32(int32_t v)
{
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &v);
}

/* ── Timestamped report callbacks ─────────────────────────────────────────── */

static int s_accel_sample_count = 0;

static void accel_report_cb(void *ctx,
                             IOReturn result, void *sender,
                             IOHIDReportType type, uint32_t reportID,
                             uint8_t *report, CFIndex reportLength,
                             uint64_t timestamp)
{
    (void)ctx; (void)sender; (void)type; (void)reportID; (void)timestamp;
    if (result != kIOReturnSuccess || !s_accel_cb) return;
    if (reportLength < ACCEL_OFFSET + 12) {
        fprintf(stderr, "[tap_accel] short report: %ld bytes\n", (long)reportLength);
        return;
    }
    double x = (double)read_le32(report + ACCEL_OFFSET + 0) / ACCEL_SCALE;
    double y = (double)read_le32(report + ACCEL_OFFSET + 4) / ACCEL_SCALE;
    double z = (double)read_le32(report + ACCEL_OFFSET + 8) / ACCEL_SCALE;
    s_accel_sample_count++;
    if (s_accel_sample_count <= 5 || s_accel_sample_count % 200 == 0)
        fprintf(stderr, "[tap_accel] sample #%d  x=%.3f y=%.3f z=%.3f\n",
                s_accel_sample_count, x, y, z);
    s_accel_cb(x, y, z, s_accel_ctx);
}

static void gyro_report_cb(void *ctx,
                            IOReturn result, void *sender,
                            IOHIDReportType type, uint32_t reportID,
                            uint8_t *report, CFIndex reportLength,
                            uint64_t timestamp)
{
    (void)ctx; (void)sender; (void)type; (void)reportID; (void)timestamp;
    if (result != kIOReturnSuccess || !s_gyro_cb) return;
    if (reportLength < ACCEL_OFFSET + 12) return;
    double rx = (double)read_le32(report + ACCEL_OFFSET + 0) / ACCEL_SCALE;
    double ry = (double)read_le32(report + ACCEL_OFFSET + 4) / ACCEL_SCALE;
    double rz = (double)read_le32(report + ACCEL_OFFSET + 8) / ACCEL_SCALE;
    s_gyro_cb(rx, ry, rz, s_gyro_ctx);
}

/* ── Wake the SPU driver to start emitting reports ────────────────────────── */
static void wake_spu_driver(void)
{
    io_iterator_t it = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDriver");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[tap_accel] AppleSPUHIDDriver not found (kr=%d)\n", kr);
        return;
    }

    int count = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        struct { const char *key; int32_t val; } props[] = {
            { "SensorPropertyReportingState", 1 },
            { "SensorPropertyPowerState",     1 },
            { "ReportInterval", REPORT_INTERVAL_US },
        };
        for (int i = 0; i < 3; i++) {
            CFStringRef k = make_cfstr(props[i].key);
            CFNumberRef v = make_cfnum32(props[i].val);
            IORegistryEntrySetCFProperty(svc, k, v);
            CFRelease(k); CFRelease(v);
        }
        IOObjectRelease(svc);
        count++;
    }
    IOObjectRelease(it);
    fprintf(stderr, "[tap_accel] woke %d AppleSPUHIDDriver instance(s)\n", count);
}

/* ── Open one device type and register its callback ──────────────────────── */
typedef void (*TSReportCb)(void *, IOReturn, void *, IOHIDReportType,
                            uint32_t, uint8_t *, CFIndex, uint64_t);

static int open_spu_devices(uint32_t targetPage, uint32_t targetUsage,
                             TSReportCb cb,
                             IOHIDDeviceRef *devArray, int *devCount,
                             uint8_t bufs[][REPORT_BUFSZ],
                             const char *label)
{
    io_iterator_t it = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDevice");
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[%s] AppleSPUHIDDevice not found (kr=%d)\n", label, kr);
        return -1;
    }

    int found = 0;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != IO_OBJECT_NULL) {
        /* Read PrimaryUsagePage and PrimaryUsage from the IORegistry */
        CFNumberRef cfPage  = IORegistryEntryCreateCFProperty(
            svc, CFSTR("PrimaryUsagePage"), kCFAllocatorDefault, 0);
        CFNumberRef cfUsage = IORegistryEntryCreateCFProperty(
            svc, CFSTR("PrimaryUsage"), kCFAllocatorDefault, 0);

        int32_t page = 0, usage = 0;
        if (cfPage)  { CFNumberGetValue(cfPage,  kCFNumberSInt32Type, &page);  CFRelease(cfPage);  }
        if (cfUsage) { CFNumberGetValue(cfUsage, kCFNumberSInt32Type, &usage); CFRelease(cfUsage); }

        fprintf(stderr, "[%s] SPU device: page=0x%x usage=%d\n", label, page, usage);

        if ((uint32_t)page == targetPage && (uint32_t)usage == targetUsage) {
            if (*devCount >= MAX_DEVICES) {
                fprintf(stderr, "[%s] too many devices, skipping\n", label);
                IOObjectRelease(svc);
                continue;
            }

            IOHIDDeviceRef hid = IOHIDDeviceCreate(kCFAllocatorDefault, svc);
            if (!hid) {
                fprintf(stderr, "[%s] IOHIDDeviceCreate failed\n", label);
                IOObjectRelease(svc);
                continue;
            }

            IOReturn ret = IOHIDDeviceOpen(hid, kIOHIDOptionsTypeNone);
            fprintf(stderr, "[%s] IOHIDDeviceOpen → %d\n", label, ret);
            if (ret != kIOReturnSuccess) {
                CFRelease(hid);
                IOObjectRelease(svc);
                continue;
            }

            int idx = (*devCount)++;
            devArray[idx] = hid;
            memset(bufs[idx], 0, REPORT_BUFSZ);

            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                hid, bufs[idx], REPORT_BUFSZ, cb, NULL);
            IOHIDDeviceScheduleWithRunLoop(
                hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);

            fprintf(stderr, "[%s] device #%d registered\n", label, idx + 1);
            found++;
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found > 0 ? 0 : -1;
}

/* ── Public API ───────────────────────────────────────────────────────────── */

int tap_accel_start(TapAccelCallback callback, void *ctx)
{
    if (s_accel_cb) return 0;
    s_accel_cb  = callback;
    s_accel_ctx = ctx;
    s_accel_dev_count = 0;
    s_accel_sample_count = 0;

    wake_spu_driver();

    /* brief pause so the driver can start up before we enumerate devices */
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);

    int ret = open_spu_devices(kAppleVendorUsagePage, kAppleAccelUsage,
                                accel_report_cb,
                                s_accel_devs, &s_accel_dev_count,
                                s_accel_bufs, "tap_accel");
    if (ret != 0) {
        fprintf(stderr, "[tap_accel] accelerometer not found\n");
        s_accel_cb = NULL;
        return -1;
    }

    fprintf(stderr, "[tap_accel] started (%d device(s))\n", s_accel_dev_count);
    return 0;
}

void tap_accel_stop(void)
{
    for (int i = 0; i < s_accel_dev_count; i++) {
        IOHIDDeviceUnscheduleFromRunLoop(s_accel_devs[i],
            CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDDeviceClose(s_accel_devs[i], kIOHIDOptionsTypeNone);
        CFRelease(s_accel_devs[i]);
        s_accel_devs[i] = NULL;
    }
    s_accel_dev_count = 0;
    s_accel_cb  = NULL;
    s_accel_ctx = NULL;
}

int tap_gyro_start(TapGyroCallback callback, void *ctx)
{
    if (s_gyro_cb) return 0;
    s_gyro_cb  = callback;
    s_gyro_ctx = ctx;
    s_gyro_dev_count = 0;

    int ret = open_spu_devices(kAppleVendorUsagePage, kAppleGyroUsage,
                                gyro_report_cb,
                                s_gyro_devs, &s_gyro_dev_count,
                                s_gyro_bufs, "tap_gyro");
    if (ret != 0) {
        fprintf(stderr, "[tap_gyro] gyroscope not found — movement filter disabled\n");
        s_gyro_cb = NULL;
        return -1;
    }

    fprintf(stderr, "[tap_gyro] started (%d device(s))\n", s_gyro_dev_count);
    return 0;
}

void tap_gyro_stop(void)
{
    for (int i = 0; i < s_gyro_dev_count; i++) {
        IOHIDDeviceUnscheduleFromRunLoop(s_gyro_devs[i],
            CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDDeviceClose(s_gyro_devs[i], kIOHIDOptionsTypeNone);
        CFRelease(s_gyro_devs[i]);
        s_gyro_devs[i] = NULL;
    }
    s_gyro_dev_count = 0;
    s_gyro_cb  = NULL;
    s_gyro_ctx = NULL;
}
