// iOS has no Vulkan loader. The runtime's vulkan.c bootstraps through dlsym("vkGetInstanceProcAddr") on whatever
// RT_VULKAN_LIB names; boot_ios.m points that at this executable, and this function forwards to the KosmicKrisp ICD
// (Frameworks/libvulkan_kosmickrisp.dylib), which only exports vk_icdGetInstanceProcAddr.
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#define vkGetInstanceProcAddr hdr_vkGetInstanceProcAddr   /* our definition below must not clash with the header's */
#include <vulkan/vulkan_core.h>
#undef vkGetInstanceProcAddr
void rt_log(const char *fmt, ...);

typedef void (*PFN_void)(void);
typedef PFN_void (*PFN_gipa)(void *instance, const char *name);
static PFN_gipa icd_gipa;

// Unified memory: the game sizes its texture and buffer pools from the device heap (8 GB reported), and GPU allocations count
// against the app's ~6 GB limit, so cap the heap the game sees (RT_VRAM_MB, default 1536).
static PFN_vkGetPhysicalDeviceMemoryProperties real_memprops;
static PFN_vkGetPhysicalDeviceMemoryProperties2 real_memprops2;
static uint64_t vram_cap(void) { const char *e = getenv("RT_VRAM_MB"); return (uint64_t)(e && atoi(e) > 0 ? atoi(e) : 1536) << 20; }
static void clamp_heaps(VkPhysicalDeviceMemoryProperties *mp) {
    for (uint32_t i = 0; i < mp->memoryHeapCount; i++)
        if (mp->memoryHeaps[i].size > vram_cap()) mp->memoryHeaps[i].size = vram_cap();
}
static void wrap_memprops(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *mp) { real_memprops(pd, mp); clamp_heaps(mp); }
static void wrap_memprops2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *mp) { real_memprops2(pd, &*mp); clamp_heaps(&mp->memoryProperties); }


// iOS does not let a backgrounded (or about to be) app use the GPU: work submitted then makes the GPU report an error and
// the driver loses the device (the game aborts with VK_ERROR_DEVICE_LOST). The app pauses GPU submission while it is not
// active (cocoa_ios.m calls rt_ios_gpu_pause) and the game's render thread waits here until it is back.
static pthread_mutex_t gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv = PTHREAD_COND_INITIALIZER;
static int gate_paused;
static int cap30_enabled;
static uint64_t cap30_tick, cap30_consumed, cap30_activation;
static double cap30_last_target;

typedef struct {
    uint64_t start, generated, used, missed, recovered, watchdog;
    uint64_t max_wait, max_acquire;
} Cap30Stats;

static Cap30Stats cap30_stats;  // Protected by gate_mu.
static uint64_t cap30_last_tick_time;

static uint64_t trace_now(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void cap30_report(uint64_t wait, uint64_t acquire) {
    pthread_mutex_lock(&gate_mu);
    if (wait > cap30_stats.max_wait) cap30_stats.max_wait = wait;
    if (acquire > cap30_stats.max_acquire) cap30_stats.max_acquire = acquire;
    uint64_t now = trace_now();
    Cap30Stats stats = cap30_stats;
    int ready = stats.start && now - stats.start >= 5000000000ull;
    if (ready) cap30_stats = (Cap30Stats){ .start = now };
    pthread_mutex_unlock(&gate_mu);

    if (ready) {
        double seconds = (now - stats.start) / 1e9;
        rt_log("[cap30 trace] %.2fs ticks=%llu (%.1f/s) used=%llu (%.1f/s) "
               "missed=%llu recovered=%llu watchdog=%llu "
               "maxGateAndCapWait=%.2fms maxAcquire=%.2fms\n",
               seconds, (unsigned long long)stats.generated, stats.generated / seconds,
               (unsigned long long)stats.used, stats.used / seconds,
               (unsigned long long)stats.missed, (unsigned long long)stats.recovered,
               (unsigned long long)stats.watchdog, stats.max_wait / 1e6,
               stats.max_acquire / 1e6);
    }
}

void rt_ios_cap30_configure(int enabled) {
    cap30_enabled = enabled;  // Set on the main thread before starting the guest.
    rt_log("[vulkan] 30 FPS cap: %s (4 ms late window)\n", enabled ? "enabled" : "disabled");
}

void rt_ios_cap30_display_tick(double target) {
    if (!cap30_enabled) return;

    pthread_mutex_lock(&gate_mu);
    if (!gate_paused && target - cap30_last_target >= 1.0 / 30.0 - 0.001) {
        cap30_last_target = target;
        uint64_t now = trace_now();
        if (!cap30_stats.start) cap30_stats.start = now;
        if (cap30_last_tick_time && cap30_tick != cap30_consumed)
            cap30_stats.missed++;
        cap30_last_tick_time = now;
        cap30_stats.generated++;
        cap30_tick++;
        pthread_cond_broadcast(&gate_cv);
    }
    pthread_mutex_unlock(&gate_mu);
}
void rt_ios_gpu_pause(int paused) {
    pthread_mutex_lock(&gate_mu);
    if (gate_paused != paused) {
        cap30_activation++;
        cap30_last_target = 0;
        cap30_last_tick_time = 0;
        cap30_stats = (Cap30Stats){0};
    }
    gate_paused = paused;
    pthread_cond_broadcast(&gate_cv);
    pthread_mutex_unlock(&gate_mu);
    rt_log("[vulkan] GPU submission %s\n", paused ? "paused (app inactive)" : "resumed");
}
static void gate_wait(void) {
    pthread_mutex_lock(&gate_mu);
    while (gate_paused) pthread_cond_wait(&gate_cv, &gate_mu);
    pthread_mutex_unlock(&gate_mu);
}
// Use a fresh tick or wait for the next one. A blocked or stopped run loop falls
// back to ordinary FIFO after 250 ms, without bypassing the lifecycle gate.
static void acquire_gate_wait(void) {
    pthread_mutex_lock(&gate_mu);
    for (;;) {
        while (gate_paused) pthread_cond_wait(&gate_cv, &gate_mu);
        uint64_t activation = cap30_activation;
        uint64_t previous_tick = cap30_tick;
        uint64_t entry = trace_now();
        // A slightly late acquire can use the latest unconsumed tick once.
        // Older ticks expire and are never queued.
        if (cap30_last_tick_time && previous_tick != cap30_consumed &&
            entry - cap30_last_tick_time <= 4000000) {
            cap30_consumed = previous_tick;
            cap30_stats.used++;
            cap30_stats.recovered++;
            goto done;
        }
        uint64_t deadline = entry + 250000000;
        while (activation == cap30_activation) {
            if (cap30_tick != previous_tick && cap30_tick != cap30_consumed) {
                cap30_consumed = cap30_tick;
                cap30_stats.used++;
                goto done;
            }
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (now >= deadline) {
                cap30_stats.watchdog++;
                goto done;
            }
            struct timespec remaining = { .tv_nsec = (long)(deadline - now) };
            if (pthread_cond_timedwait_relative_np(&gate_cv, &gate_mu, &remaining) &&
                activation == cap30_activation) {
                cap30_stats.watchdog++;
                goto done;
            }
        }
    }

done:
    pthread_mutex_unlock(&gate_mu);
}

static PFN_vkQueueSubmit real_submit;
static PFN_vkQueuePresentKHR real_present;
static PFN_vkAcquireNextImageKHR real_acquire;
static VkResult wrap_submit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence f) {
    gate_wait();
    return real_submit(q, n, si, f);
}

