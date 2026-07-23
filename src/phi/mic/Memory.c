#include <stdlib.h>

#include <Logger.h>
#include <Memory.h>

int HandleAllocMemory(scif_epd_t endpoint, const PhiMessageHeader* header)
{
	PhiAllocMemoryRequest request;
	PhiAllocMemoryReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
		.remote_handle = 0,
		.size = 0,
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

	const void* memory = malloc((size_t)request.size);

	if(memory == NULL)
	{
		reply.result.status = PHI_STATUS_OUT_OF_MEMORY;
		PhiLogInfoFmt("Failed to allocate %zu bytes", (size_t)request.size);
	}
	else
	{
		reply.remote_handle = (uint64_t)(uintptr_t)memory;
		reply.size = request.size;
		PhiLogInfoFmt("Allocated %llu bytes to handle 0x%X", reply.size, reply.remote_handle);
	}

	return SendReply(endpoint, header, &reply, sizeof(reply));
}

int HandleFreeMemory(scif_epd_t endpoint, const PhiMessageHeader* header)
{
	PhiFreeMemoryRequest request;
	PhiFreeMemoryReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
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

	if(request.remote_handle == 0)
	{
		reply.result.status = PHI_STATUS_INVALID_HANDLE;
		PhiLogErrorFmt("Could not free memory: invalid handle 0x%X", request.remote_handle);
	}
	else
	{
		free((void*)(uintptr_t)request.remote_handle);
		PhiLogInfoFmt("Freed memory handle 0x%X", request.remote_handle);
	}

	return SendReply(endpoint, header, &reply, sizeof(reply));
}
