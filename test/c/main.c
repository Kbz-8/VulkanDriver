#include <stdio.h>
#include <stdlib.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <dlfcn.h>

#ifndef LIBVK
	#define LIBVK "vulkan"
#endif

int main(void)
{
	printf("openning ./zig-out/lib/lib" LIBVK ".so\n");
	void* lib = dlopen("./zig-out/lib/lib" LIBVK ".so", RTLD_NOW | RTLD_LOCAL);

	PFN_vkGetInstanceProcAddr vkGetInstanceProcAddr = dlsym(lib, "vkGetInstanceProcAddr");

	printf("test %p\n", vkGetInstanceProcAddr);
	printf("test %p\n", vkGetInstanceProcAddr(NULL, "vkCreateInstance"));

	dlclose(lib);
	return 0;
}
