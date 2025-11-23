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

void CreateAndBindMemoryToBuffer(VkPhysicalDevice physical_device, VkDevice device, VkBuffer buffer, VkDeviceMemory* memory , VkDeviceSize size, VkMemoryPropertyFlags props)
{
	VkMemoryRequirements requirements;
	vkGetBufferMemoryRequirements(device, buffer, &requirements);

	VkMemoryAllocateInfo alloc_info = {0};
	alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc_info.allocationSize = size;
	alloc_info.memoryTypeIndex = kvfFindMemoryType(physical_device, requirements.memoryTypeBits, props);
	kvfCheckVk(vkAllocateMemory(device, &alloc_info, NULL, memory));
	kvfCheckVk(vkBindBufferMemory(device, buffer, *memory, 0));
}

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

	VkBuffer buffer = kvfCreateBuffer(device, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, 256);
	VkDeviceMemory memory;
	CreateAndBindMemoryToBuffer(physical_device, device, buffer, &memory, 256, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

	VkBuffer buffer2 = kvfCreateBuffer(device, VK_BUFFER_USAGE_TRANSFER_DST_BIT, 256);
	VkDeviceMemory memory2;
	CreateAndBindMemoryToBuffer(physical_device, device, buffer2, &memory2, 256, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);

	VkImage image = kvfCreateImage(device, 256, 256, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, KVF_IMAGE_COLOR);

	VkQueue queue = kvfGetDeviceQueue(device, KVF_GRAPHICS_QUEUE);
	VkFence fence = kvfCreateFence(device);
	VkCommandBuffer cmd = kvfCreateCommandBuffer(device);

	kvfCheckVk(vkResetCommandBuffer(cmd, 0));

	kvfBeginCommandBuffer(cmd, 0);
	{
		vkCmdFillBuffer(cmd, buffer, 0, VK_WHOLE_SIZE, 0x600DCAFE);

		VkBufferCopy region = {0};
		region.srcOffset = 0;
		region.dstOffset = 0;
		region.size = 256;
		vkCmdCopyBuffer(cmd, buffer, buffer2, 1, &region);
	}
	kvfEndCommandBuffer(cmd);

	kvfSubmitCommandBuffer(device, cmd, KVF_GRAPHICS_QUEUE, VK_NULL_HANDLE, VK_NULL_HANDLE, fence, NULL);
	kvfWaitForFence(device, fence);

	uint32_t* map = NULL;
	kvfCheckVk(vkMapMemory(device, memory2, 0, VK_WHOLE_SIZE, 0, (void**)&map));
	for(size_t i = 0; i < 64; i++)
		printf("0x%X ", map[i]);
	puts("");
	vkUnmapMemory(device, memory2);

	kvfDestroyFence(device, fence);
	kvfDestroyBuffer(device, buffer);
	vkFreeMemory(device, memory, NULL);
	kvfDestroyBuffer(device, buffer2);
	vkFreeMemory(device, memory2, NULL);

	kvfDestroyImage(device, image);

	kvfDestroyDevice(device);
	kvfDestroyInstance(instance);

	dlclose(lib);
	return 0;
}