static VkResult wrap_present(VkQueue q, const VkPresentInfoKHR *pi) {
    gate_wait();
    return real_present(q, pi);
}

static VkResult wrap_acquire(VkDevice d, VkSwapchainKHR sc, uint64_t t,
                             VkSemaphore s, VkFence f, uint32_t *i) {
    if (!cap30_enabled || t != UINT64_MAX || pthread_main_np()) {
        gate_wait();
        return real_acquire(d, sc, t, s, f, i);
    }

    uint64_t entry = trace_now();
    acquire_gate_wait();
    uint64_t begin = trace_now();
    VkResult result = real_acquire(d, sc, t, s, f, i);
    uint64_t end = trace_now();
    cap30_report(begin - entry, end - begin);
    return result;
}

__attribute__((visibility("default"), used))
PFN_void vkGetInstanceProcAddr(void *instance, const char *name) {
    if (!icd_gipa) {
        char exe[PATH_MAX], path[PATH_MAX]; uint32_t n = sizeof exe;
        if (_NSGetExecutablePath(exe, &n)) return NULL;
        char *slash = strrchr(exe, '/'); if (slash) *slash = 0;
        snprintf(path, sizeof path, "%s/Frameworks/libvulkan_kosmickrisp.dylib", exe);
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) { rt_log("[vulkan] cannot load %s: %s\n", path, dlerror()); return NULL; }
        icd_gipa = (PFN_gipa)dlsym(h, "vk_icdGetInstanceProcAddr");
        if (!icd_gipa) { rt_log("[vulkan] %s has no vk_icdGetInstanceProcAddr\n", path); return NULL; }
        rt_log("[vulkan] KosmicKrisp ICD %s\n", path);
    }
    PFN_void f = icd_gipa(instance, name);
    if (f && !strcmp(name, "vkGetPhysicalDeviceMemoryProperties")) { real_memprops = (PFN_vkGetPhysicalDeviceMemoryProperties)f; return (PFN_void)wrap_memprops; }
    if (f && (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties2") || !strcmp(name, "vkGetPhysicalDeviceMemoryProperties2KHR"))) {
        real_memprops2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)f; return (PFN_void)wrap_memprops2;
    }
    if (f && !strcmp(name, "vkQueueSubmit")) { real_submit = (PFN_vkQueueSubmit)f; return (PFN_void)wrap_submit; }
    if (f && !strcmp(name, "vkQueuePresentKHR")) { real_present = (PFN_vkQueuePresentKHR)f; return (PFN_void)wrap_present; }
    if (f && !strcmp(name, "vkAcquireNextImageKHR")) { real_acquire = (PFN_vkAcquireNextImageKHR)f; return (PFN_void)wrap_acquire; }
    return f;
}
