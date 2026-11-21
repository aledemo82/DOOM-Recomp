// UIKit side of the window system, replacing cocoa.m on iOS (same cocoa.h interface).
//
// The guest runs on its own thread (boot_ios.m); UIKit owns the main thread. A guest top-level window becomes a
// UIView backed by a CAMetalLayer (the Vulkan surface) inside one full-screen root view controller, letterboxed to
// the window's aspect ratio. UIKit input becomes Win32 messages:
//   touch            -> left mouse button + pointer motion
//   hardware keyboard / mouse (GameController) -> keys, buttons, relative motion
// win_from_cocoa() and friends only take window.c's queue lock, so they may be called from UIKit's thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#include <stdatomic.h>
#include <pthread.h>
#include "cocoa.h"
void rt_log(const char *fmt, ...);
void rt_ios_gpu_pause(int paused);   // vk_ios.c
void rt_ios_cap30_configure(int enabled);
void rt_ios_cap30_display_tick(double target);

enum {
    WM_MOVE = 3, WM_SIZE = 5, WM_ACTIVATE = 6, WM_SETFOCUS = 7, WM_KILLFOCUS = 8, WM_CLOSE = 0x10, WM_ACTIVATEAPP = 0x1C,
    WM_MOUSEMOVE = 0x200, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_LBUTTONDBLCLK, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_RBUTTONDBLCLK,
    WM_MBUTTONDOWN, WM_MBUTTONUP, WM_MBUTTONDBLCLK, WM_MOUSEWHEEL,
};
enum { VK_LBUTTON = 1, VK_RBUTTON = 2, VK_MBUTTON = 4 };

static int g_active;
static _Atomic int g_dx, g_dy;                 // raw motion since the last cocoa_mouse_delta
static _Atomic int g_cx, g_cy;                 // virtual cursor, guest pixels
static _Atomic int g_buttons;                  // MK_* mask (1 left, 2 right, 0x10 middle)
static _Atomic uint64_t g_key_hwnd;            // window that receives keyboard and mouse input
static _Atomic int g_pointer_locked;
static int g_scr_w = 1920, g_scr_h = 1080, g_scr_hz = 60;   // landscape native pixels
static UIViewController *g_root;
static UIView *g_controls;
static int g_vw, g_vh;                          // emulated display mode (0 = native)
static _Atomic double g_sens = 1.0;                     // look sensitivity multiplier (SENS button), touch and gyro
static _Atomic int g_iface_orient;               // UIInterfaceOrientation, kept current from the main thread
static _Atomic int g_gyro_on;                   // gyro aiming (GYRO button)
static _Atomic BOOL g_touch_gyro_active;
static BOOL g_touch_editing, g_touch_hidden;
static BOOL g_touch_active = YES;
static _Atomic NSUInteger g_touch_epoch;
static NSUInteger g_menu_tap;
static uint64_t g_menu_enter_hwnd;
static void cancel_touch_input(void);
static void update_touch_controls(void);
static void touch_key(int mac, uint16_t ch, int down);
static const double kSensSteps[] = { 0.5, 0.75, 1.0, 1.5, 2.0, 3.0 };

static void on_main(dispatch_block_t b) { if ([NSThread isMainThread]) b(); else dispatch_sync(dispatch_get_main_queue(), b); }
int cocoa_is_main_thread(void) { return [NSThread isMainThread]; }
int cocoa_active(void) { return g_active; }

// Screen facts (main thread, before the guest starts) for display_ios.c.
void cocoa_ios_screen_init(void) {
    UIScreen *s = UIScreen.mainScreen;
    CGSize n = s.nativeBounds.size;
    g_scr_w = (int)fmax(n.width, n.height); g_scr_h = (int)fmin(n.width, n.height);
    g_scr_hz = (int)s.maximumFramesPerSecond;
    if (g_scr_hz < 30) g_scr_hz = 60;
}
void cocoa_ios_screen(int *w, int *h, int *hz) { *w = g_scr_w; *h = g_scr_h; *hz = g_scr_hz; }
double cocoa_refresh_hz(void) { return g_scr_hz; }

// ---------------- views ----------------
@class RTView;
static NSMutableArray<RTView *> *g_views;

@interface RTView : UIView
@property uint64_t hwnd;
@property double pxPerPt;                      // guest pixels per point
@property int gx, gy, gw, gh;                  // guest client rect
@property CGPoint last;
@property double downAt;
@property CGPoint start;
@property BOOL moved;
@property(weak) UITouch *tracking;
@end

static uint64_t mk_flags(void) { return (uint64_t)atomic_load(&g_buttons); }
static uint64_t pack_pos(int x, int y) { return (uint64_t)(uint16_t)x | (uint64_t)(uint16_t)y << 16; }
static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static void mouse_button(uint64_t hwnd, int which, int down) {   // which: 1 left, 2 right, 4 middle
    int mk = which == 1 ? 1 : which == 2 ? 2 : 0x10;
    if (down) atomic_fetch_or(&g_buttons, mk); else atomic_fetch_and(&g_buttons, ~mk);
    uint32_t msg = which == 1 ? (down ? WM_LBUTTONDOWN : WM_LBUTTONUP) : which == 2 ? (down ? WM_RBUTTONDOWN : WM_RBUTTONUP) : (down ? WM_MBUTTONDOWN : WM_MBUTTONUP);
    extern void win_set_key(int vk, int down);
    win_set_key(which == 1 ? VK_LBUTTON : which == 2 ? VK_RBUTTON : VK_MBUTTON, down);
    di_mouse_button(which == 1 ? 0 : which == 2 ? 1 : 2, down);
    win_from_cocoa(hwnd, msg, mk_flags(), pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
}
static void mouse_motion(uint64_t hwnd, int dx, int dy, int x, int y) {
    atomic_store(&g_cx, x); atomic_store(&g_cy, y);
    atomic_fetch_add(&g_dx, dx); atomic_fetch_add(&g_dy, dy);
    di_mouse_move(dx, dy);
    win_from_cocoa(hwnd, WM_MOUSEMOVE, mk_flags(), pack_pos(x, y));
}

@implementation RTView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) { self.multipleTouchEnabled = NO; self.backgroundColor = UIColor.blackColor; self.opaque = YES; }
    return self;
}
- (void)point:(UITouch *)t x:(int *)x y:(int *)y {
    CGPoint p = [t locationInView:self];
    *x = clampi((int)lround(p.x * self.pxPerPt), 0, self.gw - 1); *y = clampi((int)lround(p.y * self.pxPerPt), 0, self.gh - 1);
}
// Trackpad style: dragging moves the cursor by relative motion, a short tap without movement is a left click at the cursor.
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    // Hiding the overlay still allows direct touches on the game surface.
    if (!g_touch_active || g_touch_editing || self.tracking ||
        self.hwnd != atomic_load(&g_key_hwnd)) return;
    UITouch *t = ts.anyObject; self.tracking = t; self.last = self.start = [t locationInView:self];
    self.downAt = CACurrentMediaTime(); self.moved = NO;
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    UITouch *t = self.tracking; if (!t || ![ts containsObject:t]) return;
    CGPoint p = [t locationInView:self];
    if (hypot(p.x - self.start.x, p.y - self.start.y) > (atomic_load(&g_pointer_locked) ? 0 : 8)) self.moved = YES;
    if (!self.moved) return;
    double sens = atomic_load(&g_pointer_locked) ? 1.6 * g_sens : 1.0;   // look speed in gameplay
    int dx = (int)lround((p.x - self.last.x) * self.pxPerPt * sens), dy = (int)lround((p.y - self.last.y) * self.pxPerPt * sens);
    self.last = p;
    mouse_motion(self.hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, self.gw - 1), clampi(atomic_load(&g_cy) + dy, 0, self.gh - 1));
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    UITouch *t = self.tracking; if (!t || ![ts containsObject:t]) return;
    self.tracking = nil;
    if (atomic_load(&g_pointer_locked)) return;   // gameplay: touches only look around
    if (self.moved || CACurrentMediaTime() - self.downAt > 0.35) return;
    // A tap lands where the finger is: jump the cursor there, give the game a few frames to update the hovered
    // item (menus click the item under the cursor at that moment), then click.
    uint64_t hwnd = self.hwnd;
    int x, y; [self point:t x:&x y:&y];
    mouse_motion(hwnd, x - atomic_load(&g_cx), y - atomic_load(&g_cy), x, y);
    NSUInteger epoch = g_touch_epoch, tap = ++g_menu_tap;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (epoch != g_touch_epoch || tap != g_menu_tap || atomic_load(&g_pointer_locked) ||
            hwnd != atomic_load(&g_key_hwnd) || !hwnd || g_menu_enter_hwnd) return;
        g_menu_enter_hwnd = hwnd;
        touch_key(36, '\r', 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (epoch != g_touch_epoch || g_menu_enter_hwnd != hwnd) return;
            g_menu_enter_hwnd = 0;
            touch_key(36, '\r', 0);
        });
    });
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if (self.tracking && [ts containsObject:self.tracking]) self.tracking = nil;
}
@end

