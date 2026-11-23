// Game controllers for XInput, on Apple's GameController framework (Xbox, PlayStation, Switch Pro and MFi
// controllers, wired or Bluetooth). Up to four controllers take the XInput slots 0-3 in connection order.
// Buttons and axes are mapped to the Xbox layout XInput reports; rumble goes through CoreHaptics.
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include "rt.h"
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

enum {   // XINPUT_GAMEPAD buttons
    XB_UP = 0x0001, XB_DOWN = 0x0002, XB_LEFT = 0x0004, XB_RIGHT = 0x0008, XB_START = 0x0010, XB_BACK = 0x0020,
    XB_LTHUMB = 0x0040, XB_RTHUMB = 0x0080, XB_LSHOULDER = 0x0100, XB_RSHOULDER = 0x0200, XB_GUIDE = 0x0400,
    XB_A = 0x1000, XB_B = 0x2000, XB_X = 0x4000, XB_Y = 0x8000,
};

typedef struct {
    GCController *gc;
    CHHapticEngine *engine; id<CHHapticAdvancedPatternPlayer> player; float rumble;
    uint32_t packet; uint8_t last[12];
} Pad;
static Pad pads[4];
static pthread_mutex_t pmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once = PTHREAD_ONCE_INIT;

// Windows tells programs about new devices with WM_DEVICECHANGE (DBT_DEVNODES_CHANGED), and games rescan
// XInput when they get it: send it to the game's window on every connect and disconnect.
extern uint64_t rt_last_surface_hwnd;
void win_from_cocoa(uint64_t h, uint32_t msg, uint64_t wp, uint64_t lp);
static atomic_int change_pending;   // a change seen before the game window existed
static void device_change(void) {
    if (rt_last_surface_hwnd) { change_pending = 0; win_from_cocoa(rt_last_surface_hwnd, 0x0219, 0x0007, 0); }   // WM_DEVICECHANGE, DBT_DEVNODES_CHANGED
    else change_pending = 1;
}
static void assign(GCController *gc) {
    pthread_mutex_lock(&pmu);
    int slot = -1;
    for (int i = 0; i < 4; i++) if (pads[i].gc == gc) slot = i;
    for (int i = 0; slot < 0 && i < 4; i++) if (!pads[i].gc) slot = i;
    if (slot >= 0 && !pads[slot].gc && gc.extendedGamepad) {
        pads[slot] = (Pad){ .gc = gc };
        gc.playerIndex = (GCControllerPlayerIndex)slot;
        rt_log("[gamepad] %s connected as player %d\n", gc.vendorName.UTF8String ?: "controller", slot + 1);
    }
    pthread_mutex_unlock(&pmu);
    device_change();
}
static void release(GCController *gc) {
    pthread_mutex_lock(&pmu);
    for (int i = 0; i < 4; i++) if (pads[i].gc == gc) {
        [pads[i].engine stopWithCompletionHandler:nil];
        pads[i] = (Pad){ 0 };
        rt_log("[gamepad] player %d disconnected\n", i + 1);
    }
    pthread_mutex_unlock(&pmu);
    device_change();
}
static void init(void) {
    dispatch_block_t setup = ^{
        // keep reading controllers while another app is in front (the game polls; macOS would drop input)
        GCController.shouldMonitorBackgroundEvents = YES;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { assign(n.object); }];
        [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { release(n.object); }];
        for (GCController *gc in GCController.controllers) assign(gc);
    };
    if ([NSThread isMainThread]) setup(); else dispatch_async(dispatch_get_main_queue(), setup);
}

static int16_t axis(float v) { v = v < -1 ? -1 : v > 1 ? 1 : v; return (int16_t)(v < 0 ? v * 32768.0f : v * 32767.0f); }

// XINPUT_STATE: dwPacketNumber +0, wButtons +4, bLeftTrigger +6, bRightTrigger +7, sThumbLX/LY/RX/RY +8..+14
void gamepad_start(void) { pthread_once(&once, init); }   // cocoa.m, at app start (main thread)

// Summarize polling per caller thread. Log outside the controller mutex.
static void report_gamepad_poll(uint64_t started, uint64_t before_lock,
                                uint64_t locked, int connected) {
    static _Thread_local uint64_t window, calls, connected_calls;
    static _Thread_local uint64_t max_prepare, max_lock, max_read, slow;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!window) window = now;
    calls++;
    connected_calls += connected;
    if (now - started >= 1000000) slow++;
    if (before_lock - started > max_prepare) max_prepare = before_lock - started;
    if (locked - before_lock > max_lock) max_lock = locked - before_lock;
    if (now - locked > max_read) max_read = now - locked;
    if (now - window < 5000000000ull) return;

    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    rt_log("[xinput timing] thread=%llu polls=%llu (%.1f/s) connected=%llu slow1ms=%llu "
           "maxBeforeLock=%.2fms maxLockWait=%.2fms maxRead=%.2fms\n",
           (unsigned long long)tid, (unsigned long long)calls, calls * 1e9 / (now - window),
           (unsigned long long)connected_calls, (unsigned long long)slow,
           max_prepare / 1e6, max_lock / 1e6, max_read / 1e6);
    window = now;
    calls = connected_calls = slow = max_prepare = max_lock = max_read = 0;
}

