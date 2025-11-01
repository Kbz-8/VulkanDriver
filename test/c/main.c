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
	puts("openning ./zig-out/lib/lib" LIBVK ".so");
	void* lib = dlopen("./zig-out/lib/lib" LIBVK ".so", RTLD_NOW | RTLD_LOCAL);

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
	VULKAN_INSTANCE_FUNCTION(vkDestroyInstance)

	vkDestroyInstance(instance, NULL);

	dlclose(lib);
	return 0;
}
