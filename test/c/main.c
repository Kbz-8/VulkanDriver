#include <stdio.h>
#include <stdlib.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#include <dlfcn.h>

#ifndef LIBVK
	#define LIBVK "vulkan"
#endif

#define CheckVk(x) \
	do { \
		if((x) != VK_SUCCESS) \
		{ \
			fprintf(stderr, "Vulkan call failed\n"); \
			abort(); \
		} \
	} while(0)

int main(void)
{
	void* lib = dlopen("./zig-out/lib/lib" LIBVK ".so", RTLD_NOW | RTLD_LOCAL);
	if(!lib)
	{
		fprintf(stderr, "Could not open driver lib: %s\n", dlerror());
		exit(EXIT_FAILURE);
	}
	puts("openned ./zig-out/lib/lib" LIBVK ".so");

	PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = dlsym(lib, "vkGetInstanceProcAddr");

	#define VULKAN_GLOBAL_FUNCTION(fn) PFN_##fn fn = (PFN_##fn)vkGetInstanceProcAddr(NULL, #fn);
	VULKAN_GLOBAL_FUNCTION(vkCreateInstance)

	VkInstanceCreateInfo instance_create_info = { 0 };
	instance_create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;

	VkInstance instance = VK_NULL_HANDLE;
	CheckVk(vkCreateInstance(&instance_create_info, NULL, &instance));

	printf("VkInstance %p\n", instance);

	#define VULKAN_INSTANCE_FUNCTION(fn) PFN_##fn fn = (PFN_##fn)vkGetInstanceProcAddr(instance, #fn);
	VULKAN_INSTANCE_FUNCTION(vkEnumeratePhysicalDevices)
	VULKAN_INSTANCE_FUNCTION(vkGetPhysicalDeviceProperties)
	VULKAN_INSTANCE_FUNCTION(vkGetPhysicalDeviceMemoryProperties)
	VULKAN_INSTANCE_FUNCTION(vkDestroyInstance)
	VULKAN_INSTANCE_FUNCTION(vkCreateDevice)
	VULKAN_INSTANCE_FUNCTION(vkDestroyDevice)

	uint32_t count;
	vkEnumeratePhysicalDevices(instance, &count, NULL);
	printf("VkPhysicalDevice count %d\n", count);
	VkPhysicalDevice* physical_devices = (VkPhysicalDevice*)calloc(count, sizeof(VkPhysicalDevice));
	vkEnumeratePhysicalDevices(instance, &count, physical_devices);

	VkPhysicalDeviceProperties props;
	vkGetPhysicalDeviceProperties(physical_devices[0], &props);
	printf("VkPhysicalDevice name %s\n", props.deviceName);

	VkDeviceCreateInfo device_create_info = {0};
	device_create_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
	
	VkDevice device = VK_NULL_HANDLE;
	CheckVk(vkCreateDevice(physical_devices[0], &device_create_info, NULL, &device));
	printf("VkDevice %p\n", device);

	vkDestroyDevice(device, NULL);
	vkDestroyInstance(instance, NULL);

	free(physical_devices);
	dlclose(lib);
	return 0;
}
