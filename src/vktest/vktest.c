/* vktest: minimal Vulkan check through Wine's vulkan-1.dll -> winevulkan -> MoltenVK.
 * Creates an instance, lists physical devices (name, API version, driver) and
 * creates a logical device with one queue. Exit code 0 = device created.
 * Loads vulkan-1.dll at run time, so it only needs the Vulkan headers to build.
 */
#include <stdio.h>
#include <windows.h>
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

int main(void)
{
    HMODULE vk = LoadLibraryA("vulkan-1.dll");
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkCreateInstance create_instance;
    PFN_vkEnumeratePhysicalDevices enum_devices;
    PFN_vkGetPhysicalDeviceProperties get_props;
    PFN_vkCreateDevice create_device;
    PFN_vkDestroyDevice destroy_device;
    PFN_vkEnumerateInstanceVersion enum_version;
    VkApplicationInfo app = { VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "vktest", 1, NULL, 0, VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL, 0, &app };
    VkInstance inst;
    VkPhysicalDevice devs[8];
    uint32_t n = 8, ver = 0, i;
    VkResult r;

    if (!vk) { printf("vulkan-1.dll not found (%lu)\n", GetLastError()); return 2; }
    gipa = (PFN_vkGetInstanceProcAddr)GetProcAddress(vk, "vkGetInstanceProcAddr");
    create_instance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    enum_version = (PFN_vkEnumerateInstanceVersion)gipa(NULL, "vkEnumerateInstanceVersion");
    if (enum_version) enum_version(&ver);
    printf("instance version %u.%u.%u\n", VK_VERSION_MAJOR(ver), VK_VERSION_MINOR(ver), VK_VERSION_PATCH(ver));

    r = create_instance(&ici, NULL, &inst);
    printf("vkCreateInstance: %d\n", r);
    if (r) return 3;
    enum_devices = (PFN_vkEnumeratePhysicalDevices)gipa(inst, "vkEnumeratePhysicalDevices");
    get_props = (PFN_vkGetPhysicalDeviceProperties)gipa(inst, "vkGetPhysicalDeviceProperties");
    create_device = (PFN_vkCreateDevice)gipa(inst, "vkCreateDevice");
    destroy_device = (PFN_vkDestroyDevice)gipa(inst, "vkDestroyDevice");

    r = enum_devices(inst, &n, devs);
    printf("vkEnumeratePhysicalDevices: %d, %u device(s)\n", r, n);
    for (i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p;
        get_props(devs[i], &p);
        printf("  [%u] %s  API %u.%u.%u  driver 0x%x  vendor 0x%04x device 0x%04x type %d\n", i, p.deviceName,
               VK_VERSION_MAJOR(p.apiVersion), VK_VERSION_MINOR(p.apiVersion), VK_VERSION_PATCH(p.apiVersion),
               p.driverVersion, p.vendorID, p.deviceID, p.deviceType);
    }
    if (n) {
        float prio = 1.0f;
        VkDeviceQueueCreateInfo q = { VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio };
        VkDeviceCreateInfo dci = { VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &q };
        VkDevice dev;
        r = create_device(devs[0], &dci, NULL, &dev);
        printf("vkCreateDevice: %d\n", r);
        if (!r) { destroy_device(dev, NULL); return 0; }
    }
    return 1;
}
