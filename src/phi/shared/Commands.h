#ifndef APE_PHI_COMMANDS_H
#define APE_PHI_COMMANDS_H

#include <stdint.h>

#define PHI_COMMAND_MAGIC 0x4253BF92u

typedef enum PhiCmdType
{
	PHI_CMD_COPY_BUFFER = 0,
	PHI_CMD_FILL_BUFFER = 1,
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

#endif
