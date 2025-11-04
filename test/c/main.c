#include <stdio.h>
#include <stdlib.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#include <unistd.h>

#include <dlfcn.h>

#ifndef LIBVK
	#define LIBVK "vulkan"
#endif

#define VOLK_IMPLEMENTATION
#include "volk.h"

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

	volkInitialize();

	VkDirectDriverLoadingInfoLUNARG directLoadingInfo = {};
	directLoadingInfo.sType = VK_STRUCTURE_TYPE_DIRECT_DRIVER_LOADING_INFO_LUNARG;
	directLoadingInfo.pfnGetInstanceProcAddr = (PFN_vkGetInstanceProcAddrLUNARG)(dlsym(lib, "vk_icdGetInstanceProcAddr"));

	VkDirectDriverLoadingListLUNARG directDriverList = {};
	directDriverList.sType = VK_STRUCTURE_TYPE_DIRECT_DRIVER_LOADING_LIST_LUNARG;
	directDriverList.mode = VK_DIRECT_DRIVER_LOADING_MODE_EXCLUSIVE_LUNARG;
	directDriverList.driverCount = 1;
	directDriverList.pDrivers = &directLoadingInfo;

	const char* extensions[] = { VK_LUNARG_DIRECT_DRIVER_LOADING_EXTENSION_NAME };

	VkInstanceCreateInfo instance_create_info = {};
	instance_create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	instance_create_info.pApplicationInfo = NULL;
	instance_create_info.enabledExtensionCount = 1;
	instance_create_info.ppEnabledExtensionNames = extensions;
	instance_create_info.pNext = &directDriverList;

	VkInstance instance = VK_NULL_HANDLE;
	CheckVk(vkCreateInstance(&instance_create_info, NULL, &instance));
	volkLoadInstance(instance);

	printf("VkInstance %p\n", instance);

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

	volkLoadDevice(device);

	vkDestroyDevice(device, NULL);
	vkDestroyInstance(instance, NULL);

	free(physical_devices);
	dlclose(lib);
	return 0;
}
