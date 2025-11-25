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

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include <stb_image_write.h>

VkDeviceMemory CreateAndBindMemoryToBuffer(VkPhysicalDevice physical_device, VkDevice device, VkBuffer buffer, VkMemoryPropertyFlags props)
{
	VkMemoryRequirements requirements;
	vkGetBufferMemoryRequirements(device, buffer, &requirements);

	VkMemoryAllocateInfo alloc_info = {0};
	alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc_info.allocationSize = requirements.size;
	alloc_info.memoryTypeIndex = kvfFindMemoryType(physical_device, requirements.memoryTypeBits, props);

	VkDeviceMemory memory;
	kvfCheckVk(vkAllocateMemory(device, &alloc_info, NULL, &memory));
	kvfCheckVk(vkBindBufferMemory(device, buffer, memory, 0));
	return memory;
}

VkDeviceMemory CreateAndBindMemoryToImage(VkPhysicalDevice physical_device, VkDevice device, VkImage image, VkMemoryPropertyFlags props)
{
	VkMemoryRequirements requirements;
	vkGetImageMemoryRequirements(device, image, &requirements);

	VkMemoryAllocateInfo alloc_info = {0};
	alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
	alloc_info.allocationSize = requirements.size;
	alloc_info.memoryTypeIndex = kvfFindMemoryType(physical_device, requirements.memoryTypeBits, props);

	VkDeviceMemory memory;
	kvfCheckVk(vkAllocateMemory(device, &alloc_info, NULL, &memory));
	kvfCheckVk(vkBindImageMemory(device, image, memory, 0));
	return memory;
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

	VkImage image = kvfCreateImage(device, 256, 256, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, KVF_IMAGE_COLOR);
	VkDeviceMemory memory = CreateAndBindMemoryToImage(physical_device, device, image, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);

	VkImageView image_view = kvfCreateImageView(device, image, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_VIEW_TYPE_2D, VK_IMAGE_ASPECT_COLOR_BIT, 1);

	VkQueue queue = kvfGetDeviceQueue(device, KVF_GRAPHICS_QUEUE);
	VkFence fence = kvfCreateFence(device);
	VkCommandBuffer cmd = kvfCreateCommandBuffer(device);

	kvfCheckVk(vkResetCommandBuffer(cmd, 0));

	kvfBeginCommandBuffer(cmd, 0);
	{
	}
	kvfEndCommandBuffer(cmd);

	kvfSubmitCommandBuffer(device, cmd, KVF_GRAPHICS_QUEUE, VK_NULL_HANDLE, VK_NULL_HANDLE, fence, NULL);
	kvfWaitForFence(device, fence);

	void* map = NULL;
	kvfCheckVk(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &map));
	if(!stbi_write_png("res.png", 256, 256, 4, map, 256 * 4))
		fprintf(stderr, "Failed to write result image to file\n");
	vkUnmapMemory(device, memory);

	kvfDestroyFence(device, fence);

	kvfDestroyImageView(device, image_view);
	kvfDestroyImage(device, image);
	vkFreeMemory(device, memory, NULL);

	kvfDestroyDevice(device);
	kvfDestroyInstance(instance);

	dlclose(lib);
	return 0;
}
