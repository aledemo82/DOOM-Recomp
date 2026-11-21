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
// against the app's ~6 GB limit, so cap the heap the game sees (RT_VRAM_MB, default 2048).
static PFN_vkGetPhysicalDeviceMemoryProperties real_memprops;
static PFN_vkGetPhysicalDeviceMemoryProperties2 real_memprops2;

static uint64_t vram_cap(void) {
    const char *e = getenv("RT_VRAM_MB");
    return (uint64_t)(e && atoi(e) > 0 ? atoi(e) : 2048) << 20;
}

static void clamp_heaps(VkPhysicalDeviceMemoryProperties *mp) {
    for (uint32_t i = 0; i < mp->memoryHeapCount; i++)
        if (mp->memoryHeaps[i].size > vram_cap()) mp->memoryHeaps[i].size = vram_cap();
}

static void wrap_memprops(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *mp) {
    real_memprops(pd, mp);
    clamp_heaps(mp);
}

static void wrap_memprops2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *mp) {
    real_memprops2(pd, mp);
    clamp_heaps(&mp->memoryProperties);
}

// Suspend GPU calls while the app is inactive to avoid device loss on iOS.
static pthread_mutex_t gate_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_cv = PTHREAD_COND_INITIALIZER;
static int gate_paused;

void rt_ios_gpu_pause(int paused) {
    pthread_mutex_lock(&gate_mu);
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

// Report slow calls and gaps, at most once per second per operation and thread.
static uint64_t trace_now(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void trace_slow(const char *name, uint64_t start, uint64_t end,
                       uint64_t *last_log) {
    if (end - start < 30000000 || (*last_log && end - *last_log < 1000000000))
        return;
    *last_log = end;
    rt_log("[frame trace] %s %.2f ms\n", name, (end - start) / 1e6);
}

static VkResult wrap_submit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence f) {
    static _Thread_local uint64_t last_driver_log, last_gate_log;
    uint64_t entry = trace_now();
    gate_wait();
    uint64_t begin = trace_now();
    VkResult result = real_submit(q, n, si, f);
    uint64_t end = trace_now();
    trace_slow("submit gate", entry, begin, &last_gate_log);
    trace_slow("vkQueueSubmit", begin, end, &last_driver_log);
    return result;
}

static VkResult wrap_present(VkQueue q, const VkPresentInfoKHR *pi) {
    static _Thread_local uint64_t previous_end, last_gap_log, last_driver_log, last_gate_log;
    uint64_t entry = trace_now();
    gate_wait();
    uint64_t begin = trace_now();
    VkResult result = real_present(q, pi);
    uint64_t end = trace_now();
    if (previous_end)
        trace_slow("between present calls", previous_end, entry, &last_gap_log);
    trace_slow("present gate", entry, begin, &last_gate_log);
    trace_slow("vkQueuePresentKHR", begin, end, &last_driver_log);
    previous_end = trace_now();
    return result;
}

static VkResult wrap_acquire(VkDevice d, VkSwapchainKHR sc, uint64_t t,
                             VkSemaphore s, VkFence f, uint32_t *i) {
    static _Thread_local uint64_t last_driver_log, last_gate_log;
    uint64_t entry = trace_now();
    gate_wait();
    uint64_t begin = trace_now();
    VkResult result = real_acquire(d, sc, t, s, f, i);
    uint64_t end = trace_now();
    trace_slow("acquire gate", entry, begin, &last_gate_log);
    trace_slow("vkAcquireNextImageKHR", begin, end, &last_driver_log);
    return result;
}

__attribute__((visibility("default"), used))
PFN_void vkGetInstanceProcAddr(void *instance, const char *name) {
    if (!icd_gipa) {
        char exe[PATH_MAX], path[PATH_MAX];
        uint32_t n = sizeof exe;
        if (_NSGetExecutablePath(exe, &n)) return NULL;
        char *slash = strrchr(exe, '/');
        if (slash) *slash = 0;
        snprintf(path, sizeof path, "%s/Frameworks/libvulkan_kosmickrisp.dylib", exe);
        void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!h) {
            rt_log("[vulkan] cannot load %s: %s\n", path, dlerror());
            return NULL;
        }
        icd_gipa = (PFN_gipa)dlsym(h, "vk_icdGetInstanceProcAddr");
        if (!icd_gipa) {
            rt_log("[vulkan] %s has no vk_icdGetInstanceProcAddr\n", path);
            return NULL;
        }
        rt_log("[vulkan] KosmicKrisp ICD %s\n", path);
    }

    PFN_void f = icd_gipa(instance, name);
    if (f && !strcmp(name, "vkGetPhysicalDeviceMemoryProperties")) {
        real_memprops = (PFN_vkGetPhysicalDeviceMemoryProperties)f;
        return (PFN_void)wrap_memprops;
    }
    if (f && (!strcmp(name, "vkGetPhysicalDeviceMemoryProperties2") ||
              !strcmp(name, "vkGetPhysicalDeviceMemoryProperties2KHR"))) {
        real_memprops2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)f;
        return (PFN_void)wrap_memprops2;
    }
    if (f && !strcmp(name, "vkQueueSubmit")) {
        real_submit = (PFN_vkQueueSubmit)f;
        return (PFN_void)wrap_submit;
    }
    if (f && !strcmp(name, "vkQueuePresentKHR")) {
        real_present = (PFN_vkQueuePresentKHR)f;
        return (PFN_void)wrap_present;
    }
    if (f && !strcmp(name, "vkAcquireNextImageKHR")) {
        real_acquire = (PFN_vkAcquireNextImageKHR)f;
        return (PFN_void)wrap_acquire;
    }
    return f;
}
