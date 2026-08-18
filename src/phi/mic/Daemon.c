#include "Protocol.h"
#include <CommandBuffer.h>
#include <Daemon.h>
#include <Logger.h>
#include <Memory.h>

static int HandleHello(PhiEndpoint endpoint, const PhiMessageHeader* header)
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

PhiEndpoint StartDaemon(void)
{
	PhiLogInfo("Starting the daemon...");

	PhiEndpoint endpoint = PhiTransportListen(PHI_TRANSPORT_PORT);
	if(endpoint == PHI_ENDPOINT_INVALID)
		PhiLogError("Could not listen on the Phi transport");

	PhiLogInfo("Daemon started");
	return endpoint;
}

void ShutdownDaemon(PhiEndpoint endpoint)
{
	PhiLogInfo("Shutting down the daemon...");
	PhiTransportClose(endpoint);
}

int HandlePacket(PhiEndpoint endpoint)
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

		switch((PhiPacketType)header.type)
		{
			case PHI_PACKET_HELLO:
				if(HandleHello(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_PACKET_MAP_HOST_MEMORY:
			case PHI_PACKET_ALLOC_MEMORY:
				if(HandleNewMemory(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_PACKET_DESTROY_MEMORY:
				if(HandleDestroyMemory(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_PACKET_WORK_EXECUTION:
				if(HandleWorkExecution(endpoint, &header) < 0)
					return -1;
				break;

			case PHI_PACKET_SHUTDOWN:
				if(DrainPayload(endpoint, header.payload_size) < 0)
					return -1;
				if(SendStatus(endpoint, &header, PHI_STATUS_OK) < 0)
					return -1;
				return 0;

			default:
				if(DrainPayload(endpoint, header.payload_size) < 0)
					return -1;
				if(SendStatus(endpoint, &header, PHI_STATUS_UNSUPPORTED_PACKET) < 0)
					return -1;
				break;
		}
	}
}

int ReadAll(PhiEndpoint endpoint, void* data, size_t size)
{
	uint8_t* bytes = data;
	size_t offset = 0;

	while(offset < size)
	{
		ssize_t got = PhiTransportReceive(endpoint, bytes + offset, size - offset);
		if(got <= 0)
			return -1;
		offset += (size_t)got;
	}

	return 0;
}

int WriteAll(PhiEndpoint endpoint, const void* data, size_t size)
{
	const uint8_t* bytes = data;
	size_t offset = 0;

	while(offset < size)
	{
		ssize_t sent = PhiTransportSend(endpoint, bytes + offset, size - offset);
		if(sent <= 0)
			return -1;
		offset += (size_t)sent;
	}

	return 0;
}

int SendReply(PhiEndpoint endpoint, const PhiMessageHeader* request, const void* payload, uint64_t payload_size)
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

int SendStatus(PhiEndpoint endpoint, const PhiMessageHeader* request, PhiStatus status)
{
	PhiResultReply reply = {
		.result = {
			.status = status,
			.reserved = 0,
		},
	};

	return SendReply(endpoint, request, &reply, sizeof(reply));
}

int DrainPayload(PhiEndpoint endpoint, uint64_t size)
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
