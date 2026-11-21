// iOS has no Vulkan loader. The runtime's vulkan.c bootstraps through dlsym("vkGetInstanceProcAddr") on whatever
// RT_VULKAN_LIB names; boot_ios.m points that at this executable, and this function forwards to the KosmicKrisp ICD
// (Frameworks/libvulkan_kosmickrisp.dylib), which only exports vk_icdGetInstanceProcAddr.
#include <dlfcn.h>
#include <errno.h>
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
// against the app's ~6 GB limit, so cap the heap the game sees (RT_VRAM_MB, default 2048).
static PFN_vkGetPhysicalDeviceMemoryProperties real_memprops;
static PFN_vkGetPhysicalDeviceMemoryProperties2 real_memprops2;
static uint64_t vram_cap(void) { const char *e = getenv("RT_VRAM_MB"); return (uint64_t)(e && atoi(e) > 0 ? atoi(e) : 2048) << 20; }
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
static uint64_t next_present_ns;  // protected by gate_mu
static uint64_t gate_generation;  // protected by gate_mu
void rt_ios_gpu_pause(int paused) {
    pthread_mutex_lock(&gate_mu);
    if (gate_paused != paused) {
        next_present_ns = 0;
        gate_generation++;
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
static PFN_vkQueueSubmit real_submit;
static PFN_vkQueuePresentKHR real_present;
static PFN_vkAcquireNextImageKHR real_acquire;
static VkResult wrap_submit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence f) { gate_wait(); return real_submit(q, n, si, f); }
// CPU-side timings only. The driver can queue work after real_present returns.
static pthread_once_t pacing_log_once = PTHREAD_ONCE_INIT;
static int pacing_log_enabled;
static _Thread_local uint64_t acquire_ns;
static void init_pacing_log(void) { pacing_log_enabled = getenv("RT_FPS") != NULL; }

static void log_pacing(uint64_t generation, uint64_t arrival, uint64_t admitted, uint64_t complete) {
    static _Thread_local uint64_t last_generation, last_admitted, last_complete;
    static _Thread_local uint64_t start, cap, driver, acquire, other, max_interval;
    static _Thread_local unsigned intervals;

    if (last_generation != generation || !last_complete || arrival < last_complete) {
        start = admitted;
        cap = driver = acquire = other = max_interval = 0;
        intervals = 0;
    } else {
        uint64_t interval = admitted - last_admitted;
        if (interval > max_interval) max_interval = interval;
        cap += admitted - arrival;
        driver += complete - admitted;
        acquire += acquire_ns;
        other += arrival - last_complete;
        intervals++;
        if (admitted - start >= 5000000000ull) {
            double ms = 1e6 * intervals;
            rt_log("[pacing ios] %.2f submits/s, peak gap %.2f ms | cap %.2f ms, "
                   "present API %.2f ms, acquire API %.2f ms, rest incl. framework %.2f ms\n",
                   intervals * 1e9 / (admitted - start), max_interval / 1e6,
                   cap / ms, driver / ms, acquire / ms, (other > acquire ? other - acquire : 0) / ms);
            start = admitted;
            cap = driver = acquire = other = max_interval = 0;
            intervals = 0;
        }
    }
    last_generation = generation;
    last_admitted = admitted;
    last_complete = complete;
    acquire_ns = 0;
}

static VkResult wrap_present(VkQueue q, const VkPresentInfoKHR *pi) {
    const uint64_t interval_ns = 25000000;  // 40 Hz schedule
    pthread_once(&pacing_log_once, init_pacing_log);
    uint64_t arrival = pacing_log_enabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    uint64_t waited_deadline = 0, waited_generation = 0;
    uint64_t admitted, generation;

    pthread_mutex_lock(&gate_mu);
    for (;;) {
        while (gate_paused) pthread_cond_wait(&gate_cv, &gate_mu);

        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now >= next_present_ns) {
            // Keep the 25 ms phase through small timer wake-up jitter. If work was
            // late on arrival or the wake-up missed by more than 10%, start a new phase.
            uint64_t slot = now;
            if (waited_deadline && waited_deadline == next_present_ns &&
                waited_generation == gate_generation && now - waited_deadline <= interval_ns / 10)
                slot = waited_deadline;
            next_present_ns = slot + interval_ns;
            admitted = now;
            generation = gate_generation;
            break;
        }

        // The relative wait releases the lock. Recheck both predicates on wake-up.
        waited_deadline = next_present_ns;
        waited_generation = gate_generation;
        struct timespec remaining = { .tv_nsec = (long)(waited_deadline - now) };
        int err = pthread_cond_timedwait_relative_np(&gate_cv, &gate_mu, &remaining);
        if (err && err != ETIMEDOUT) {
            pthread_mutex_unlock(&gate_mu);
            rt_log("[vulkan] present pacing wait failed: %d\n", err);
            return VK_ERROR_UNKNOWN;
        }
    }
    pthread_mutex_unlock(&gate_mu);

    // The driver may block on the swapchain. Keep the lifecycle gate available.
    VkResult result = real_present(q, pi);
    if (pacing_log_enabled) log_pacing(generation, arrival, admitted, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    return result;
}

static VkResult wrap_acquire(VkDevice d, VkSwapchainKHR sc, uint64_t t, VkSemaphore s, VkFence f, uint32_t *i) {
    gate_wait();
    pthread_once(&pacing_log_once, init_pacing_log);
    uint64_t start = pacing_log_enabled ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    VkResult result = real_acquire(d, sc, t, s, f, i);
    if (pacing_log_enabled) acquire_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
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
