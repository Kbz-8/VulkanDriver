#include <CommandBuffer.h>
#include <Logger.h>

#include <Buffer.h>
#include <Image.h>

#include <string.h>

static const char* CommandName[] = {
	"CopyBuffer", "FillBuffer", "CopyBufferToImage", "CopyImageToBuffer", "CopyImage",
};

PhiStatus ReadCommandData(PhiCommandReader* reader, void* data, uint64_t size)
{
	if(reader->remaining < size)
		return PHI_STATUS_BAD_MESSAGE;

	if(reader->memory != NULL)
	{
		memcpy(data, reader->memory, (size_t)size);
		reader->memory += (size_t)size;
	}
	else if(ReadAll(reader->endpoint, data, (size_t)size) < 0)
	{
		return PHI_STATUS_BAD_MESSAGE;
	}

	reader->remaining -= size;
	return PHI_STATUS_OK;
}

int DrainCommandReader(PhiCommandReader* reader)
{
	if(reader->remaining == 0)
		return 0;

	if(reader->memory != NULL)
	{
		reader->memory += (size_t)reader->remaining;
		reader->remaining = 0;
		return 0;
	}

	int result = DrainPayload(reader->endpoint, reader->remaining);
	reader->remaining = 0;
	return result;
}

static PhiStatus ReadCommandHeader(PhiCommandReader* reader, PhiCmdHeader* command_header)
{
	PhiStatus status = ReadCommandData(reader, command_header, sizeof(*command_header));
	if(status != PHI_STATUS_OK)
		return status;

	if(command_header->magic != PHI_COMMAND_MAGIC)
		return PHI_STATUS_BAD_MESSAGE;

	return PHI_STATUS_OK;
}

static PhiStatus ExecuteCommand(PhiCommandReader* reader, const PhiCmdHeader* command_header)
{
	if(IsBufferCommand(command_header))
		return ExecuteBufferCommand(reader, command_header);

	if(IsImageCommand(command_header))
		return ExecuteImageCommand(reader, command_header);

	return PHI_STATUS_BAD_MESSAGE;
}

static PhiStatus ExecuteCommands(PhiCommandReader* reader, uint64_t cmd_count)
{
	PhiStatus status = PHI_STATUS_OK;

	for(uint64_t cmd_index = 0; cmd_index < cmd_count; ++cmd_index)
	{
		PhiCmdHeader cmd_header;
		status = ReadCommandHeader(reader, &cmd_header);
		if(status != PHI_STATUS_OK)
			break;

		status = ExecuteCommand(reader, &cmd_header);
		if(status != PHI_STATUS_OK)
		{
			const size_t command_name_count = sizeof(CommandName) / sizeof(CommandName[0]);
			const char* command_name = cmd_header.type < command_name_count ? CommandName[cmd_header.type] : "Unknown";
			LogErrorFmt("Command %s execution failed: %s", command_name, StatusName[status]);
			break;
		}
	}

	return status;
}

PhiStatus ExecuteCommandBuffer(const void* data, uint64_t size, uint64_t cmd_count)
{
	PhiCommandReader reader = {
		.endpoint = PHI_ENDPOINT_INVALID,
		.memory = data,
		.remaining = size,
	};

	const PhiStatus status = ExecuteCommands(&reader, cmd_count);
	if(status != PHI_STATUS_OK)
		return status;

	return reader.remaining == 0 ? PHI_STATUS_OK : PHI_STATUS_BAD_MESSAGE;
}

int HandleWorkExecution(PhiEndpoint endpoint, const PhiMessageHeader* header)
{
	PhiWorkExecutionRequest request;
	PhiResultReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
	};

	if(header->payload_size < sizeof(request))
	{
		if(DrainPayload(endpoint, header->payload_size) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}
	if(ReadAll(endpoint, &request, sizeof(request)) < 0)
		return -1;

	PhiCommandReader reader = {
		.endpoint = endpoint,
		.memory = NULL,
		.remaining = header->payload_size - sizeof(request),
	};

	if(reader.remaining != request.command_buffer_size)
	{
		if(DrainCommandReader(&reader) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	reply.result.status = ExecuteCommands(&reader, request.cmd_count);

	if(reader.remaining > 0 && DrainCommandReader(&reader) < 0)
		return -1;

	return SendReply(endpoint, header, &reply, sizeof(reply));
}
