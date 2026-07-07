#include <Buffer.h>

#include <string.h>

int PhiIsBufferCommand(const PhiCmdHeader* header)
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
	PhiStatus status = PhiReadCommandData(reader, &command, sizeof(command));
	if(status != PHI_STATUS_OK)
		return status;

	if(command.src_memory == 0 || command.dst_memory == 0)
		return PHI_STATUS_INVALID_HANDLE;

	void* dst = (void*)((uintptr_t)command.dst_memory + (uintptr_t)command.dst_offset);
	const void* src = (const void*)((uintptr_t)command.src_memory + (uintptr_t)command.src_offset);

	memcpy(dst, src, (size_t)command.size);

	return PHI_STATUS_OK;
}

static PhiStatus FillBuffer(PhiCommandReader* reader)
{
	PhiCmdFillBuffer command;
	PhiStatus status = PhiReadCommandData(reader, &command, sizeof(command));
	if(status != PHI_STATUS_OK)
		return status;

	if(command.memory == 0)
		return PHI_STATUS_INVALID_HANDLE;

	uint32_t* dst = (uint32_t*)((uintptr_t)command.memory + (uintptr_t)command.offset);

	for(; command.size >= 4; command.size -= 4, dst++)
		*dst = command.data;

	return PHI_STATUS_OK;
}

PhiStatus PhiExecuteBufferCommand(PhiCommandReader* reader, const PhiCmdHeader* header)
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