int gamepad_state(int user, uint8_t out[16], int guide) {
    uint64_t started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_once(&once, init);
    if (change_pending && rt_last_surface_hwnd) device_change();
    if (user < 0 || user > 3) return 0;
    uint64_t before_lock = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_mutex_lock(&pmu);
    uint64_t locked = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    Pad *p = &pads[user];
    GCExtendedGamepad *g = p->gc.extendedGamepad;
    if (!g) {
        pthread_mutex_unlock(&pmu);
        report_gamepad_poll(started, before_lock, locked, 0);
        return 0;
    }
    uint16_t b = 0;
    if (g.dpad.up.pressed) b |= XB_UP;
    if (g.dpad.down.pressed) b |= XB_DOWN;
    if (g.dpad.left.pressed) b |= XB_LEFT;
    if (g.dpad.right.pressed) b |= XB_RIGHT;
    if (g.buttonMenu.pressed) b |= XB_START;          // Xbox Menu, PlayStation Options, Switch +
    if (g.buttonOptions.pressed) b |= XB_BACK;        // Xbox View, PlayStation Share/Create, Switch -
    if (g.leftThumbstickButton.pressed) b |= XB_LTHUMB;
    if (g.rightThumbstickButton.pressed) b |= XB_RTHUMB;
    if (g.leftShoulder.pressed) b |= XB_LSHOULDER;
    if (g.rightShoulder.pressed) b |= XB_RSHOULDER;
    if (guide && g.buttonHome.pressed) b |= XB_GUIDE;
    if (g.buttonA.pressed) b |= XB_A;                 // bottom face button (Cross on PlayStation)
    if (g.buttonB.pressed) b |= XB_B;
    if (g.buttonX.pressed) b |= XB_X;
    if (g.buttonY.pressed) b |= XB_Y;
    uint8_t s[12];
    memcpy(s, &b, 2);
    s[2] = (uint8_t)(g.leftTrigger.value * 255.0f + 0.5f);
    s[3] = (uint8_t)(g.rightTrigger.value * 255.0f + 0.5f);
    int16_t ax[4] = { axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value),
                      axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value) };
    memcpy(s + 4, ax, 8);
    if (memcmp(s, p->last, sizeof s)) { memcpy(p->last, s, sizeof s); p->packet++; }   // the packet number changes with the state
    memcpy(out, &p->packet, 4);
    memcpy(out + 4, s, 12);
    pthread_mutex_unlock(&pmu);
    report_gamepad_poll(started, before_lock, locked, 1);
    return 1;
}

int gamepad_connected(int user) {
    pthread_once(&once, init);
    if (change_pending && rt_last_surface_hwnd) device_change();
    if (user < 0 || user > 3) return 0;
    pthread_mutex_lock(&pmu);
    int r = pads[user].gc.extendedGamepad != nil;
    pthread_mutex_unlock(&pmu);
    return r;
}

// XInputSetState: the two motors (0-65535) become one haptic intensity, played as a continuous event whose
// intensity follows the game's requests
static void rumble_locked(Pad *p, float level) {
    if (!p->gc.haptics) return;
    if (!p->engine) {
        p->engine = [p->gc.haptics createEngineWithLocality:GCHapticsLocalityDefault];
        if (!p->engine) return;
        p->engine.playsHapticsOnly = YES;
        p->engine.autoShutdownEnabled = NO;
        NSError *e = nil;
        if (![p->engine startAndReturnError:&e]) { p->engine = nil; return; }
        CHHapticEvent *ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
            parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0f] ]
            relativeTime:0 duration:3600];
        CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&e];
        p->player = pat ? [p->engine createAdvancedPlayerWithPattern:pat error:&e] : nil;
        if (!p->player) { [p->engine stopWithCompletionHandler:nil]; p->engine = nil; return; }
    }
    if (level == p->rumble) return;
    NSError *e = nil;
    if (level <= 0) { [p->player pauseAtTime:CHHapticTimeImmediate error:&e]; }
    else {
        CHHapticDynamicParameter *dp = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level relativeTime:0];
        [p->player sendParameters:@[ dp ] atTime:CHHapticTimeImmediate error:&e];
        if (p->rumble <= 0) {
            if (p->player.isMuted) p->player.isMuted = NO;
            [p->player resumeAtTime:CHHapticTimeImmediate error:&e] || [p->player startAtTime:CHHapticTimeImmediate error:&e];
        }
    }
    p->rumble = level;
}
int gamepad_rumble(int user, uint16_t left, uint16_t right) {
    pthread_once(&once, init);
    if (user < 0 || user > 3) return 0;
    pthread_mutex_lock(&pmu);
    Pad *p = &pads[user];
    int ok = p->gc.extendedGamepad != nil;
    if (ok) {
        float level = (float)(left > right ? left : right) / 65535.0f;
        @try { rumble_locked(p, level); } @catch (NSException *x) { }
    }
    pthread_mutex_unlock(&pmu);
    return ok;
}

// XINPUT_BATTERY_INFORMATION { BatteryType, BatteryLevel }
void gamepad_battery(int user, uint8_t *type, uint8_t *level) {
    *type = 1; *level = 3;   // BATTERY_TYPE_WIRED, BATTERY_LEVEL_FULL
    pthread_mutex_lock(&pmu);
    GCDeviceBattery *bat = (user >= 0 && user < 4) ? pads[user].gc.battery : nil;
    if (bat && bat.batteryState != GCDeviceBatteryStateUnknown && bat.batteryState != GCDeviceBatteryStateFull) {
        *type = 2;   // BATTERY_TYPE_ALKALINE (any battery)
        float l = bat.batteryLevel;
        *level = l < 0.05f ? 0 : l < 0.35f ? 1 : l < 0.7f ? 2 : 3;
    }
    pthread_mutex_unlock(&pmu);
}
