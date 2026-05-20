/*
 * TapTapSPU — privileged LaunchDaemon that wakes the Apple Silicon SPU
 * (accelerometer + gyroscope) and streams 25-byte samples over a Unix
 * domain socket to the main TapTap app process.
 *
 * Socket path : /tmp/com.colmo.taptap.spud
 * Sample format (25 bytes, packed, little-endian):
 *   uint8_t  type   — 0 = accel, 1 = gyro
 *   double   x      — 8 bytes LE
 *   double   y      — 8 bytes LE
 *   double   z      — 8 bytes LE
 */

#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDValue.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* ── Constants ────────────────────────────────────────────────────────────── */

#define SOCKET_PATH       "/tmp/com.colmo.taptap.spud"

#define ACCEL_USAGE_PAGE  0xFF00u
#define ACCEL_USAGE       0x0003u
#define GYRO_USAGE_PAGE   0xFF00u
#define GYRO_USAGE        0x0009u

#define REPORT_OFFSET     6           /* byte offset of first int32 axis     */
#define REPORT_SCALE      65536.0     /* Q16.16 → physical units divisor     */
#define REPORT_INTERVAL   1000        /* µs → 1 kHz driver report rate       */
#define MIN_REPORT_LEN    (REPORT_OFFSET + 12)

#define SAMPLE_TYPE_ACCEL 0
#define SAMPLE_TYPE_GYRO  1
#define SAMPLE_SIZE       25          /* 1 + 8 + 8 + 8                       */

/* ── Shared client fd (protected by mutex) ────────────────────────────────── */

static volatile int  g_client_fd = -1;
static pthread_mutex_t g_fd_mutex = PTHREAD_MUTEX_INITIALIZER;

/* ── Helper: read little-endian int32 ────────────────────────────────────── */

static int32_t read_le32(const uint8_t *p)
{
    return (int32_t)( (uint32_t)p[0]
                    | ((uint32_t)p[1] <<  8)
                    | ((uint32_t)p[2] << 16)
                    | ((uint32_t)p[3] << 24) );
}

/* ── Serialize and write one sample to the current client ─────────────────── */

static void send_sample(uint8_t type, double x, double y, double z)
{
    uint8_t buf[SAMPLE_SIZE];
    buf[0] = type;
    memcpy(buf + 1,  &x, 8);
    memcpy(buf + 9,  &y, 8);
    memcpy(buf + 17, &z, 8);

    pthread_mutex_lock(&g_fd_mutex);
    int fd = g_client_fd;
    pthread_mutex_unlock(&g_fd_mutex);

    if (fd < 0) return;

    ssize_t n = write(fd, buf, SAMPLE_SIZE);
    if (n < 0) {
        /* Broken pipe — client disconnected; clear fd until next accept(). */
        fprintf(stderr, "[spud] write failed (fd=%d errno=%d), client gone\n",
                fd, errno);
        pthread_mutex_lock(&g_fd_mutex);
        if (g_client_fd == fd) g_client_fd = -1;
        pthread_mutex_unlock(&g_fd_mutex);
        close(fd);
    }
}

/* ── Parse a raw HID report and emit a sample ─────────────────────────────── */

static void dispatch_report(const uint8_t *report, CFIndex len, uint8_t type)
{
    if (len < MIN_REPORT_LEN) return;

    double x = (double)read_le32(report + REPORT_OFFSET + 0) / REPORT_SCALE;
    double y = (double)read_le32(report + REPORT_OFFSET + 4) / REPORT_SCALE;
    double z = (double)read_le32(report + REPORT_OFFSET + 8) / REPORT_SCALE;

    send_sample(type, x, y, z);
}

/* ── Driver wake ─────────────────────────────────────────────────────────── */

