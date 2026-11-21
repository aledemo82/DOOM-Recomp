// GENERATED from framework/runtime/display.c by ios/scripts/gen_display_ios.py: do not edit.
// user32/gdi32 displays on iOS: one display (the screen), backed by UIScreen through cocoa_ios.m.
//
// Every active Mac display is a monitor. The main display comes first, is primary, and sits at (0,0).
// Coordinates are in pixels: each display's CG origin (points) is scaled by that display's pixel density.
// Mode changes are accepted but not performed (the game renders into its window at any size).
// Gamma ramps are stored and returned. They are only applied to the real display with RT_GAMMA=1,
// because CoreGraphics gamma affects the whole screen, not just the game.
#include "rt.h"
#include <math.h>
#include <CoreFoundation/CoreFoundation.h>
void cocoa_ios_screen(int *w, int *h, int *hz);
typedef uint32_t CGDirectDisplayID;
#include <pthread.h>

#define HMON_BASE 0x4D4F4E0000000000ull   // fake HMONITOR: base | (index + 1)
#define MAXD 16

typedef struct { uint32_t w, h, hz; } Mode;
typedef struct { CGDirectDisplayID id; int32_t x, y; uint32_t w, h, hz; uint32_t nw, nh; Mode *modes; int nmodes; uint32_t capw, caph; } Disp;   // w,h: current (maybe emulated); nw,nh: native
static Disp disps[MAXD];
static int ndisp;
static pthread_once_t disp_once = PTHREAD_ONCE_INIT;

static int mode_cmp(const void *a, const void *b) {
    const Mode *x = a, *y = b;
    if (x->w != y->w) return x->w < y->w ? -1 : 1;
    if (x->h != y->h) return x->h < y->h ? -1 : 1;
    return x->hz < y->hz ? -1 : x->hz > y->hz;
}
// The game groups resolutions by their exact reduced ratio (w/gcd : h/gcd; x:5 shown as 2x:10, near 16:9 and
// 21:9 snapped). Mac sizes are often a pixel off a simple ratio (1710x1112 is 855:556, not 20:13), which
// left a MacBook's own aspect ratio with a single resolution and odd groups beside it. So every size within
// 0.2% of a simple ratio (denominator up to 16) is moved onto it: 1710x1112 -> 1720x1118 (20:13). The
// emulated modes are scaled to the screen anyway, so the difference is invisible.
static void snap_ratio(uint32_t *w, uint32_t *h) {
    if (!*w || !*h) return;
    double r = (double)*w / *h;
    for (uint32_t q = 1; q <= 16; q++) {
        uint32_t p = (uint32_t)lround(r * q);
        if (!p || fabs((double)p / q - r) / r > 0.002) continue;
        uint32_t k = (uint32_t)lround((double)*h / q);
        if (k) { *w = k * p; *h = k * q; }
        return;
    }
}
static void add_mode(Disp *d, uint32_t w, uint32_t h, uint32_t hz) {
    snap_ratio(&w, &h);
    if (h < 480) return;   // the game ignores them
    // nothing above the panel's native resolution (macOS lists HiDPI backing sizes, e.g. 6720x3780 on a 4K
    // monitor); the current mode is added separately
    if (d->capw && (w > d->capw || h > d->caph) && !(w == d->w && h == d->h)) return;
    for (int i = 0; i < d->nmodes; i++) if (d->modes[i].w == w && d->modes[i].h == h && d->modes[i].hz == hz) return;
    d->modes = realloc(d->modes, sizeof(Mode) * (d->nmodes + 1));
    d->modes[d->nmodes++] = (Mode){ w, h, hz };
}
static void disp_init(void) {
    int sw, sh, shz;
    cocoa_ios_screen(&sw, &sh, &shz);
    Disp *d = &disps[0];
    d->id = 1; d->w = (uint32_t)sw; d->h = (uint32_t)sh; d->hz = (uint32_t)shz; d->x = d->y = 0;
    // Keep exact native ratio.
    d->capw = d->w; d->caph = d->h;
    // iOS fullscreen presets: exact requested width, height scaled to the
    // current panel ratio and rounded to an even pixel count.
    // Add directly: add_mode() snaps unusual aspect ratios to other ratios.
    {
        static const uint32_t widths[] = { 1280, 1440, 1650, 1920 };
        for (size_t i = 0; i < sizeof widths / sizeof *widths; i++) {
            uint32_t w = widths[i];
            uint32_t h = (uint32_t)lround((double)w * d->h / d->w / 2.0) * 2;
            if (h < 480 || w > d->capw || h > d->caph) continue;
            int found = 0;
            for (int j = 0; j < d->nmodes; j++)
                if (d->modes[j].w == w && d->modes[j].h == h && d->modes[j].hz == d->hz)
                    found = 1;
            if (!found) {
                d->modes = realloc(d->modes, sizeof(Mode) * (d->nmodes + 1));
                d->modes[d->nmodes++] = (Mode){ w, h, d->hz };
            }
        }
    }
    d->nw = d->w; d->nh = d->h;
    d->modes = realloc(d->modes, sizeof(Mode) * (d->nmodes + 1));
    d->modes[d->nmodes++] = (Mode){ d->w, d->h, d->hz };
    qsort(d->modes, d->nmodes, sizeof(Mode), mode_cmp);
    rt_log("[display] DISPLAY1: %ux%u @ %u Hz primary, %d modes\n", d->w, d->h, d->hz, d->nmodes);
    if (getenv("RT_LIST_MODES")) for (int i = 0; i < d->nmodes; i++) rt_log("[display]   %ux%u @ %u\n", d->modes[i].w, d->modes[i].h, d->modes[i].hz);
    ndisp = 1;
}
static int disp_count(void) { pthread_once(&disp_once, disp_init); return ndisp; }
static int mon_index(uint64_t h) {
    int n = disp_count();
    if ((h & ~0xFFFFull) != HMON_BASE) return -1;
    int i = (int)(h & 0xFFFF) - 1;
    return i >= 0 && i < n ? i : -1;
}
static uint64_t mon_handle(int i) { return HMON_BASE | (uint64_t)(i + 1); }
static void put_rect(uint64_t p, const Disp *d) { wr32(p, (uint32_t)d->x); wr32(p + 4, (uint32_t)d->y); wr32(p + 8, (uint32_t)(d->x + (int32_t)d->w)); wr32(p + 12, (uint32_t)(d->y + (int32_t)d->h)); }