// ---------------- root view controller ----------------
static void relayout_all(void);
static void overlay_front(void);
@interface RTRootViewController : UIViewController @end
@implementation RTRootViewController
- (void)loadView { UIView *v = [UIView new]; v.backgroundColor = UIColor.blackColor; self.view = v; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersPointerLocked { return atomic_load(&g_pointer_locked); }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; relayout_all(); atomic_store(&g_iface_orient, (int)self.view.window.windowScene.interfaceOrientation); }
@end

UIViewController *cocoa_ios_root(void) {   // main thread
    if (!g_root) g_root = [RTRootViewController new];
    return g_root;
}

// Guest client rect -> the view: fill the screen at the rect's own aspect ratio (letterboxed), drawable = cw x ch.
static void layout_view(RTView *v) {
    CGRect b = g_root.view.bounds;
    if (b.size.width < 1 || b.size.height < 1 || v.gw < 1 || v.gh < 1) return;
    double k = fmin(b.size.width / v.gw, b.size.height / v.gh);   // points per guest pixel
    CGRect f = CGRectMake(floor((b.size.width - v.gw * k) / 2), floor((b.size.height - v.gh * k) / 2), v.gw * k, v.gh * k);
    v.frame = f;
    v.pxPerPt = 1.0 / k;
    v.contentScaleFactor = 1.0 / k;
    ((CAMetalLayer *)v.layer).contentsScale = 1.0 / k;
}
static void relayout_all(void) { for (RTView *v in g_views) layout_view(v); }

// ---------------- windows ----------------
void *cocoa_window_new(uint64_t hwnd, int x, int y, int cw, int ch, int titled, int resizable, int minimizable, const char *title) {
    __block void *res = NULL;
    on_main(^{
        UIViewController *root = cocoa_ios_root();
        (void)root.view;
        RTView *v = [[RTView alloc] initWithFrame:root.view.bounds];
        v.hwnd = hwnd; v.gx = x; v.gy = y; v.gw = cw; v.gh = ch; v.hidden = YES;
        if (!g_views) g_views = [NSMutableArray array];
        [g_views addObject:v];
        [root.view addSubview:v];
        overlay_front();
        layout_view(v);
        g_active = 1;
        res = (__bridge_retained void *)v;
    });
    return res;
}
void cocoa_window_free(void *p) {
    on_main(^{
        RTView *v = (__bridge_transfer RTView *)p;
        if (atomic_load(&g_key_hwnd) == v.hwnd) cancel_touch_input();
        [v removeFromSuperview]; [g_views removeObject:v];
        if (atomic_load(&g_key_hwnd) == v.hwnd) atomic_store(&g_key_hwnd, 0);
    });
}
void cocoa_window_show(void *p, int show, int activate) {
    on_main(^{
        RTView *v = (__bridge RTView *)p;
        v.hidden = !show;
        if (show) {
            [g_root.view bringSubviewToFront:v]; overlay_front();
            if (atomic_load(&g_key_hwnd) != v.hwnd) cancel_touch_input();
            atomic_store(&g_key_hwnd, v.hwnd);
            win_from_cocoa(v.hwnd, WM_ACTIVATE, 1, 0);
            win_from_cocoa(v.hwnd, WM_SETFOCUS, 0, 0);
        } else if (atomic_load(&g_key_hwnd) == v.hwnd) {
            cancel_touch_input();
        }
    });
}
void cocoa_window_minimize(void *p, int m) { (void)p; (void)m; }
void cocoa_window_zoom(void *p, int z) { (void)p; (void)z; }
void cocoa_window_state(void *p, int *mn, int *zm, int *vis) {
    __block int v = 1;
    on_main(^{ v = !((__bridge RTView *)p).hidden; });
    *mn = 0; *zm = 0; *vis = v;
}
void cocoa_window_set_style(void *p, int titled, int resizable, int minimizable) { (void)p; (void)titled; (void)resizable; (void)minimizable; }
void cocoa_window_set_client(void *p, int x, int y, int cw, int ch) {
    on_main(^{
        RTView *v = (__bridge RTView *)p;
        v.gx = x; v.gy = y; v.gw = cw; v.gh = ch;
        layout_view(v);
        rt_log("[cocoa] layout hwnd %llx guest %d,%d %dx%d -> view %.0fx%.0f pt, scale %.3f\n", (unsigned long long)v.hwnd, x, y, cw, ch,
               v.frame.size.width, v.frame.size.height, v.contentScaleFactor);
        win_from_cocoa(v.hwnd, WM_SIZE, 0, pack_pos(cw, ch));
    });
}
void cocoa_window_get_client(void *p, int *x, int *y, int *cw, int *ch) {
    __block int a, b, c, d;
    on_main(^{ RTView *v = (__bridge RTView *)p; a = v.gx; b = v.gy; c = v.gw; d = v.gh; });
    *x = a; *y = b; *cw = c; *ch = d;
}
void cocoa_window_set_title(void *p, const char *title) { (void)p; (void)title; }
void cocoa_window_activate(void *p) { cocoa_window_show(p, 1, 1); }
void *cocoa_window_layer(void *p) {
    __block void *l = NULL;
    on_main(^{ l = (__bridge void *)((__bridge RTView *)p).layer; });
    return l;
}
void cocoa_frame_insets(int titled, int resizable, int *l, int *t, int *r, int *b) { (void)titled; (void)resizable; *l = *t = *r = *b = 0; }
void cocoa_set_virtual_screen(int w, int h) { g_vw = w; g_vh = h; }   // the view letterboxes any size onto the screen

void cocoa_pump(int wait_ms) {
    if (![NSThread isMainThread]) return;
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, wait_ms > 0 ? wait_ms / 1000.0 : 0, true);
}

// ---------------- cursor ----------------
void cocoa_cursor_pos(int *x, int *y) { *x = atomic_load(&g_cx); *y = atomic_load(&g_cy); }
void cocoa_set_cursor_pos(int x, int y) { atomic_store(&g_cx, x); atomic_store(&g_cy, y); }
void cocoa_cursor_visible(int v) {
    int previous = atomic_exchange(&g_pointer_locked, !v);
    rt_log("[cocoa] mouse capture %s\n", v ? "off" : "on");
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_root setNeedsUpdateOfPrefersPointerLocked];
        if (previous != !v) cancel_touch_input();
        update_touch_controls();
    });
}
void cocoa_mouse_delta(int *dx, int *dy) { *dx = atomic_exchange(&g_dx, 0); *dy = atomic_exchange(&g_dy, 0); }

