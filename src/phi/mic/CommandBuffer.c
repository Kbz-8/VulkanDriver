#include <CommandBuffer.h>

#include <Buffer.h>

PhiStatus PhiReadCommandData(PhiCommandReader* reader, void* data, uint64_t size)
{
	if(reader->remaining < size)
		return PHI_STATUS_BAD_MESSAGE;

	if(ReadAll(reader->endpoint, data, (size_t)size) < 0)
		return PHI_STATUS_BAD_MESSAGE;

	reader->remaining -= size;
	return PHI_STATUS_OK;
}

int PhiDrainCommandReader(PhiCommandReader* reader)
{
	if(reader->remaining == 0)
		return 0;

	int result = DrainPayload(reader->endpoint, reader->remaining);
	reader->remaining = 0;
	return result;
}

static PhiStatus ReadCommandHeader(PhiCommandReader* reader, PhiCmdHeader* command_header)
{
	PhiStatus status = PhiReadCommandData(reader, command_header, sizeof(*command_header));
	if(status != PHI_STATUS_OK)
		return status;

	if(command_header->magic != PHI_COMMAND_MAGIC)
		return PHI_STATUS_BAD_MESSAGE;

	return PHI_STATUS_OK;
}

static PhiStatus ExecuteCommand(PhiCommandReader* reader, const PhiCmdHeader* command_header)
{
	if(PhiIsBufferCommand(command_header))
		return PhiExecuteBufferCommand(reader, command_header);

	return PHI_STATUS_BAD_MESSAGE;
}

int HandleWorkExecution(scif_epd_t endpoint, const PhiMessageHeader* header)
{
	PhiWorkExecutionRequest request;
	PhiWorkExecutionReply reply = {
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
		.remaining = header->payload_size - sizeof(request),
	};

	if(reader.remaining != request.command_buffer_size)
	{
		if(PhiDrainCommandReader(&reader) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	for(uint64_t cmd_index = 0; cmd_index < request.cmd_count; ++cmd_index)
	{
		PhiCmdHeader cmd_header;
		reply.result.status = ReadCommandHeader(&reader, &cmd_header);
		if(reply.result.status != PHI_STATUS_OK)
			break;

		reply.result.status = ExecuteCommand(&reader, &cmd_header);
		if(reply.result.status != PHI_STATUS_OK)
			break;
	}

	if(reader.remaining > 0 && PhiDrainCommandReader(&reader) < 0)
		return -1;

	return SendReply(endpoint, header, &reply, sizeof(reply));
}