// primary display rect in pixels (window.c)
int rt_primary_rect(int32_t r[4]) {
    if (!disp_count()) { r[0] = r[1] = 0; r[2] = 1920; r[3] = 1080; return 0; }
    r[0] = disps[0].x; r[1] = disps[0].y; r[2] = disps[0].x + (int32_t)disps[0].w; r[3] = disps[0].y + (int32_t)disps[0].h;
    return 1;
}

// ---------------- monitors ----------------
// EnumDisplayMonitors(hdc, clip, callback(HMONITOR, HDC, RECT*, LPARAM), lparam)
void I_user32_dll_EnumDisplayMonitors(CPU *c) {
    uint64_t hdc = A0, cb = A2, data = A3;
    int n = disp_count();
    for (int i = 0; i < n; i++) {
        int32_t rect[4];
        put_rect(G(rect), &disps[i]);
        uint64_t a[4] = { mon_handle(i), hdc, G(rect), data };
        if (!(uint32_t)guest_call(c, cb, 4, a)) break;
    }
    RET(1);
}
// GetMonitorInfo(hmon, MONITORINFO[EX]*): cbSize +0, rcMonitor +4, rcWork +20, dwFlags +36, szDevice +40 (EX)
static void monitor_info(CPU *c, int wide) {
    int i = mon_index(A0); uint64_t mi = A1;
    if (i < 0) { set_last_error(1461); RET(0); return; }   // ERROR_INVALID_MONITOR_HANDLE
    uint32_t cb = rd32(mi);
    put_rect(mi + 4, &disps[i]);
    put_rect(mi + 20, &disps[i]);
    wr32(mi + 36, i == 0);   // MONITORINFOF_PRIMARY
    char name[32]; snprintf(name, sizeof name, "\\\\.\\DISPLAY%d", i + 1);
    if (!wide && cb >= 72) strlcpy(PTR(mi + 40), name, 32);
    if (wide && cb >= 104) { uint16_t *w = utf8_to_w16(name); memcpy(PTR(mi + 40), w, (w16len(w) + 1) * 2); free(w); }
    RET(1);
}
void I_user32_dll_GetMonitorInfoA(CPU *c) { monitor_info(c, 0); }
void I_user32_dll_GetMonitorInfoW(CPU *c) { monitor_info(c, 1); }
// flags: MONITOR_DEFAULTTONULL 0, MONITOR_DEFAULTTOPRIMARY 1, MONITOR_DEFAULTTONEAREST 2
static uint64_t monitor_at(int32_t x, int32_t y, uint32_t flags) {
    int n = disp_count(), best = 0; int64_t bestd = INT64_MAX;
    for (int i = 0; i < n; i++) {
        const Disp *d = &disps[i];
        int64_t dx = x < d->x ? d->x - x : x >= d->x + (int32_t)d->w ? x - (d->x + (int32_t)d->w - 1) : 0;
        int64_t dy = y < d->y ? d->y - y : y >= d->y + (int32_t)d->h ? y - (d->y + (int32_t)d->h - 1) : 0;
        if (!dx && !dy) return mon_handle(i);
        if (dx * dx + dy * dy < bestd) { bestd = dx * dx + dy * dy; best = i; }
    }
    return flags == 0 || !n ? 0 : flags == 2 ? mon_handle(best) : mon_handle(0);
}
// MonitorFromPoint(POINT by value: x in the low dword, y in the high dword, flags)
void I_user32_dll_MonitorFromPoint(CPU *c) { RET(monitor_at((int32_t)A0, (int32_t)(A0 >> 32), (uint32_t)A1)); }
void I_user32_dll_MonitorFromRect(CPU *c) {
    uint64_t r = A0; int32_t l = (int32_t)rd32(r), t = (int32_t)rd32(r + 4), rr = (int32_t)rd32(r + 8), b = (int32_t)rd32(r + 12);
    RET(monitor_at(l + (rr - l) / 2, t + (b - t) / 2, (uint32_t)A1));
}
// No real windows yet: every window is on the primary display.
void I_user32_dll_MonitorFromWindow(CPU *c) { RET(disp_count() ? mon_handle(0) : 0); }