// ---------------- dialogs ----------------
char *cocoa_choose_folder(const char *message) { (void)message; return NULL; }   // the game folder is fixed (boot_ios.m)

static UIViewController *top_vc(void) {
    UIViewController *t = g_root;
    while (t.presentedViewController) t = t.presentedViewController;
    return t;
}
// Blocks the calling (guest) thread until dismissed; from the main thread it returns at once.
void cocoa_alert(const char *title, const char *text) {
    NSString *t = [NSString stringWithUTF8String:title ?: ""], *x = [NSString stringWithUTF8String:text ?: ""];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    BOOL wait = ![NSThread isMainThread];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:x preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *act) { dispatch_semaphore_signal(sem); }]];
        [top_vc() presentViewController:a animated:YES completion:nil];
    });
    if (wait) dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
}
void cocoa_pick_friends(int n, const char *const *names, const char *const *details,
                        void (*done)(const int *picked, int npicked, void *ctx), void *ctx) {
    (void)n; (void)names; (void)details;
    dispatch_async(dispatch_get_main_queue(), ^{ done(NULL, 0, ctx); });   // no Steam overlay here
}
void cocoa_log_layer(void *p) {
    CAMetalLayer *l = (__bridge CAMetalLayer *)p;
    rt_log("[cocoa] layer bounds %.0fx%.0f pt, contentsScale %.3f, drawableSize %.0fx%.0f\n", l.bounds.size.width, l.bounds.size.height,
           l.contentsScale, l.drawableSize.width, l.drawableSize.height);
}

// ---------------- keyboard ----------------
// HID usage page 7 -> macOS virtual key code (window.c's key table is keyed by those).
static const uint8_t hid_to_mac[232] = {
    [0x04]=0,[0x05]=11,[0x06]=8,[0x07]=2,[0x08]=14,[0x09]=3,[0x0A]=5,[0x0B]=4,[0x0C]=34,[0x0D]=38,[0x0E]=40,[0x0F]=37,[0x10]=46,
    [0x11]=45,[0x12]=31,[0x13]=35,[0x14]=12,[0x15]=15,[0x16]=1,[0x17]=17,[0x18]=32,[0x19]=9,[0x1A]=13,[0x1B]=7,[0x1C]=16,[0x1D]=6,
    [0x1E]=18,[0x1F]=19,[0x20]=20,[0x21]=21,[0x22]=23,[0x23]=22,[0x24]=26,[0x25]=28,[0x26]=25,[0x27]=29,
    [0x28]=36,[0x29]=53,[0x2A]=51,[0x2B]=48,[0x2C]=49,[0x2D]=27,[0x2E]=24,[0x2F]=33,[0x30]=30,[0x31]=42,[0x33]=41,[0x34]=39,[0x35]=50,
    [0x36]=43,[0x37]=47,[0x38]=44,[0x39]=57,
    [0x3A]=122,[0x3B]=120,[0x3C]=99,[0x3D]=118,[0x3E]=96,[0x3F]=97,[0x40]=98,[0x41]=100,[0x42]=101,[0x43]=109,[0x44]=103,[0x45]=111,
    [0x49]=114,[0x4A]=115,[0x4B]=116,[0x4C]=117,[0x4D]=119,[0x4E]=121,[0x4F]=124,[0x50]=123,[0x51]=125,[0x52]=126,
    [0xE0]=59,[0xE1]=56,[0xE2]=58,[0xE3]=55,[0xE4]=62,[0xE5]=60,[0xE6]=61,[0xE7]=54,
};
static char hid_char(int u, int shift) {
    if (u >= 0x04 && u <= 0x1D) return (char)((shift ? 'A' : 'a') + u - 4);
    if (u >= 0x1E && u <= 0x27) return shift ? ")!@#$%^&*("[(u - 0x1E + 1) % 10] : "1234567890"[u - 0x1E];
    switch (u) {
    case 0x28: return '\r'; case 0x29: return 0x1B; case 0x2A: return 0x7F; case 0x2B: return '\t'; case 0x2C: return ' ';
    case 0x2D: return shift ? '_' : '-'; case 0x2E: return shift ? '+' : '='; case 0x2F: return shift ? '{' : '[';
    case 0x30: return shift ? '}' : ']'; case 0x31: return shift ? '|' : '\\'; case 0x33: return shift ? ':' : ';';
    case 0x34: return shift ? '"' : '\''; case 0x35: return shift ? '~' : '`'; case 0x36: return shift ? '<' : ',';
    case 0x37: return shift ? '>' : '.'; case 0x38: return shift ? '?' : '/';
    }
    return 0;
}
static _Atomic int g_shift;
static void key_event(int usage, int down) {
    if (usage < 0 || usage >= 232 || !(hid_to_mac[usage] || usage == 4)) return;
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (!hwnd) return;
    if (usage == 0xE1 || usage == 0xE5) atomic_store(&g_shift, down);
    uint16_t ch[1]; int n = 0;
    char c = hid_char(usage, atomic_load(&g_shift));
    if (c && down) ch[n++] = (uint16_t)(unsigned char)c;
    win_key_from_cocoa(hwnd, hid_to_mac[usage], down, 0, ch, n);
}

static void attach_keyboard(GCKeyboard *kb) {
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) { key_event((int)code, pressed); };
}
static void attach_mouse(GCMouse *m) {
    m.mouseInput.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
        uint64_t hwnd = atomic_load(&g_key_hwnd);
        int w = 1, h = 1; for (RTView *v in g_views) if (v.hwnd == hwnd) { w = v.gw; h = v.gh; }
        int ix = (int)lround(dx), iy = (int)lround(-dy);   // GameController's y is up
        mouse_motion(hwnd, ix, iy, clampi(atomic_load(&g_cx) + ix, 0, w - 1), clampi(atomic_load(&g_cy) + iy, 0, h - 1));
    };
    m.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 1, p); };
    m.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 2, p); };
    m.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL p) { mouse_button(atomic_load(&g_key_hwnd), 4, p); };
    m.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput *a, float v) {
        int d = (int)lround(v * 120);
        if (!d) return;
        di_mouse_wheel(d);
        win_from_cocoa(atomic_load(&g_key_hwnd), WM_MOUSEWHEEL, mk_flags() | (uint64_t)(uint16_t)(int16_t)d << 16, pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
    };
}


// ---------------- touch overlay ----------------

// The menu Enter button and the delayed menu tap can hold the same key.
// Likewise ALT FIRE can hold primary fire while another finger uses FIRE.
static unsigned g_touch_keys[128], g_touch_mouse[5];
static CGFloat g_touch_target = 44, g_stick_float = 8;  // main thread, updated with the layout

static void touch_key(int mac, uint16_t ch, int down) {
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (!hwnd) return;
    unsigned *count = &g_touch_keys[mac];
    BOOL changed = down ? (*count)++ == 0 : (*count && --*count == 0);
    if (changed) win_key_from_cocoa(hwnd, (uint16_t)mac, down, 0, down && ch ? &ch : NULL, down && ch ? 1 : 0);
}

static void touch_mouse(int button, int down) {
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    if (!hwnd) return;
    unsigned *count = &g_touch_mouse[button];
    if (down ? (*count)++ == 0 : (*count && --*count == 0)) mouse_button(hwnd, button, down);
}

typedef enum { ACT_KEY, ACT_MOUSE, ACT_WHEEL, ACT_CUSTOM } ActKind;
@interface RTActionButton : UIButton
@property ActKind kind;
@property int code, arg;
@property uint16_t character;
- (void)pressed;
- (void)released;
- (void)cancelInput;
- (void)updateTitle;
@end

