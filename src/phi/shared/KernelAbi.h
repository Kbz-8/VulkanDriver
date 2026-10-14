#ifndef APE_PHI_KERNEL_ABI_H
#define APE_PHI_KERNEL_ABI_H

#include <stddef.h>
#include <stdint.h>

#define PHI_KERNEL_ABI_VERSION 1u
#define PHI_KERNEL_BUFFER_DESCRIPTOR_SIZE 16u
#define PHI_KERNEL_BUFFER_DESCRIPTOR_ALIGNMENT 8u
#define PHI_KERNEL_CONTEXT_SIZE 80u
#define PHI_KERNEL_CONTEXT_ALIGNMENT 8u

typedef struct PhiKernelBufferDescriptor
{
	// Card virtual address, NOT a host pointer or a transport memory handle
	uint64_t address;
	uint64_t size;
} PhiKernelBufferDescriptor;

typedef struct PhiKernelContext
{
	uint32_t abi_version;
	uint32_t resource_count;
	// Card virtual addresses of the descriptor array and push-constant bytes
	uint64_t resources;
	uint64_t push_constants;
	uint32_t push_constant_size;
	uint32_t reserved;
	uint32_t base_group[3];
	uint32_t group_count[3];
	uint32_t local_size[3];
	uint32_t num_workgroups[3];
} PhiKernelContext;

typedef void (*PhiKernelEntryPoint)(const PhiKernelContext* context, uint64_t begin_workgroup, uint64_t end_workgroup);

#define PHI_KERNEL_ABI_ASSERT(name, expression) typedef char PhiKernelAbiAssert_##name[(expression) ? 1 : -1]
#define PHI_KERNEL_ABI_OFFSET(type, field, offset) PHI_KERNEL_ABI_ASSERT(type##_##field, offsetof(type, field) == (offset))

PHI_KERNEL_ABI_ASSERT(buffer_descriptor_size, sizeof(PhiKernelBufferDescriptor) == PHI_KERNEL_BUFFER_DESCRIPTOR_SIZE);
PHI_KERNEL_ABI_ASSERT(buffer_descriptor_alignment,
                      __alignof__(PhiKernelBufferDescriptor) == PHI_KERNEL_BUFFER_DESCRIPTOR_ALIGNMENT);
PHI_KERNEL_ABI_OFFSET(PhiKernelBufferDescriptor, address, 0);
PHI_KERNEL_ABI_OFFSET(PhiKernelBufferDescriptor, size, 8);

PHI_KERNEL_ABI_ASSERT(context_size, sizeof(PhiKernelContext) == PHI_KERNEL_CONTEXT_SIZE);
PHI_KERNEL_ABI_ASSERT(context_alignment, __alignof__(PhiKernelContext) == PHI_KERNEL_CONTEXT_ALIGNMENT);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, abi_version, 0);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, resource_count, 4);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, resources, 8);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, push_constants, 16);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, push_constant_size, 24);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, reserved, 28);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, base_group, 32);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, group_count, 44);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, local_size, 56);
PHI_KERNEL_ABI_OFFSET(PhiKernelContext, num_workgroups, 68);

#endif
