#ifndef APE_PHI_COMMANDS_H
#define APE_PHI_COMMANDS_H

#include <stdint.h>

#define PHI_COMMAND_MAGIC 0x4253BF92u

// When adding commands, update CommandName in mic/CommandBuffer.c
typedef enum PhiCmdType
{
	PHI_CMD_COPY_BUFFER = 0,
	PHI_CMD_FILL_BUFFER = 1,

	PHI_CMD_COPY_BUFFER_TO_IMAGE = 2,
	PHI_CMD_COPY_IMAGE_TO_BUFFER = 3,
	PHI_CMD_COPY_IMAGE = 4,
} PhiCmdType;

typedef struct PhiCmdHeader
{
	uint32_t magic;
	uint16_t type;
} PhiCmdHeader;

typedef struct PhiCmdCopyBuffer
{
	uintptr_t src_memory;
	uint64_t src_offset;

	uintptr_t dst_memory;
	uint64_t dst_offset;

	uint64_t size;
} PhiCmdCopyBuffer;

typedef struct PhiCmdFillBuffer
{
	uintptr_t memory;
	uint64_t offset;
	uint64_t size;
	uint32_t data;
} PhiCmdFillBuffer;

typedef struct PhiCmdCopyImage
{
	uintptr_t src_memory;
	uint64_t src_offset;

	uint64_t src_row_pitch;
	uint64_t src_slice_pitch;
	uint64_t src_layer_pitch;

	uintptr_t dst_memory;
	uint64_t dst_offset;

	uint64_t dst_row_pitch;
	uint64_t dst_slice_pitch;
	uint64_t dst_layer_pitch;

	// For compressed formats this is "block_count_x * bytes_per_block" rather than "width * bytes_per_texel"
	uint64_t row_size;

	uint32_t row_count;
	uint32_t slice_count;
	uint32_t layer_count;
} PhiCmdCopyImage;

#endif