static CGFloat bounded(CGFloat value, CGFloat lower, CGFloat upper) {
    return fmax(lower, fmin(value, upper));
}

static CGRect touch_bounds(CGRect frame, CGFloat minimum) {
    return CGRectInset(frame, -fmax(0, minimum - frame.size.width) / 2,
                             -fmax(0, minimum - frame.size.height) / 2);
}

@implementation RTActionButton {
    BOOL _held, _armed, _pulsePrimary, _pulseSecondary;
    NSUInteger _sequence;
}

@synthesize kind = _kind, code = _code, arg = _arg, character = _character;
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)event {
    return CGRectContainsPoint(touch_bounds(self.bounds, g_touch_target), p);
}

- (BOOL)isSecondary { return self.kind == ACT_MOUSE && self.code == 2; }

- (void)setArmed:(BOOL)armed {
    _armed = armed;
    self.layer.borderColor = (armed ? UIColor.systemOrangeColor : [UIColor colorWithWhite:1 alpha:0.45]).CGColor;
}

- (void)updateTitle {
    if (self.kind != ACT_CUSTOM) return;
    NSString *title = self.code == 0
        ? [NSString stringWithFormat:@"SENS\n%.2gx", atomic_load(&g_sens)]
        : (atomic_load(&g_gyro_on) ? @"GYRO\nON" : @"GYRO\nOFF");
    [self setTitle:title forState:UIControlStateNormal];
}

- (void)pressed {
    if (_held || _pulseSecondary || !g_touch_active || g_touch_editing || g_touch_hidden ||
        !atomic_load(&g_key_hwnd)) return;
    _held = YES;
    if (self.kind == ACT_KEY) touch_key(self.code, self.character, 1);
    if (self.kind == ACT_MOUSE) touch_mouse(self.code, 1);
    if (self.kind == ACT_WHEEL) {
        di_mouse_wheel(self.arg);
        win_from_cocoa(atomic_load(&g_key_hwnd), WM_MOUSEWHEEL,
                       mk_flags() | (uint64_t)(uint16_t)(int16_t)self.arg << 16,
                       pack_pos(atomic_load(&g_cx), atomic_load(&g_cy)));
    }
    if (self.isSecondary) {
        NSUInteger sequence = ++_sequence;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (sequence == self->_sequence && self->_held) [self setArmed:YES];
        });
    }
}

- (void)cancelInput {
    _sequence++;
    [self setArmed:NO];
    if (_held && self.kind == ACT_KEY) touch_key(self.code, self.character, 0);
    if (_held && self.kind == ACT_MOUSE) touch_mouse(self.code, 0);
    if (_pulsePrimary) touch_mouse(1, 0);
    if (_pulseSecondary) touch_mouse(2, 0);
    _held = _pulsePrimary = _pulseSecondary = NO;
}

// Releasing an armed ALT FIRE performs the existing primary/secondary sequence.
// Cancellation only releases buttons. Old callbacks cannot affect a new touch.
- (void)released {
    if (!_held) return;
    if (self.isSecondary && _armed) {
        NSUInteger sequence = ++_sequence;
        _held = NO;
        [self setArmed:NO];
        _pulsePrimary = _pulseSecondary = YES;
        touch_mouse(1, 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (sequence != self->_sequence) return;
            self->_pulsePrimary = NO;
            touch_mouse(1, 0);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 160 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (sequence != self->_sequence) return;
            self->_pulseSecondary = NO;
            touch_mouse(2, 0);
        });
        return;
    }
    if (self.kind == ACT_CUSTOM) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (self.code == 0) {
            double current = atomic_load(&g_sens);
            NSUInteger count = sizeof kSensSteps / sizeof *kSensSteps, index = 0;
            while (index < count && kSensSteps[index] <= current) index++;
            double next = kSensSteps[index % count];
            atomic_store(&g_sens, next);
            [defaults setDouble:next forKey:@"sens"];
        } else {
            BOOL enabled = !atomic_load(&g_gyro_on);
            atomic_store(&g_gyro_on, enabled);
            [defaults setBool:enabled forKey:@"gyro"];
        }
        [self updateTitle];
    }
    [self cancelInput];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (!_held || !(self.kind == ACT_MOUSE || (self.kind == ACT_KEY && self.code == 12))) return;
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:g_root.view], q = [touch previousLocationInView:g_root.view];
    uint64_t hwnd = atomic_load(&g_key_hwnd);
    double scale = 1.6 * atomic_load(&g_sens);
    for (RTView *view in g_views) if (view.hwnd == hwnd) scale *= view.pxPerPt;
    int dx = (int)lround((p.x - q.x) * scale), dy = (int)lround((p.y - q.y) * scale);
    if (dx || dy) mouse_motion(hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, 4095),
                                            clampi(atomic_load(&g_cy) + dy, 0, 4095));
}
@end

@interface RTStick : UIView
@property(nonatomic, strong) UIView *knob;
@property(nonatomic) int dirs;
- (void)updateFromOffset:(CGPoint)offset;
@end

@implementation RTStick
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat diameter = self.bounds.size.width;
    self.layer.cornerRadius = diameter / 2;
    CGFloat size = diameter * 0.4;
    self.knob.bounds = CGRectMake(0, 0, size, size);
    self.knob.layer.cornerRadius = size / 2;
    self.knob.center = CGPointMake(diameter / 2, diameter / 2);
}

- (void)setDirs:(int)dirs {
    static const int mac[] = { 13, 0, 1, 2 };   // W A S D
    for (int i = 0; i < 4; i++) {
        if ((dirs ^ _dirs) & (1 << i)) touch_key(mac[i], 0, !!(dirs & (1 << i)));
    }
    _dirs = dirs;
}

- (void)updateFromOffset:(CGPoint)offset {
    CGFloat radius = self.bounds.size.width / 2;
    if (radius <= 0) return;
    CGFloat x = offset.x / radius, y = offset.y / radius, length = hypot(x, y);
    if (length > 1) { x /= length; y /= length; }
    CGFloat travel = radius - self.knob.bounds.size.width / 2;
    self.knob.center = CGPointMake(radius + x * travel, radius + y * travel);
    self.dirs = (y < -0.38 ? 1 : 0) | (x < -0.38 ? 2 : 0) | (y > 0.38 ? 4 : 0) | (x > 0.38 ? 8 : 0);
}
@end

typedef struct {
    const char *identifier, *title;
    ActKind kind;
    int code, arg;
    uint16_t character;
    CGFloat width, height;
    BOOL menu;
} RTTouchControl;