static void wake_spu_driver(IOHIDDeviceRef device, const char *label)
{
    struct { const char *key; int32_t val; } props[] = {
        { "SensorPropertyReportingState", 1            },
        { "SensorPropertyPowerState",     1            },
        { "ReportInterval",               REPORT_INTERVAL },
    };

    io_service_t svc = IOHIDDeviceGetService(device);

    for (int i = 0; i < 3; i++) {
        CFStringRef cfKey = CFStringCreateWithCString(
            kCFAllocatorDefault, props[i].key, kCFStringEncodingUTF8);
        CFNumberRef cfVal = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt32Type, &props[i].val);

        IOHIDDeviceSetProperty(device, cfKey, cfVal);
        IOReturn r = svc
            ? IORegistryEntrySetCFProperty(svc, cfKey, cfVal)
            : (IOReturn)kIOReturnNotFound;

        fprintf(stderr, "[spud] %s wake %s: IOReg=0x%x\n", label, props[i].key, r);
        CFRelease(cfKey);
        CFRelease(cfVal);
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Accelerometer
 * ═══════════════════════════════════════════════════════════════════════════ */

static IOHIDManagerRef s_accel_mgr    = NULL;
static IOHIDDeviceRef  s_accel_device = NULL;
static uint8_t         s_accel_buf[512];

static void accel_report_cb(void *context, IOReturn result, void *sender,
                             IOHIDReportType type, uint32_t reportID,
                             uint8_t *report, CFIndex len, uint64_t ts)
{
    (void)context; (void)sender; (void)type; (void)reportID; (void)ts;
    if (result != kIOReturnSuccess) return;
    dispatch_report(report, len, SAMPLE_TYPE_ACCEL);
}

static void accel_matched_cb(void *context, IOReturn result,
                              void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;
    if (s_accel_device) {
        fprintf(stderr, "[spud] accel: already matched, skipping\n");
        return;
    }

    CFStringRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char prod[128] = "<unnamed>";
    if (product) CFStringGetCString(product, prod, sizeof(prod), kCFStringEncodingUTF8);
    fprintf(stderr, "[spud] accel matched: \"%s\"\n", prod);

    IOReturn openRet = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[spud] accel open: 0x%x (%s)\n",
            openRet, openRet == kIOReturnSuccess ? "ok" : "FAILED");
    if (openRet != kIOReturnSuccess) return;

    s_accel_device = device;
    wake_spu_driver(device, "accel");

    IOHIDDeviceRegisterInputReportWithTimeStampCallback(
        device, s_accel_buf, (CFIndex)sizeof(s_accel_buf),
        accel_report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    fprintf(stderr, "[spud] accel streaming at 1 kHz\n");
}

static void accel_removed_cb(void *context, IOReturn result,
                              void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)result; (void)sender;
    fprintf(stderr, "[spud] accel removed\n");
    if (device == s_accel_device) s_accel_device = NULL;
}

