// iOS entry point, replacing boot.c: UIApplicationMain on the main thread, the guest on its own thread.
//
// Game files: <app Documents>/DOOM/ (must contain DOOMx64vk.exe). Documents is visible in the Files app and to
// `devicectl device copy`; DOOM_GAME_DIR overrides it.
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import <Metal/Metal.h>
#include <malloc/malloc.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rt.h"
#include "cocoa.h"
#include "game.h"

void win32_init(int argc, char **argv);
int rt_guest_strip_claimed(void);              // rt.c (ios/patches/framework/0001-ios-claim-guest-strip.patch)
UIViewController *cocoa_ios_root(void);
void cocoa_ios_start(void);

// The game restarts itself through CreateProcess to switch renderer or mode; an iOS app cannot start another
// copy of itself.
int rt_relaunch(int nargs, char **args) {
    (void)args;
    rt_log("[boot] relaunch requested (%d game args): not possible on iOS\n", nargs);
    return 0;
}

static char g_exe[PATH_MAX], g_dir[PATH_MAX];
static int g_argc; static char **g_argv;

static void *game_thread(void *arg) {
    (void)arg;
    pthread_setname_np("DOOM main");
    rt_init();
    char **gargv = g_argv; int gargc = g_argc;
    if (rt_game.extra_args) {
        int ne = 0; while (rt_game.extra_args[ne]) ne++;
        char **v = calloc((size_t)(gargc + ne + 1), sizeof *v);
        memcpy(v, gargv, (size_t)gargc * sizeof *v);
        for (int i = 0; i < ne; i++) v[gargc++] = (char *)rt_game.extra_args[i];
        gargv = v;
    }
    rt_log("[boot] game folder %s\n", g_dir);
    rt_load_image(g_exe);
    if (chdir(g_dir)) { perror(g_dir); return NULL; }
    win32_init(gargc, gargv);
    CPU *c = cpu_new(8u << 20);
    rt_set_cur(c);
    rt_log("[boot] image at 0x%llx, entry 0x%llx, %d functions\n", (unsigned long long)gimage_base, (unsigned long long)gentry, ngfuncs);
    uint64_t r = guest_call(c, gentry, 0, NULL);
    rt_log("[boot] entry returned %llu\n", (unsigned long long)r);
    exit(0);
}



// Resident+swapped (dirty) memory by VM tag, largest first: what is growing.
static void vm_tag_summary(char *out, size_t n) {
    static uint64_t bytes[256]; memset(bytes, 0, sizeof bytes);
    vm_address_t a = 0; natural_t depth = 0;
    for (;;) {
        vm_size_t sz = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &c) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        bytes[info.user_tag & 255] += (uint64_t)(info.pages_dirtied + info.pages_swapped_out) * vm_page_size;
        a += sz;
    }
    int o = snprintf(out, n, "[vmtags]");
    for (int k = 0; k < 5; k++) {
        int best = -1; for (int t = 0; t < 256; t++) if (bytes[t] > (best < 0 ? 64u << 20 : bytes[best])) best = t;
        if (best < 0) break;
        o += snprintf(out + o, n - (size_t)o, " tag%d=%.0fMB", best, bytes[best] / 1048576.0); bytes[best] = 0;
    }
}

// Performance log (every 5 s into the log, with RT_FPS): CPU use per thread, to see what limits the frame rate.
#include <mach/mach.h>
#include <os/proc.h>
static void *perf_thread(void *arg) {
    pthread_setname_np("perf monitor");
    id<MTLDevice> metal = MTLCreateSystemDefaultDevice();
    for (;;) {
        sleep(5);
        thread_act_array_t th; mach_msg_type_number_t n = 0;
        if (task_threads(mach_task_self(), &th, &n)) continue;
        char line[1024]; int o = snprintf(line, sizeof line, "[perf]");
        for (mach_msg_type_number_t i = 0; i < n; i++) {
            thread_basic_info_data_t bi; mach_msg_type_number_t c = THREAD_BASIC_INFO_COUNT;
            if (thread_info(th[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &c)) continue;
            double cpu = bi.cpu_usage / 10.0;
            if (cpu < 3.0) continue;
            char name[64] = "?"; pthread_t pt = pthread_from_mach_thread_np(th[i]);
            if (pt) pthread_getname_np(pt, name, sizeof name);
            if (o < 740) o += snprintf(line + o, sizeof line - (size_t)o, " %.63s=%.0f%%", name[0] ? name : "?", cpu);
        }
        for (mach_msg_type_number_t i = 0; i < n; i++) mach_port_deallocate(mach_task_self(), th[i]);
        vm_deallocate(mach_task_self(), (vm_address_t)th, n * sizeof *th);
        { task_vm_info_data_t vi; mach_msg_type_number_t vc = TASK_VM_INFO_COUNT;
          if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vc) == KERN_SUCCESS)
              o += snprintf(line + o, sizeof line - (size_t)o, " | footprint=%.0fMB avail=%.0fMB", vi.phys_footprint / 1048576.0, os_proc_available_memory() / 1048576.0); }
        NSProcessInfo *pi = NSProcessInfo.processInfo;
        o += snprintf(line + o, sizeof line - (size_t)o, " | lowPower=%d thermal=%ld", pi.lowPowerModeEnabled, (long)pi.thermalState);
        { extern double cocoa_dl_interval_ms; extern int cocoa_dl_count;
          if (cocoa_dl_count) { o += snprintf(line + o, sizeof line - (size_t)o, " displayLink=%.2fms", cocoa_dl_interval_ms / cocoa_dl_count); cocoa_dl_interval_ms = 0; cocoa_dl_count = 0; } }
        malloc_statistics_t heap = {0};
        malloc_zone_statistics(NULL, &heap);
        o += snprintf(line + o, sizeof line - (size_t)o,
                      " | mallocInUse=%.1fMiB mallocReserved=%.1fMiB",
                      heap.bytes_in_use / 1048576.0, heap.size_allocated / 1048576.0);
        if (metal) {
            snprintf(line + o, sizeof line - (size_t)o, " metalAllocated=%.1fMiB",
                     metal.currentAllocatedSize / 1048576.0);
        } else {
            snprintf(line + o, sizeof line - (size_t)o, " metalAllocated=unavailable");
        }
        rt_log("%s\n", line);
        { static int tick; if (++tick % 6 == 0) { char vl[400]; vm_tag_summary(vl, sizeof vl); rt_log("%s\n", vl); } }
    }
    return NULL;
}

