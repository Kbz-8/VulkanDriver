#include <Daemon.h>
#include <Logger.h>
#include <Memory.h>

static int HandleHello(scif_epd_t endpoint, const PhiMessageHeader* header)
{
	PhiHelloRequest request;
	PhiHelloReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
		.device_protocol_version = PHI_PROTOCOL_VERSION,
		.pointer_bits = (uint32_t)(sizeof(void *) * 8u),
	};

	if(header->payload_size != sizeof(request))
	{
		if(DrainPayload(endpoint, header->payload_size) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	if(ReadAll(endpoint, &request, sizeof(request)) < 0)
		return -1;

	if(request.host_protocol_version != PHI_PROTOCOL_VERSION)
		reply.result.status = PHI_STATUS_UNSUPPORTED_VERSION;

	return SendReply(endpoint, header, &reply, sizeof(reply));
}

scif_epd_t StartDaemon()
{
	PhiLogInfo("Starting the daemon...");

	scif_epd_t endpoint = scif_open();
	if(endpoint < 0)
	{
		PhiLogError("Failed to create SCIF endpoint");
		return 0;
	}

	if(scif_bind(endpoint, PHI_SCIF_PORT) < 0)
	{
		PhiLogError("Failed to bind SCIF port");
		scif_close(endpoint);
		return 0;
	}

	if(scif_listen(endpoint, 1) < 0)
	{
		PhiLogError("Could not listen to SCIF port");
		scif_close(endpoint);
		return 0;
	}

	return endpoint;
}

void ShutdownDaemon(scif_epd_t endpoint)
{
	PhiLogInfo("Shuting down the daemon...");
	scif_close(endpoint);
}

int HandlePacket(scif_epd_t endpoint)
{
	for(;;)
	{
		PhiMessageHeader header;

		if(ReadAll(endpoint, &header, sizeof(header)) < 0)
			return -1;

		if(header.magic != PHI_PROTOCOL_MAGIC || header.version != PHI_PROTOCOL_VERSION)
		{
			if(DrainPayload(endpoint, header.payload_size) < 0)
				return -1;
			if(SendStatus(endpoint, &header, PHI_STATUS_BAD_MESSAGE) < 0)
				return -1;
			continue;
		}

		switch((PhiCommandType)header.type)
		{
			case PHI_COMMAND_HELLO:
				if(HandleHello(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_COMMAND_ALLOC_MEMORY:
				if(HandleAllocMemory(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_COMMAND_FREE_MEMORY:
				if(HandleFreeMemory(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_COMMAND_SHUTDOWN:
				if(DrainPayload(endpoint, header.payload_size) < 0)
					return -1;
				if(SendStatus(endpoint, &header, PHI_STATUS_OK) < 0)
					return -1;
				return 0;

			default:
				if(DrainPayload(endpoint, header.payload_size) < 0)
					return -1;
				if(SendStatus(endpoint, &header, PHI_STATUS_UNSUPPORTED_COMMAND) < 0)
					return -1;
				break;
		}
	}
}

int ReadAll(scif_epd_t endpoint, void* data, size_t size)
{
	uint8_t* bytes = data;
	size_t offset = 0;

	while(offset < size)
	{
		int got = scif_recv(endpoint, bytes + offset, size - offset, SCIF_RECV_BLOCK);
		if(got <= 0)
			return -1;
		offset += (size_t)got;
	}

	return 0;
}

int WriteAll(scif_epd_t endpoint, const void* data, size_t size)
{
	const uint8_t* bytes = data;
	size_t offset = 0;

	while(offset < size)
	{
		int sent = scif_send(endpoint, (void*)(bytes + offset), size - offset, SCIF_SEND_BLOCK);
		if(sent <= 0)
			return -1;
		offset += (size_t)sent;
	}

	return 0;
}

int SendReply(scif_epd_t endpoint, const PhiMessageHeader* request, const void* payload, uint64_t payload_size)
{
	PhiMessageHeader reply = {
		.magic = PHI_PROTOCOL_MAGIC,
		.version = PHI_PROTOCOL_VERSION,
		.type = request->type,
		.sequence = request->sequence,
		.payload_size = payload_size,
	};

	if(WriteAll(endpoint, &reply, sizeof(reply)) < 0)
		return -1;

	return WriteAll(endpoint, payload, (size_t)payload_size);
}

int SendStatus(scif_epd_t endpoint, const PhiMessageHeader* request, PhiStatus status)
{
	PhiFreeMemoryReply reply = {
		.result = {
			.status = status,
			.reserved = 0,
		},
	};

	return SendReply(endpoint, request, &reply, sizeof(reply));
}

int DrainPayload(scif_epd_t endpoint, uint64_t size)
{
	uint8_t buffer[256];

	while(size > 0)
	{
		size_t chunk = size < sizeof(buffer) ? (size_t)size : sizeof(buffer);
		if(ReadAll(endpoint, buffer, chunk) < 0)
			return -1;
		size -= chunk;
	}

	return 0;
}