static const RTTouchControl kTouchControls[] = {
    {"escape", "Esc", ACT_KEY, 53, 0, 0x1B, 22, 18, YES},
    {"enter", "Enter", ACT_KEY, 36, 0, '\r', 22, 18, YES},
    {"space", "Space", ACT_KEY, 49, 0, ' ', 22, 18, YES},
    {"tab", "Tab", ACT_KEY, 48, 0, '\t', 22, 18, YES},
    {"left", "◀", ACT_KEY, 123, 0, 0, 22, 18, YES},
    {"up", "▲", ACT_KEY, 126, 0, 0, 22, 18, YES},
    {"down", "▼", ACT_KEY, 125, 0, 0, 22, 18, YES},
    {"right", "▶", ACT_KEY, 124, 0, 0, 22, 18, YES},
    {"yes", "Y", ACT_KEY, 16, 0, 'y', 22, 18, YES},
    {"no", "N", ACT_KEY, 45, 0, 'n', 22, 18, YES},
    {"fire", "FIRE", ACT_MOUSE, 1, 0, 0, 52, 52, NO},
    {"jump", "JUMP", ACT_KEY, 49, 0, 0, 37, 37, NO},
    {"use", "USE", ACT_KEY, 14, 0, 0, 29, 29, NO},
    {"melee", "MELEE", ACT_KEY, 3, 0, 0, 29, 29, NO},
    {"altFire", "ALT\nFIRE", ACT_MOUSE, 2, 0, 0, 33, 33, NO},
    {"useEquipment", "USE\nEQUIP", ACT_MOUSE, 4, 0, 0, 33, 33, NO},
    {"chainsaw", "CHAIN\nSAW", ACT_KEY, 5, 0, 0, 29, 29, NO},
    {"swap", "SWAP\nWHEEL", ACT_KEY, 12, 0, 0, 29, 29, NO},
    {"nextEquipment", "NEXT\nEQUIP", ACT_KEY, 122, 0, 0, 29, 29, NO},
    {"weaponUp", "WPN\n▲", ACT_WHEEL, 0, 120, 0, 26, 26, NO},
    {"weaponDown", "WPN\n▼", ACT_WHEEL, 0, -120, 0, 26, 26, NO},
    {"sensitivity", "SENS", ACT_CUSTOM, 0, 0, 0, 26, 26, NO},
    {"gyro", "GYRO", ACT_CUSTOM, 1, 0, 0, 26, 26, NO},
};
enum { kMenuCount = 10, kStickIndex = sizeof kTouchControls / sizeof *kTouchControls, kControlCount };
static NSString *const kTouchDefaultsKey = @"touchLayout";
static const CGFloat kDefaultOpacity = 0.82, kMinimumOpacity = 0.05;

static NSString *control_id(NSUInteger index) {
    return index == kStickIndex ? @"movement" : [NSString stringWithUTF8String:kTouchControls[index].identifier];
}

static CGRect control_hit_frame(NSUInteger index, CGRect frame) {
    // Include every position the floating base can occupy.
    return index == kStickIndex ? CGRectInset(frame, -g_stick_float, -g_stick_float) : touch_bounds(frame, g_touch_target);
}

static CGRect fitted_control_frame(NSUInteger index, CGPoint center, CGSize size,
                                   CGRect area, BOOL fitHitTarget) {
    CGRect frame = CGRectMake(center.x - size.width / 2, center.y - size.height / 2, size.width, size.height);
    CGRect limit = fitHitTarget ? control_hit_frame(index, frame) : frame;
    if (limit.size.width > area.size.width || limit.size.height > area.size.height) return CGRectNull;
    frame.origin.x += bounded(limit.origin.x, CGRectGetMinX(area), CGRectGetMaxX(area) - limit.size.width) - limit.origin.x;
    frame.origin.y += bounded(limit.origin.y, CGRectGetMinY(area), CGRectGetMaxY(area) - limit.size.height) - limit.origin.y;
    return frame;
}

@interface RTControlsView : UIView
@property(nonatomic, strong) NSArray<RTActionButton *> *buttons;
@property(nonatomic, strong) RTStick *stick;
@property(nonatomic, strong) UIButton *editButton, *visibilityButton, *resetButton, *controlPicker;
@property(nonatomic, strong) UISlider *opacitySlider;
@property(nonatomic, strong) UIView *selectionBorder, *resizeHandle;
@property(nonatomic, strong) UILabel *moveHandle;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *positions;
@property(nonatomic) CGFloat opacity;
- (void)refresh;
- (void)cancelInput;
- (void)selectControl:(NSUInteger)index;
@end

@implementation RTControlsView {
    CGRect _frames[kControlCount];
    CGRect _area, _defaultArea, _handleArea;
    NSInteger _selected;
    __weak UITouch *_editorTouch, *_stickTouch;
    CGPoint _start, _stickOrigin;
    CGRect _initialFrame;
    BOOL _resizing;
    CGFloat _scale;
}

static UIButton *toolbar_button(NSString *title) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.exclusiveTouch = NO;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.75];
    button.layer.cornerRadius = 10;
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.multipleTouchEnabled = YES;
    _selected = -1;
    _opacity = kDefaultOpacity;
    _positions = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kTouchDefaultsKey];
    if ([saved[@"version"] isEqual:@1] || [saved[@"version"] isEqual:@2]) {
        NSDictionary *positions = saved[@"positions"];
        if ([positions isKindOfClass:NSDictionary.class]) [_positions addEntriesFromDictionary:positions];
        NSNumber *opacity = saved[@"opacity"], *hidden = saved[@"hidden"];
        if ([opacity isKindOfClass:NSNumber.class] && isfinite(opacity.doubleValue))
            _opacity = bounded(opacity.doubleValue, kMinimumOpacity, 1);
        if ([hidden isKindOfClass:NSNumber.class]) g_touch_hidden = hidden.boolValue;
    }
    NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:kStickIndex];
    for (NSUInteger i = 0; i < kStickIndex; i++) {
        const RTTouchControl *control = &kTouchControls[i];
        RTActionButton *button = [[RTActionButton alloc] initWithFrame:CGRectZero];
        button.exclusiveTouch = NO;
        button.kind = control->kind;
        button.code = control->code;
        button.arg = control->arg;
        button.character = control->character;
        [button setTitle:[NSString stringWithUTF8String:control->title] forState:UIControlStateNormal];
        [button updateTitle];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [button setTitleColor:[UIColor colorWithRed:1 green:0.74 blue:0.47 alpha:1] forState:UIControlStateHighlighted];
        button.titleLabel.numberOfLines = 2;
        button.titleLabel.textAlignment = NSTextAlignmentCenter;
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.65;
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
        [button addTarget:button action:@selector(pressed) forControlEvents:UIControlEventTouchDown];
        [button addTarget:button action:@selector(released) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:button action:@selector(cancelInput) forControlEvents:UIControlEventTouchCancel | UIControlEventTouchUpOutside];
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.buttons = buttons;
    self.stick = [RTStick new];
    self.stick.userInteractionEnabled = NO;
    self.stick.layer.borderWidth = 1.5;
    self.stick.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
    self.stick.knob = [UIView new];
    [self.stick addSubview:self.stick.knob];
    [self addSubview:self.stick];

    self.selectionBorder = [UIView new];
    self.selectionBorder.userInteractionEnabled = NO;
    self.selectionBorder.layer.borderWidth = 1.5;
    self.selectionBorder.layer.borderColor = UIColor.systemOrangeColor.CGColor;
    self.selectionBorder.layer.cornerRadius = 7;
    [self addSubview:self.selectionBorder];
    self.resizeHandle = [UIView new];
    self.resizeHandle.userInteractionEnabled = NO;
    self.resizeHandle.backgroundColor = UIColor.systemOrangeColor;
    self.resizeHandle.layer.cornerRadius = 5;
    [self addSubview:self.resizeHandle];

    self.moveHandle = [UILabel new];
    self.moveHandle.text = @"↔";
    self.moveHandle.textAlignment = NSTextAlignmentCenter;
    self.moveHandle.textColor = UIColor.blackColor;
    self.moveHandle.backgroundColor = UIColor.systemOrangeColor;
    self.moveHandle.layer.cornerRadius = 13;
    self.moveHandle.clipsToBounds = YES;
    self.moveHandle.userInteractionEnabled = NO;
    [self addSubview:self.moveHandle];

    self.controlPicker = toolbar_button(@"CONTROLLI");
    self.controlPicker.showsMenuAsPrimaryAction = YES;
    NSMutableArray<UIAction *> *choices = [NSMutableArray arrayWithCapacity:kControlCount];
    __weak RTControlsView *weakSelf = self;
    for (NSUInteger i = 0; i < kControlCount; i++) {
        NSString *title = i == kStickIndex ? @"Joystick" :
            [[NSString stringWithUTF8String:kTouchControls[i].title] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [choices addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *action) {
            [weakSelf selectControl:i];
        }]];
    }
    self.controlPicker.menu = [UIMenu menuWithTitle:@"" children:choices];

    self.editButton = toolbar_button(@"EDIT");
    self.visibilityButton = toolbar_button(@"NASCONDI");
    self.resetButton = toolbar_button(@"RESET");
    [self.editButton addTarget:self action:@selector(toggleEditing) forControlEvents:UIControlEventTouchUpInside];
    [self.visibilityButton addTarget:self action:@selector(toggleVisibility) forControlEvents:UIControlEventTouchUpInside];
    [self.resetButton addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    self.opacitySlider = [UISlider new];
    self.opacitySlider.minimumValue = kMinimumOpacity;
    self.opacitySlider.maximumValue = 1;
    self.opacitySlider.value = self.opacity;
    self.opacitySlider.accessibilityLabel = @"Opacità";
    self.opacitySlider.minimumTrackTintColor = UIColor.systemOrangeColor;
    [self.opacitySlider addTarget:self action:@selector(changeOpacity) forControlEvents:UIControlEventValueChanged];
    for (UIView *view in @[self.editButton, self.visibilityButton, self.resetButton, self.controlPicker, self.opacitySlider])
        [self addSubview:view];
    [self refresh];
    return self;
}

