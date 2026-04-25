#ifndef TAP_ACCEL_H
#define TAP_ACCEL_H

/// Callback fired on the main run loop with each accelerometer sample (in g-force).
typedef void (*TapAccelCallback)(double x, double y, double z, void *ctx);

/// Open the built-in accelerometer via IOKit HID and begin streaming samples.
/// Schedules callbacks on CFRunLoopGetMain().
/// Returns 0 on success, -1 if the accelerometer device could not be opened
/// (e.g. not Apple Silicon, or access denied).
int tap_accel_start(TapAccelCallback callback, void *ctx);

/// Stop streaming and release all IOKit resources.
void tap_accel_stop(void);

/// Callback fired on the main run loop with each gyroscope sample (in rad/s).
typedef void (*TapGyroCallback)(double rx, double ry, double rz, void *ctx);

/// Open the built-in gyroscope via IOKit HID and begin streaming samples.
/// Schedules callbacks on CFRunLoopGetMain().
/// Returns 0 on success, -1 if the gyroscope device could not be opened.
int tap_gyro_start(TapGyroCallback callback, void *ctx);

/// Stop gyroscope streaming and release all IOKit resources.
void tap_gyro_stop(void);

#endif /* TAP_ACCEL_H */
