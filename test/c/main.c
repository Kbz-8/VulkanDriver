#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#include <unistd.h>

#include <dlfcn.h>

#ifndef LIBVK
	#define LIBVK "vulkan"
#endif

#define VOLK_IMPLEMENTATION
#include <volk.h>

#define CheckVk(x) \
	do { \
		if((x) != VK_SUCCESS) \
		{ \
			fprintf(stderr, "Vulkan call failed %d\n", (x)); \
			abort(); \
		} \
	} while(0)

int main(void)
{
	volkInitialize();

	void* lib = dlopen("./zig-out/lib/lib" LIBVK ".so", RTLD_NOW | RTLD_LOCAL);
	if(!lib)
	{
		fprintf(stderr, "Could not open driver lib: %s\n", dlerror());
		exit(EXIT_FAILURE);
	}
	puts("openned ./zig-out/lib/lib" LIBVK ".so");

	VkDirectDriverLoadingInfoLUNARG direct_loading_info = {};
	direct_loading_info.sType = VK_STRUCTURE_TYPE_DIRECT_DRIVER_LOADING_INFO_LUNARG;
	direct_loading_info.pfnGetInstanceProcAddr = (PFN_vkGetInstanceProcAddrLUNARG)(dlsym(lib, "vk_icdGetInstanceProcAddr"));

	VkDirectDriverLoadingListLUNARG direct_driver_list = {};
	direct_driver_list.sType = VK_STRUCTURE_TYPE_DIRECT_DRIVER_LOADING_LIST_LUNARG;
	direct_driver_list.mode = VK_DIRECT_DRIVER_LOADING_MODE_EXCLUSIVE_LUNARG;
	direct_driver_list.driverCount = 1;
	direct_driver_list.pDrivers = &direct_loading_info;

	const char* extensions[] = { VK_LUNARG_DIRECT_DRIVER_LOADING_EXTENSION_NAME };

	VkInstanceCreateInfo instance_create_info = {};
	instance_create_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
	instance_create_info.pApplicationInfo = NULL;
	instance_create_info.enabledExtensionCount = 1;
	instance_create_info.ppEnabledExtensionNames = extensions;
	instance_create_info.pNext = &direct_driver_list;

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

	VkMemoryAllocateInfo memory_allocate_info = {};
	memory_allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	memory_allocate_info.allocationSize = 512;
	memory_allocate_info.memoryTypeIndex = 0;

	VkDeviceMemory memory = VK_NULL_HANDLE;
	CheckVk(vkAllocateMemory(device, &memory_allocate_info, NULL, &memory));
	printf("VkDeviceMemory %p\n", memory);

	void* map;
	CheckVk(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &map));
	const unsigned char data[5] = { 't', 'e', 's', 't', 0x00 };
	memcpy(map, data, 5);
	printf("Mapped %p\n", map);
	printf("Mapped data: %s\n", (char*)map);
	vkUnmapMemory(device, memory);

	vkFreeMemory(device, memory, NULL);

	vkDestroyDevice(device, NULL);
	vkDestroyInstance(instance, NULL);

	free(physical_devices);
	dlclose(lib);
	return 0;
}