- (void)savePreferences {
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"version": @2, @"positions": self.positions, @"opacity": @(self.opacity), @"hidden": @(g_touch_hidden)
    } forKey:kTouchDefaultsKey];
}

- (void)toggleEditing {
    atomic_store(&g_touch_gyro_active, NO);
    cancel_touch_input();
    g_touch_editing = !g_touch_editing;
    _selected = -1;
    [self refresh];
}

- (void)toggleVisibility {
    atomic_store(&g_touch_gyro_active, NO);
    cancel_touch_input();
    g_touch_hidden = !g_touch_hidden;
    g_touch_editing = NO;
    _selected = -1;
    [self savePreferences];
    [self refresh];
}

- (void)resetLayout {
    [self cancelInput];
    [self.positions removeAllObjects];
    _selected = -1;
    self.opacity = kDefaultOpacity;
    self.opacitySlider.value = self.opacity;
    [self savePreferences];
    [self refresh];
}

- (void)selectControl:(NSUInteger)index {
    if (!g_touch_editing || !g_touch_active || _editorTouch) return;
    _selected = index;
    [self applyFrames];
}

- (void)changeOpacity {
    self.opacity = self.opacitySlider.value;
    [self savePreferences];
    [self refresh];
}

- (void)refresh {
    BOOL gameplay = atomic_load(&g_pointer_locked);
    for (NSUInteger i = 0; i < self.buttons.count; i++) {
        RTActionButton *button = self.buttons[i];
        button.hidden = g_touch_hidden || (!g_touch_editing && !gameplay && !kTouchControls[i].menu);
        button.userInteractionEnabled = !g_touch_editing && g_touch_active;
        button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.85];
        button.layer.opacity = self.opacity;
    }
    self.stick.hidden = g_touch_hidden || (!gameplay && !g_touch_editing);
    self.stick.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.75];
    self.stick.knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.76];
    self.stick.layer.opacity = self.opacity;
    self.editButton.hidden = g_touch_hidden;
    self.resetButton.hidden = self.opacitySlider.hidden = self.controlPicker.hidden = !g_touch_editing;
    [self.editButton setTitle:g_touch_editing ? @"DONE" : @"EDIT" forState:UIControlStateNormal];
    [self.visibilityButton setTitle:g_touch_hidden ? @"MOSTRA" : @"NASCONDI" forState:UIControlStateNormal];
    self.visibilityButton.alpha = g_touch_hidden ? 0.72 : 1;
    atomic_store(&g_touch_gyro_active, g_touch_active && gameplay && !g_touch_hidden && !g_touch_editing);
    [self setNeedsLayout];
}

- (CGSize)controlSize:(NSUInteger)index {
    return index == kStickIndex ? CGSizeMake(75 * _scale, 75 * _scale)
        : CGSizeMake(kTouchControls[index].width * _scale, kTouchControls[index].height * _scale);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = self.safeAreaLayoutGuide.layoutFrame;
    CGFloat left = CGRectGetMinX(safe), top = CGRectGetMinY(safe), right = CGRectGetMaxX(safe);
    self.visibilityButton.frame = CGRectMake(right - 78, top, 78, 44);
    self.editButton.frame = CGRectMake(right - 136, top, 54, 44);
    self.resetButton.frame = CGRectMake(left, top, 62, 44);
    self.controlPicker.frame = CGRectMake(left + 66, top, 80, 44);
    CGFloat sliderWidth = fmin(155, safe.size.width - 292);
    self.opacitySlider.frame = sliderWidth >= 44 ? CGRectMake(left + 152, top, sliderWidth, 44)
        : CGRectMake(left, top + 44, fmin(155, safe.size.width), 44);
    _handleArea = UIEdgeInsetsInsetRect(safe, UIEdgeInsetsMake(sliderWidth >= 44 ? 48 : 92, 0, 0, 0));

    CGRect area = UIEdgeInsetsInsetRect(safe, UIEdgeInsetsMake(48, 4, 4, 4));
    if (area.size.width <= 0 || area.size.height <= 0) return;
    if (!CGRectEqualToRect(_area, self.bounds) || !CGRectEqualToRect(_defaultArea, area)) {
        _area = self.bounds;
        _defaultArea = area;
        cancel_touch_input();
    } else if (_editorTouch) {
        return;   // a toolbar update must not reset the frame being dragged
    }
    BOOL compact = area.size.width < 470 || area.size.height < 244;
    _scale = compact ? fmin(1, fmin(area.size.width / 540, area.size.height / 160))
                     : fmin(1, fmin(area.size.width / 490, area.size.height / 302));
    g_touch_target = compact ? 44 * _scale : 44;
    g_stick_float = 8 * _scale;
    for (NSUInteger i = 0; i < kControlCount; i++) {
        CGPoint center;
        if (compact) {
            CGFloat stickColumn = 104 * _scale;
            if (i == kStickIndex) {
                center = CGPointMake(CGRectGetMinX(area) + stickColumn / 2,
                                     CGRectGetMaxY(area) - 52 * _scale);
            } else {
                CGFloat column = (area.size.width - stickColumn) / 8;
                center = CGPointMake(CGRectGetMinX(area) + stickColumn + (i % 8 + 0.5) * column,
                                     CGRectGetMinY(area) + (i / 8 + 0.5) * area.size.height / 3);
            }
        } else if (i < kMenuCount) {
            center = CGPointMake(CGRectGetMinX(area) + 22 + (area.size.width - 44) * i / (kMenuCount - 1),
                                 CGRectGetMinY(area) + 22);
        } else if (i == kStickIndex) {
            center = CGPointMake(CGRectGetMinX(area) + 66 * _scale, CGRectGetMaxY(area) - 65 * _scale);
        } else {
            NSUInteger slot = i - kMenuCount;
            CGFloat step = fmax(47, 58 * _scale);
            center = CGPointMake(CGRectGetMaxX(area) - 31 - step * (slot % 4),
                                 CGRectGetMaxY(area) - 28 - (slot / 4) * step);
        }
        CGSize size = [self controlSize:i];
        _frames[i] = fitted_control_frame(i, center, size, area, YES);
        if (CGRectIsNull(_frames[i])) _frames[i] = fitted_control_frame(i, center, size, _area, NO);
        NSArray *entry = self.positions[control_id(i)];
        if (![entry isKindOfClass:NSArray.class] || (entry.count != 3 && entry.count != 4) ||
            ![entry[0] isKindOfClass:NSNumber.class] || ![entry[1] isKindOfClass:NSNumber.class] ||
            ![entry[2] isKindOfClass:NSNumber.class]) continue;
        double x = [entry[0] doubleValue], y = [entry[1] doubleValue], factor = [entry[2] doubleValue];
        if (!isfinite(x) || !isfinite(y) || !isfinite(factor)) continue;
        // Three-value entries retain their legacy safe-area coordinates until edited.
        BOOL legacy = entry.count == 3;
        CGRect reference = legacy ? area : _area;
        center = CGPointMake(CGRectGetMinX(reference) + bounded(x, 0, 1) * reference.size.width,
                             CGRectGetMinY(reference) + bounded(y, 0, 1) * reference.size.height);
        factor = bounded(factor, 0.8, 2.5);
        CGRect saved = fitted_control_frame(i, center, CGSizeMake(size.width * factor, size.height * factor),
                                           reference, legacy);
        if (!CGRectIsNull(saved)) _frames[i] = saved;
    }
    [self applyFrames];
}