static int start_accel(void)
{
    s_accel_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!s_accel_mgr) return -1;

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int pg = (int)ACCEL_USAGE_PAGE, us = (int)ACCEL_USAGE;
    CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pg);
    CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &us);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), nPage);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey),     nUsage);
    CFRelease(nPage);
    CFRelease(nUsage);

    IOHIDManagerSetDeviceMatching(s_accel_mgr, match);
    CFRelease(match);

    IOHIDManagerRegisterDeviceMatchingCallback(s_accel_mgr, accel_matched_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(s_accel_mgr, accel_removed_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(s_accel_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn ret = IOHIDManagerOpen(s_accel_mgr, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[spud] accel IOHIDManagerOpen: 0x%x (%s)\n",
            ret, ret == kIOReturnSuccess ? "ok" : "FAILED");

    if (ret != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(s_accel_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(s_accel_mgr);
        s_accel_mgr = NULL;
        return -1;
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Gyroscope
 * ═══════════════════════════════════════════════════════════════════════════ */

static IOHIDManagerRef s_gyro_mgr    = NULL;
static IOHIDDeviceRef  s_gyro_device = NULL;
static uint8_t         s_gyro_buf[512];

static void gyro_report_cb(void *context, IOReturn result, void *sender,
                            IOHIDReportType type, uint32_t reportID,
                            uint8_t *report, CFIndex len, uint64_t ts)
{
    (void)context; (void)sender; (void)type; (void)reportID; (void)ts;
    if (result != kIOReturnSuccess) return;
    dispatch_report(report, len, SAMPLE_TYPE_GYRO);
}

static void gyro_matched_cb(void *context, IOReturn result,
                             void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;
    if (s_gyro_device) {
        fprintf(stderr, "[spud] gyro: already matched, skipping\n");
        return;
    }

    CFStringRef product = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductKey));
    char prod[128] = "<unnamed>";
    if (product) CFStringGetCString(product, prod, sizeof(prod), kCFStringEncodingUTF8);
    fprintf(stderr, "[spud] gyro matched: \"%s\"\n", prod);

    IOReturn openRet = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[spud] gyro open: 0x%x (%s)\n",
            openRet, openRet == kIOReturnSuccess ? "ok" : "FAILED");
    if (openRet != kIOReturnSuccess) return;

    s_gyro_device = device;
    wake_spu_driver(device, "gyro");

    IOHIDDeviceRegisterInputReportWithTimeStampCallback(
        device, s_gyro_buf, (CFIndex)sizeof(s_gyro_buf),
        gyro_report_cb, NULL);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    fprintf(stderr, "[spud] gyro streaming at 1 kHz\n");
}

static void gyro_removed_cb(void *context, IOReturn result,
                             void *sender, IOHIDDeviceRef device)
{
    (void)context; (void)result; (void)sender;
    fprintf(stderr, "[spud] gyro removed\n");
    if (device == s_gyro_device) s_gyro_device = NULL;
}

static int start_gyro(void)
{
    s_gyro_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!s_gyro_mgr) return -1;

    CFMutableDictionaryRef match = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);

    int pg = (int)GYRO_USAGE_PAGE, us = (int)GYRO_USAGE;
    CFNumberRef nPage  = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pg);
    CFNumberRef nUsage = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &us);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsagePageKey), nPage);
    CFDictionarySetValue(match, CFSTR(kIOHIDPrimaryUsageKey),     nUsage);
    CFRelease(nPage);
    CFRelease(nUsage);

    IOHIDManagerSetDeviceMatching(s_gyro_mgr, match);
    CFRelease(match);

    IOHIDManagerRegisterDeviceMatchingCallback(s_gyro_mgr, gyro_matched_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(s_gyro_mgr, gyro_removed_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(s_gyro_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);

    IOReturn ret = IOHIDManagerOpen(s_gyro_mgr, kIOHIDOptionsTypeNone);
    fprintf(stderr, "[spud] gyro IOHIDManagerOpen: 0x%x (%s)\n",
            ret, ret == kIOReturnSuccess ? "ok" : "FAILED");

    if (ret != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(s_gyro_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(s_gyro_mgr);
        s_gyro_mgr = NULL;
        return -1;
    }
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Accept thread — loops forever accepting one client at a time
 * ═══════════════════════════════════════════════════════════════════════════ */

static void *accept_thread(void *arg)
{
    int server_fd = *(int *)arg;

    for (;;) {
        fprintf(stderr, "[spud] waiting for client...\n");
        int fd = accept(server_fd, NULL, NULL);
        if (fd < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "[spud] accept() error: %d\n", errno);
            continue;
        }
        fprintf(stderr, "[spud] client connected (fd=%d)\n", fd);

        int old_fd = -1;
        pthread_mutex_lock(&g_fd_mutex);
        old_fd = g_client_fd;
        g_client_fd = fd;
        pthread_mutex_unlock(&g_fd_mutex);

        if (old_fd >= 0) {
            fprintf(stderr, "[spud] closing previous client fd=%d\n", old_fd);
            close(old_fd);
        }
    }
    return NULL;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * main
 * ═══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    signal(SIGPIPE, SIG_IGN);

    fprintf(stderr, "[spud] starting\n");

    /* Remove stale socket if any */
    unlink(SOCKET_PATH);

    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        fprintf(stderr, "[spud] socket() failed: %d\n", errno);
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path));

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[spud] bind() failed: %d\n", errno);
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, 4) < 0) {
        fprintf(stderr, "[spud] listen() failed: %d\n", errno);
        close(server_fd);
        return 1;
    }

    /* Allow any user to connect (app runs as the logged-in user, not root) */
    chmod(SOCKET_PATH, 0666);

    fprintf(stderr, "[spud] listening on %s\n", SOCKET_PATH);

    /* Spin up accept thread */
    pthread_t thread;
    if (pthread_create(&thread, NULL, accept_thread, &server_fd) != 0) {
        fprintf(stderr, "[spud] pthread_create() failed\n");
        close(server_fd);
        return 1;
    }
    pthread_detach(thread);

    /* Start HID managers */
    if (start_accel() != 0)
        fprintf(stderr, "[spud] WARNING: accel init failed\n");
    if (start_gyro() != 0)
        fprintf(stderr, "[spud] WARNING: gyro init failed\n");

    fprintf(stderr, "[spud] entering run loop\n");
    CFRunLoopRun();

    /* Should not reach here */
    fprintf(stderr, "[spud] run loop exited unexpectedly\n");
    close(server_fd);
    return 0;
}
