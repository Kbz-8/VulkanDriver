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
#include <volk.h>

#define KVF_IMPLEMENTATION
#define KVF_ENABLE_VALIDATION_LAYERS
#define KVF_NO_KHR
#include <kvf.h>

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

	VkInstance instance = kvfCreateInstanceNext(extensions, 1, &direct_driver_list);
	volkLoadInstance(instance);

	VkPhysicalDevice physical_device = kvfPickGoodPhysicalDevice(instance, VK_NULL_HANDLE, NULL, 0);

	VkDevice device = kvfCreateDevice(physical_device, NULL, 0, NULL);
	volkLoadDevice(device);

	VkQueue queue = kvfGetDeviceQueue(device, KVF_GRAPHICS_QUEUE);
	VkFence fence = kvfCreateFence(device);
	VkCommandBuffer cmd = kvfCreateCommandBuffer(device);

	kvfCheckVk(vkResetCommandBuffer(cmd, 0));

	kvfBeginCommandBuffer(cmd, 0);
	kvfEndCommandBuffer(cmd);

	kvfSubmitCommandBuffer(device, cmd, KVF_GRAPHICS_QUEUE, VK_NULL_HANDLE, VK_NULL_HANDLE, fence, NULL);
	kvfWaitForFence(device, fence);

	kvfDestroyFence(device, fence);

	kvfDestroyDevice(device);
	kvfDestroyInstance(instance);

	dlclose(lib);
	return 0;
}