- (void)applyFrames {
    for (NSUInteger i = 0; i < self.buttons.count; i++) {
        RTActionButton *button = self.buttons[i];
        CGRect frame = _frames[i];
        button.frame = frame;
        button.layer.cornerRadius = kTouchControls[i].menu ? fmin(8, frame.size.height / 3) : frame.size.width / 2;
        button.titleLabel.font = [UIFont boldSystemFontOfSize:bounded(frame.size.width * 0.29, 7, 17)];
    }
    if (!_stickTouch) self.stick.frame = _frames[kStickIndex];
    BOOL selected = g_touch_editing && _selected >= 0;
    self.selectionBorder.hidden = self.resizeHandle.hidden = self.moveHandle.hidden = !selected;
    if (selected) {
        CGRect frame = _frames[_selected];
        self.selectionBorder.frame = CGRectIntersection(control_hit_frame(_selected, frame), _area);
        CGFloat maxX = CGRectGetMaxX(_handleArea), maxY = CGRectGetMaxY(_handleArea);
        CGFloat minX = CGRectGetMinX(_handleArea), minY = CGRectGetMinY(_handleArea);
        CGFloat x = bounded(CGRectGetMaxX(frame) - 5, minX + 8, maxX - 8);
        CGFloat y = bounded(CGRectGetMaxY(frame) - 5, minY + 8, maxY - 8);
        self.resizeHandle.frame = CGRectMake(x - 5, y - 5, 10, 10);
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        self.moveHandle.hidden = CGRectContainsPoint(CGRectInset(_handleArea, 13, 13), center);
        if (!self.moveHandle.hidden) {
            CGFloat moveX = bounded(center.x, minX + 13, maxX - 13);
            CGFloat moveY = bounded(center.y, minY + 13, maxY - 13);
            if (fabs(moveX - x) < 26 && fabs(moveY - y) < 26)
                moveY = y < CGRectGetMidY(_handleArea) ? y + 27 : y - 27;
            self.moveHandle.frame = CGRectMake(moveX - 13, moveY - 13, 26, 26);
        }
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *target = [super hitTest:point withEvent:event];
    if ([target isKindOfClass:RTActionButton.class] && ((RTActionButton *)target).tracking) {
        // A second finger can reach the next button in the stack. UIKit keeps the
        // first finger bound to its original view for the lifetime of that touch.
        target = self;
        for (RTActionButton *button in self.buttons.reverseObjectEnumerator) {
            if (button.tracking) continue;
            UIView *hit = [button hitTest:[self convertPoint:point toView:button] withEvent:event];
            if (hit) return hit;
        }
    }
    if (target != self) return target;
    if (g_touch_editing) return self;
    // Toolbar and unoccupied buttons take priority over the joystick.
    return !_stickTouch && !self.stick.hidden && g_touch_active &&
           CGRectContainsPoint(control_hit_frame(kStickIndex, _frames[kStickIndex]), point) ? self : nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!g_touch_active || g_touch_hidden) return;
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:self];
    if (g_touch_editing) {
        if (_editorTouch) return;
        _resizing = _selected >= 0 && CGRectContainsPoint(CGRectInset(self.resizeHandle.frame, -6, -6), point);
        BOOL move = !self.moveHandle.hidden && CGRectContainsPoint(self.moveHandle.frame, point);
        if (!_resizing && !move &&
            (_selected < 0 || !CGRectContainsPoint(control_hit_frame(_selected, _frames[_selected]), point))) {
            _selected = -1;
            // Match gameplay: buttons use their front-to-back UIKit order, then the joystick.
            for (NSInteger i = kStickIndex - 1; i >= 0; i--) {
                if (CGRectContainsPoint(control_hit_frame(i, _frames[i]), point)) { _selected = i; break; }
            }
            if (_selected < 0 && CGRectContainsPoint(control_hit_frame(kStickIndex, _frames[kStickIndex]), point))
                _selected = kStickIndex;
        }
        [self applyFrames];
        if (_selected < 0) return;
        _editorTouch = touch;
        _start = point;
        _initialFrame = _frames[_selected];
        return;
    }
    if (_stickTouch || self.stick.hidden || !atomic_load(&g_key_hwnd)) return;
    CGRect frame = _frames[kStickIndex];
    CGFloat x = CGRectGetMidX(frame), y = CGRectGetMidY(frame);
    CGFloat half = frame.size.width / 2;
    self.stick.center = CGPointMake(bounded(bounded(point.x, x - g_stick_float, x + g_stick_float),
                                           CGRectGetMinX(_area) + half, CGRectGetMaxX(_area) - half),
                                    bounded(bounded(point.y, y - g_stick_float, y + g_stick_float),
                                           CGRectGetMinY(_area) + half, CGRectGetMaxY(_area) - half));
    _stickOrigin = point;
    _stickTouch = touch;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_editorTouch && [touches containsObject:_editorTouch]) {
        CGPoint point = [_editorTouch locationInView:self];
        CGFloat dx = point.x - _start.x, dy = point.y - _start.y;
        CGPoint center = CGPointMake(CGRectGetMidX(_initialFrame), CGRectGetMidY(_initialFrame));
        CGSize size = _initialFrame.size;
        CGSize base = [self controlSize:_selected];
        if (_resizing) {
            // Project the drag onto the lower-right corner's direction of travel.
            CGFloat factor = size.width / base.width;
            factor += 2 * (dx * base.width + dy * base.height) /
                      (base.width * base.width + base.height * base.height);
            factor = bounded(factor, 0.8, 2.5);
            size = CGSizeMake(base.width * factor, base.height * factor);
        } else {
            center.x += dx;
            center.y += dy;
        }
        CGRect next = fitted_control_frame(_selected, center, size, _area, NO);
        if (!CGRectIsNull(next)) {
            _frames[_selected] = next;
            [self applyFrames];
        }
    } else if (_stickTouch && [touches containsObject:_stickTouch]) {
        CGPoint point = [_stickTouch locationInView:self];
        [self.stick updateFromOffset:CGPointMake(point.x - _stickOrigin.x, point.y - _stickOrigin.y)];
    }
}

- (void)finishTouches:(NSSet<UITouch *> *)touches save:(BOOL)save {
    if (_editorTouch && [touches containsObject:_editorTouch]) {
        _editorTouch = nil;
        CGRect frame = _frames[_selected];
        if (save && !CGRectEqualToRect(frame, _initialFrame)) {
            self.positions[control_id(_selected)] = @[
                @((CGRectGetMidX(frame) - CGRectGetMinX(_area)) / _area.size.width),
                @((CGRectGetMidY(frame) - CGRectGetMinY(_area)) / _area.size.height),
                @(frame.size.width / [self controlSize:_selected].width), @2
            ];
            [self savePreferences];
        } else if (!save) {
            _frames[_selected] = _initialFrame;
            [self applyFrames];
        }
    }
    if (_stickTouch && [touches containsObject:_stickTouch]) {
        _stickTouch = nil;
        [self.stick updateFromOffset:CGPointZero];
        self.stick.frame = _frames[kStickIndex];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self finishTouches:touches save:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self finishTouches:touches save:NO]; }

