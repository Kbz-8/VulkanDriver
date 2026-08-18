#include <Buffer.h>
#include <Logger.h>
#include <Memory.h>

#include <avx/Avx.h>

int IsBufferCommand(const PhiCmdHeader* header)
{
	switch((PhiCmdType)header->type)
	{
		case PHI_CMD_COPY_BUFFER:
		case PHI_CMD_FILL_BUFFER:
			return 1;

		default:
			return 0;
	}
}

static PhiStatus CopyBuffer(PhiCommandReader* reader)
{
	PhiCmdCopyBuffer command;
	PhiStatus status = ReadCommandData(reader, &command, sizeof(command));
	if(status != PHI_STATUS_OK)
		return status;

	if(command.src_memory == 0 || command.dst_memory == 0)
		return PHI_STATUS_INVALID_HANDLE;

	Memory* dst_memory = (Memory*)command.dst_memory;
	const Memory* src_memory = (const Memory*)command.src_memory;

	uint8_t* dst = (uint8_t*)dst_memory->ptr + (size_t)command.dst_offset;
	const uint8_t* src = (const uint8_t*)src_memory->ptr + (size_t)command.src_offset;

	AvxCopy(dst, src, (size_t)command.size);

	return PHI_STATUS_OK;
}

static PhiStatus FillBuffer(PhiCommandReader* reader)
{
	PhiCmdFillBuffer command;

	PhiStatus status = ReadCommandData(reader, &command, sizeof(command));

	if(status != PHI_STATUS_OK)
		return status;

	if(command.memory == 0)
	{
		LogErrorFmt("Invalid memory handle: %p", command.memory);
		return PHI_STATUS_INVALID_HANDLE;
	}

	Memory* memory = (Memory*)command.memory;

	uint8_t* dst = (uint8_t*)memory->ptr + (size_t)command.offset;

	size_t size = (size_t)command.size;
	const uint32_t value = command.data;

	// Check if dst and size are 4-byte aligned
	uintptr_t alignment = ((uintptr_t)dst | size) & 3;
	if(alignment != 0)
	{
		LogErrorFmt("Invalid memory alignment: %d", alignment);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	// Bring dst to a 64-byte cache-line boundary.
	while(size >= 4 && ((uintptr_t)dst & 63) != 0)
	{
		*(uint32_t*)dst = value;

		dst += 4;
		size -= 4;
	}

	while(size >= 256)
	{
		AvxFill256(dst, value);

		dst += 256;
		size -= 256;
	}

	while(size >= 64)
	{
		AvxFill64(dst, value);

		dst += 64;
		size -= 64;
	}

	uint32_t* tail = (uint32_t*)dst;
	while(size >= 4)
	{
		*tail++ = value;
		size -= 4;
	}

	return PHI_STATUS_OK;
}

PhiStatus ExecuteBufferCommand(PhiCommandReader* reader, const PhiCmdHeader* header)
{
	switch((PhiCmdType)header->type)
	{
		case PHI_CMD_COPY_BUFFER:
			return CopyBuffer(reader);
		case PHI_CMD_FILL_BUFFER:
			return FillBuffer(reader);

		default:
			return PHI_STATUS_BAD_MESSAGE;
	}
}
