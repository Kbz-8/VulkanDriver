#include <stddef.h>
#include <stdint.h>

#include <psp2/kernel/clib.h>
#include <psp2/kernel/modulemgr.h>

#define DEQP_VITA_VK_DRIVER_ABI_MAGIC 0x56564b44u
#define DEQP_VITA_VK_DRIVER_ABI_VERSION 2u

typedef void (*DeqpVitaVkVoidFunction)(void);
typedef DeqpVitaVkVoidFunction (*DeqpVitaVkGetInstanceProcAddr)(void* instance, const char* name);
typedef int (*DeqpVitaVkPublishDriver)(void* user_data,
                                       DeqpVitaVkGetInstanceProcAddr get_instance_proc_addr,
                                       const char* build_id);
typedef void* (*DeqpVitaVkAllocate)(void* user_data, uint32_t size);
typedef void* (*DeqpVitaVkReallocate)(void* user_data, void* memory, uint32_t size);
typedef void (*DeqpVitaVkFree)(void* user_data, void* memory);

typedef struct DeqpVitaVkDriverBootstrap
{
	uint32_t magic;
	uint32_t abi_version;
	uint32_t struct_size;
	void* user_data;
	DeqpVitaVkPublishDriver publish;
	DeqpVitaVkAllocate allocate;
	DeqpVitaVkReallocate reallocate;
	DeqpVitaVkFree free;
} DeqpVitaVkDriverBootstrap;

static void* s_allocator_user_data;
static DeqpVitaVkAllocate s_allocate;
static DeqpVitaVkReallocate s_reallocate;
static DeqpVitaVkFree s_free;

// Optimized Zig builds can otherwise contain only zero-initialized writable
// data. GNU ld then emits a zero-file-size RW PT_LOAD whose file offset
// overlaps the text segment, which vita-elf-create cannot rewrite. Keep one
// live initialized word so every optimization mode has a conventional .data
// section and RW load segment. Volatile prevents constant folding
static volatile uint32_t s_module_data_anchor = DEQP_VITA_VK_DRIVER_ABI_MAGIC;

// A dynamically loaded SUPRX cannot assume that its host process imports
// SceLibc. Route Zig's C allocator calls through the CTS process instead, so
// allocations use the same newlib heap as the executable and the module has
// no SceLibc/SceLibstdcxx load-time dependency
void* malloc(size_t size)
{
	return s_allocate ? s_allocate(s_allocator_user_data, (uint32_t)size) : NULL;
}

void* realloc(void* memory, size_t size)
{
	return s_reallocate ? s_reallocate(s_allocator_user_data, memory, (uint32_t)size) : NULL;
}

void free(void* memory)
{
	if(s_free)
		s_free(s_allocator_user_data, memory);
}

size_t strlen(const char* string)
{
	const char* end = string;
	while(*end)
		++end;
	return (size_t)(end - string);
}

void* memcpy(void* destination, const void* source, size_t size)
{
	return sceClibMemcpy(destination, source, (SceSize)size);
}

void* memmove(void* destination, const void* source, size_t size)
{
	return sceClibMemmove(destination, source, (SceSize)size);
}

void* memset(void* destination, int value, size_t size)
{
	return sceClibMemset(destination, value, (SceSize)size);
}

// Zig/LLVM emits ARM EABI memory calls. VitaSDK normally provides these from
// newlib, but linking newlib into a SUPRX also pulls in executable-only CRT,
// reentrancy and syscall state. Keep the module independent by forwarding the
// EABI calls directly to Vita's process-owned clib implementation
void __aeabi_memcpy(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemcpy(destination, source, size);
}

void __aeabi_memcpy4(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemcpy(destination, source, size);
}

void __aeabi_memcpy8(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemcpy(destination, source, size);
}

void __aeabi_memmove(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemmove(destination, source, size);
}

void __aeabi_memmove4(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemmove(destination, source, size);
}

void __aeabi_memmove8(void* destination, const void* source, SceSize size)
{
	(void)sceClibMemmove(destination, source, size);
}

// The ARM EABI order is destination, size, value rather than C memset's destination, value, size
void __aeabi_memset(void* destination, SceSize size, int value)
{
	(void)sceClibMemset(destination, value, size);
}

void __aeabi_memset4(void* destination, SceSize size, int value)
{
	(void)sceClibMemset(destination, value, size);
}

void __aeabi_memset8(void* destination, SceSize size, int value)
{
	(void)sceClibMemset(destination, value, size);
}

void __aeabi_memclr(void* destination, SceSize size)
{
	(void)sceClibMemset(destination, 0, size);
}

void __aeabi_memclr4(void* destination, SceSize size)
{
	(void)sceClibMemset(destination, 0, size);
}

void __aeabi_memclr8(void* destination, SceSize size)
{
	(void)sceClibMemset(destination, 0, size);
}

// Exported by src/vulkan/lib_vulkan.zig so the C bootstrap can keep Vulkan headers out of the Vita module boundary
extern DeqpVitaVkVoidFunction vkGetInstanceProcAddr(void* instance, const char* name);

int module_start(SceSize argument_size, void* arguments)
{
	const DeqpVitaVkDriverBootstrap* bootstrap = (const DeqpVitaVkDriverBootstrap*)arguments;

	if(s_module_data_anchor != DEQP_VITA_VK_DRIVER_ABI_MAGIC || !bootstrap || argument_size < sizeof(*bootstrap) ||
	   bootstrap->magic != DEQP_VITA_VK_DRIVER_ABI_MAGIC || bootstrap->abi_version != DEQP_VITA_VK_DRIVER_ABI_VERSION ||
	   bootstrap->struct_size < sizeof(*bootstrap) || !bootstrap->publish || !bootstrap->allocate || !bootstrap->reallocate ||
	   !bootstrap->free)
		return SCE_KERNEL_START_FAILED;

	s_allocator_user_data = bootstrap->user_data;
	s_allocate = bootstrap->allocate;
	s_reallocate = bootstrap->reallocate;
	s_free = bootstrap->free;

	if(bootstrap->publish(bootstrap->user_data, vkGetInstanceProcAddr, "psvk-2026.0.1") != 0)
		return SCE_KERNEL_START_FAILED;

	return SCE_KERNEL_START_SUCCESS;
}

int module_stop(SceSize argument_size, const void* arguments)
{
	(void)argument_size;
	(void)arguments;
	s_free = NULL;
	s_reallocate = NULL;
	s_allocate = NULL;
	s_allocator_user_data = NULL;
	return SCE_KERNEL_STOP_SUCCESS;
}

int module_exit(void)
{
	return SCE_KERNEL_STOP_SUCCESS;
}