- (void)cancelInput {
    for (RTActionButton *button in self.buttons) [button cancelInput];
    if (_editorTouch) {
        _editorTouch = nil;
        _frames[_selected] = _initialFrame;
    }
    _stickTouch = nil;
    self.stick.dirs = 0;
    [self.stick updateFromOffset:CGPointZero];
    [self setNeedsLayout];
}
@end

static void overlay_front(void) {
    if (g_controls) [g_root.view bringSubviewToFront:g_controls];
}

static void update_touch_controls(void) {
    [(RTControlsView *)g_controls refresh];
}

static void cancel_touch_input(void) {
    g_touch_epoch++;
    for (RTView *view in g_views) view.tracking = nil;
    if (g_menu_enter_hwnd) {
        g_menu_enter_hwnd = 0;
        touch_key(36, '\r', 0);
    }
    [(RTControlsView *)g_controls cancelInput];
}

static void build_controls(void) {
    RTControlsView *view = [[RTControlsView alloc] initWithFrame:g_root.view.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_controls = view;
    [g_root.view addSubview:view];
}

// ---------------- gyro aiming ----------------
// Turning the phone about the world's vertical axis turns the view; tilting it about the screen's horizontal axis
// looks up/down. Rotation rates come from CMDeviceMotion (gravity gives the vertical axis, so it works at any tilt).
static CMMotionManager *g_motion;
static void start_gyro(void) {
    g_motion = [CMMotionManager new];
    if (!g_motion.deviceMotionAvailable) { rt_log("[cocoa] no gyro\n"); return; }
    g_motion.deviceMotionUpdateInterval = 1.0 / 120;
    static double accx, accy, lastT;
    static NSUInteger lastEpoch;
    NSOperationQueue *motionQueue = [NSOperationQueue new];
    motionQueue.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:motionQueue withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!m) return;
        double dt = lastT ? m.timestamp - lastT : 0; lastT = m.timestamp;
        NSUInteger epoch = atomic_load(&g_touch_epoch);
        if (epoch != lastEpoch) {
            accx = accy = 0;
            lastEpoch = epoch;
        }
        if (!atomic_load(&g_touch_gyro_active) || !atomic_load(&g_gyro_on)) {
            accx = accy = 0;
            return;
        }
        if (dt <= 0 || dt > 0.1) return;
        uint64_t hwnd = atomic_load(&g_key_hwnd); if (!hwnd) return;
        CMRotationRate r = m.rotationRate; CMAcceleration g = m.gravity;
        { static double px, py, pz; static int cnt; static double gx, gy, gz;   // diagnostics: peak rate per axis every 0.5 s
          if (fabs(r.x) > fabs(px)) px = r.x; if (fabs(r.y) > fabs(py)) py = r.y; if (fabs(r.z) > fabs(pz)) pz = r.z;
          gx += g.x; gy += g.y; gz += g.z;
          if (++cnt >= 60) { rt_log("[gyro] peak rate x %+.2f y %+.2f z %+.2f rad/s | gravity x %+.2f y %+.2f z %+.2f\n", px, py, pz, gx / cnt, gy / cnt, gz / cnt); px = py = pz = gx = gy = gz = 0; cnt = 0; } }
        // Two orthogonal axes from gravity, whatever way the sensors are mounted: yaw about the world's vertical (up = -gravity),
        // pitch about the screen's horizontal axis = up x screen-normal (z), normalized. (On this phone gravity lies along
        // the device's y axis in play, not x: assuming a fixed axis for pitch gave none.)
        double ux = -g.x, uy = -g.y, uz = -g.z;
        double yaw = r.x * ux + r.y * uy + r.z * uz;       // + = turning left
        double rx = uy, ry = -ux, rn = sqrt(rx * rx + ry * ry);   // screen-right in device coordinates
        double pitchUp = rn > 0.3 ? (r.x * rx + r.y * ry) / rn : 0;   // + = looking up
        double pitch = -pitchUp;                           // mouse y grows downward
        double k = 450.0 * g_sens * dt;                            // mouse counts per rad/s
        accx += -yaw * k; accy += pitch * k;
        int dx = (int)accx, dy = (int)accy; accx -= dx; accy -= dy;
        if (dx || dy) {
            on_main(^{
                if (epoch == atomic_load(&g_touch_epoch) && atomic_load(&g_touch_gyro_active) &&
                    atomic_load(&g_gyro_on) && atomic_load(&g_pointer_locked) && hwnd == atomic_load(&g_key_hwnd))
                    mouse_motion(hwnd, dx, dy, clampi(atomic_load(&g_cx) + dx, 0, 4095),
                                                clampi(atomic_load(&g_cy) + dy, 0, 4095));
            });
        }
    }];
}

// ProMotion: tell the system this app wants 60-120 Hz. Without a request iOS can settle the display at 30 Hz when
// frames arrive irregularly. The optional cap also uses this display link.
@interface RTRateHint : NSObject - (void)tick:(CADisplayLink *)l; @end
double cocoa_dl_interval_ms = 0; int cocoa_dl_count;   // measured display-link period (read by the perf log)
@implementation RTRateHint
- (void)tick:(CADisplayLink *)l {
    static CFTimeInterval last; CFTimeInterval t = l.timestamp;
    if (last) { cocoa_dl_interval_ms += (t - last) * 1000; cocoa_dl_count++; }
    last = t;
    rt_ios_cap30_display_tick(l.targetTimestamp);
}
@end
static RTRateHint *g_hint; static CADisplayLink *g_link;
static void request_high_refresh(void) {
    g_hint = [RTRateHint new];
    g_link = [CADisplayLink displayLinkWithTarget:g_hint selector:@selector(tick:)];
    g_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [g_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

// Main thread, at launch: input devices, app activation.
void gamepad_start(void);
void cocoa_ios_start(void) {
    cocoa_ios_screen_init();
    NSURL *docs = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                       inDomains:NSUserDomainMask].firstObject;
    NSString *capPath = [docs URLByAppendingPathComponent:@"cap30.txt"].path;
    BOOL isDirectory = NO;
    BOOL enabled = capPath && [NSFileManager.defaultManager fileExistsAtPath:capPath isDirectory:&isDirectory];
    rt_ios_cap30_configure(enabled && !isDirectory);
    request_high_refresh();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    double sensitivity = [defaults doubleForKey:@"sens"];
    if (isfinite(sensitivity) && sensitivity >= 0.5 && sensitivity <= 3) g_sens = sensitivity;
    atomic_store(&g_gyro_on, [defaults boolForKey:@"gyro"]);
    build_controls();
    start_gyro();
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (GCKeyboard.coalescedKeyboard) attach_keyboard(GCKeyboard.coalescedKeyboard);
    [nc addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { attach_keyboard(n.object); }];
    for (GCMouse *m in GCMouse.mice) attach_mouse(m);
    [nc addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) { attach_mouse(n.object); }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        g_touch_active = YES;
        update_touch_controls();
        rt_ios_gpu_pause(0); win_from_cocoa(0, WM_ACTIVATEAPP, 1, 0);
    }];
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        g_touch_active = NO;
        update_touch_controls();
        cancel_touch_input();
        rt_ios_gpu_pause(1); win_from_cocoa(0, WM_ACTIVATEAPP, 0, 0);
    }];
    gamepad_start();
}