// ---------------- display modes ----------------
// DEVMODE offsets differ between the A (156 bytes) and W (220 bytes) layouts.
typedef struct { uint32_t spec, size, fields, pos, orient, fixed, logpix, bpp, w, h, flags, freq, total, namelen; } DevmodeLayout;
static const DevmodeLayout DM_A = { 32, 36, 40, 44, 52, 56, 102, 104, 108, 112, 116, 120, 156, 32 };
static const DevmodeLayout DM_W = { 64, 68, 72, 76, 84, 88, 166, 168, 172, 176, 180, 184, 220, 64 };
#define DM_FIELDS (0x20u | 0x80u | 0x40000u | 0x80000u | 0x100000u | 0x200000u | 0x400000u)   // position, orientation, bpp, w, h, flags, freq

static int disp_from_name(uint64_t name, int wide) {
    if (!name) return 0;
    char *s = wide ? w16_to_utf8(PTR(name)) : strdup(PTR(name));
    size_t L = strlen(s); int k = 0, mul = 1;
    while (L && s[L - 1] >= '0' && s[L - 1] <= '9') { k += (s[L - 1] - '0') * mul; mul *= 10; L--; }
    free(s);
    return k > 0 ? k - 1 : 0;
}
// EnumDisplaySettings[Ex](device, mode, DEVMODE*[, flags]): mode -1 current, -2 registry, else an index
static void enum_settings(CPU *c, int wide) {
    const DevmodeLayout *L = wide ? &DM_W : &DM_A;
    int di = disp_from_name(A0, wide); uint32_t mode = (uint32_t)A1; uint64_t dm = A2;
    if (di >= disp_count() || !dm) { RET(0); return; }
    const Disp *d = &disps[di];
    Mode m;
    if (mode == 0xFFFFFFFFu || mode == 0xFFFFFFFEu) m = (Mode){ d->w, d->h, d->hz };
    else if (mode < (uint32_t)d->nmodes) m = d->modes[mode];
    else { RET(0); return; }
    uint32_t sz = rd16(dm + L->size), extra = rd16(dm + L->size + 2);
    if (sz < L->fields + 4 || sz > L->total) sz = L->total;
    memset(PTR(dm), 0, sz);
    char name[32]; snprintf(name, sizeof name, "\\\\.\\DISPLAY%d", di + 1);
    if (wide) { uint16_t *w = utf8_to_w16(name); memcpy(PTR(dm), w, (w16len(w) + 1) * 2); free(w); }
    else strlcpy(PTR(dm), name, 32);
    wr16(dm + L->spec, 0x0401); wr16(dm + L->size, (uint16_t)sz); wr16(dm + L->size + 2, (uint16_t)extra);
    wr32(dm + L->fields, DM_FIELDS);
    #define PUT32(off, v) do { if ((off) + 4 <= sz) wr32(dm + (off), (uint32_t)(v)); } while (0)
    PUT32(L->pos, d->x); PUT32(L->pos + 4, d->y);
    PUT32(L->bpp, 32); PUT32(L->w, m.w); PUT32(L->h, m.h); PUT32(L->freq, m.hz);
    if (L->logpix + 2 <= sz) wr16(dm + L->logpix, 96);
    #undef PUT32
    RET(1);
}
void I_user32_dll_EnumDisplaySettingsA(CPU *c) { enum_settings(c, 0); }
void I_user32_dll_EnumDisplaySettingsW(CPU *c) { enum_settings(c, 1); }
void I_user32_dll_EnumDisplaySettingsExA(CPU *c) { enum_settings(c, 0); }
void I_user32_dll_EnumDisplaySettingsExW(CPU *c) { enum_settings(c, 1); }
// ChangeDisplaySettings[Ex]: the primary display's mode is emulated, never really switched. Afterwards the
// game sees the requested size everywhere (metrics, monitor rects, current mode) and cocoa.m scales that
// mode onto the real screen. A NULL DEVMODE (or the native size) restores the native mode.
#include "cocoa.h"
static void change_settings(uint64_t dm, int wide, uint32_t flags) {
    const DevmodeLayout *L = wide ? &DM_W : &DM_A;
    if (!disp_count()) return;
    Disp *d = &disps[0];
    uint32_t w = d->nw, h = d->nh;
    if (dm && (rd32(dm + L->fields) & 0x180000u) == 0x180000u) { w = rd32(dm + L->w); h = rd32(dm + L->h); }   // DM_PELSWIDTH | DM_PELSHEIGHT
    if (flags & 2) return;   // CDS_TEST
    if (!w || !h) { w = d->nw; h = d->nh; }
    if (w == d->w && h == d->h) return;
    d->w = w; d->h = h;
    int native = w == d->nw && h == d->nh;
    rt_log("[display] display mode %ux%u%s\n", w, h, native ? " (native)" : " (emulated: scaled to the screen)");
    cocoa_set_virtual_screen(native ? 0 : (int)w, native ? 0 : (int)h);
    win_relayout();
}
// A fullscreen game switching to windowed mode only restyles its window (Windows drops a CDS_FULLSCREEN mode
// on its own then): when a top-level window gets a title bar while a mode is emulated, go back to the
// desktop mode, so a windowed 1280x720 game is a 1280x720 window on the real screen, not the whole screen.
void display_restore_desktop(void) {
    if (!disp_count()) return;
    Disp *d = &disps[0];
    if (d->w == d->nw && d->h == d->nh) return;
    rt_log("[display] titled window: back to the desktop mode %ux%u\n", d->nw, d->nh);
    d->w = d->nw; d->h = d->nh;
    cocoa_set_virtual_screen(0, 0);
    win_relayout();
}
// ChangeDisplaySettingsEx(device, DEVMODE*, hwnd, flags, lparam) / ChangeDisplaySettings(DEVMODE*, flags)
void I_user32_dll_ChangeDisplaySettingsExA(CPU *c) { change_settings(A1, 0, (uint32_t)A3); RET(0); }
void I_user32_dll_ChangeDisplaySettingsExW(CPU *c) { change_settings(A1, 1, (uint32_t)A3); RET(0); }
void I_user32_dll_ChangeDisplaySettingsA(CPU *c) { change_settings(A0, 0, (uint32_t)A1); RET(0); }
void I_user32_dll_ChangeDisplaySettingsW(CPU *c) { change_settings(A0, 1, (uint32_t)A1); RET(0); }

// ---------------- gamma ----------------
static uint16_t gamma_ramp[3][256];
static int gamma_set;
static pthread_mutex_t gamma_mu = PTHREAD_MUTEX_INITIALIZER;
// GetDeviceGammaRamp(hdc, WORD ramp[3][256])
void I_gdi32_dll_GetDeviceGammaRamp(CPU *c) {
    pthread_mutex_lock(&gamma_mu);
    if (!gamma_set) for (int ch = 0; ch < 3; ch++) for (int i = 0; i < 256; i++) gamma_ramp[ch][i] = (uint16_t)(i * 257);
    memcpy(PTR(A1), gamma_ramp, sizeof gamma_ramp);
    pthread_mutex_unlock(&gamma_mu);
    RET(1);
}
void I_gdi32_dll_SetDeviceGammaRamp(CPU *c) {
    pthread_mutex_lock(&gamma_mu);
    memcpy(gamma_ramp, PTR(A1), sizeof gamma_ramp);
    gamma_set = 1;
    pthread_mutex_unlock(&gamma_mu);
    RET(1);
}