static void start_game(void) {
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 64u << 20);
    pthread_t t;
    pthread_t pm; pthread_create(&pm, NULL, perf_thread, NULL); pthread_detach(pm);
    if (pthread_create(&t, &at, game_thread, NULL)) rt_log("[boot] cannot start the game thread\n");
    pthread_detach(t);
}

static void fatal(UIViewController *root, NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Quit" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { exit(0); }]];
    [root presentViewController:a animated:YES completion:nil];
}

static int is_game_dir(const char *d) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/%s", d, rt_game.exe);
    return access(p, R_OK) == 0;
}

@interface RTSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong) UIWindow *window;
@end
@interface RTiOSDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RTiOSDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = [RTSceneDelegate class];
    return c;
}
- (UIInterfaceOrientationMask)application:(UIApplication *)a supportedInterfaceOrientationsForWindow:(UIWindow *)w { return UIInterfaceOrientationMaskLandscape; }
@end
@implementation RTSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    UIApplication *app = UIApplication.sharedApplication;
    static int started; if (started++) return;
    setvbuf(stderr, NULL, _IONBF, 0);
    { NSString *d0 = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; freopen([d0 stringByAppendingPathComponent:@"DOOM-recomp.log"].fileSystemRepresentation, "w", stderr); setvbuf(stderr, NULL, _IONBF, 0); fprintf(stderr, "[boot] launched, strip claimed: %d\n", rt_guest_strip_claimed()); }
    { char exe[PATH_MAX]; uint32_t n = sizeof exe; if (!_NSGetExecutablePath(exe, &n)) setenv("RT_VULKAN_LIB", exe, 0); }   // vk_ios.c
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (getenv("RT_LOG_FILE")) freopen([docs stringByAppendingPathComponent:@"DOOM-recomp.log"].fileSystemRepresentation, "w", stderr);
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = cocoa_ios_root();
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    cocoa_ios_start();
    app.idleTimerDisabled = YES;
    // Skip the online login (Bethesda/PlayFab): its failures cost ~30 s at startup. DOOM_ONLINE_LOGIN=1 turns it back on.
    setenv("RT_FPS", "1", 0);
    setenv("MESA_LOG", "file", 0); setenv("MESA_LOG_LEVEL", "info", 0); setenv("MESA_LOG_PREFIX", "tag,level", 0);   // driver errors (e.g. why the device was lost) into the log
    if (!getenv("DOOM_ONLINE_LOGIN")) setenv("RT_NO_HTTP", "1", 0);

    AVAudioSession *as = AVAudioSession.sharedInstance;
    [as setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:nil];
    [as setPreferredSampleRate:48000 error:nil];
    [as setActive:YES error:nil];

    if (!rt_guest_strip_claimed()) {
        rt_log("[boot] the guest address range 0x140000000 was not available in this launch\n");
        dispatch_async(dispatch_get_main_queue(), ^{
            fatal(root, @"Couldn't reserve memory",
                  @"iOS placed something in the address range the game needs. This happens on some launches. Quit and open the app again.");
        });
        return;
    }
    const char *env = rt_game_env("GAME_DIR");
    snprintf(g_dir, sizeof g_dir, "%s", env && *env ? env : [docs stringByAppendingPathComponent:@"DOOM"].fileSystemRepresentation);
    if (!is_game_dir(g_dir)) {
        NSString *msg = [NSString stringWithFormat:@"Copy the contents of your DOOM (2016) folder, the one containing %s, to the app's Documents/DOOM folder (Finder > this iPhone > Files, or devicectl device copy to), then reopen the app.", rt_game.exe];
        dispatch_async(dispatch_get_main_queue(), ^{ fatal(root, @"Game files not found", msg); });
        return;
    }
    snprintf(g_exe, sizeof g_exe, "%s/%s", g_dir, rt_game.exe);
    static char *argv0[] = { "DOOM", NULL };
    g_argc = 1; g_argv = argv0;
    start_game();
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([RTiOSDelegate class])); }
}
