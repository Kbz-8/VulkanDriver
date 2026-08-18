#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <Logger.h>
#include <Memory.h>

static size_t AlignUp(size_t value, size_t alignment)
{
	return (value + alignment - 1) & ~(alignment - 1);
}

static Memory* MapHostMemory(PhiEndpoint epd, const PhiMapHostMemoryRequest* request)
{
	void* ptr = scif_mmap(NULL, request->scif_size, PROT_READ | PROT_WRITE, 0, epd, request->scif_offset);

	if(ptr == MAP_FAILED)
	{
		PhiLogErrorFmt("Failed to map host memory: %s", strerror(errno));
		return NULL;
	}

	Memory* memory = malloc(sizeof(*memory));
	if(!memory)
	{
		scif_munmap(ptr, request->scif_size);
		PhiLogError("Failed to allocate memory");
		return NULL;
	}

	memory->type = PHI_MEMORY_HOST_MAPPED;
	memory->ptr = ptr;
	memory->size = request->size;
	memory->scif_size = request->scif_size;

	return memory;
}

static Memory* AllocMemory(PhiEndpoint epd, const PhiAllocMemoryRequest* request)
{
	Memory* memory = (Memory*)malloc(sizeof(Memory) + PHI_MEMORY_ALIGNMENT + request->size);

	if(!memory)
		return NULL;

	memory->type = PHI_MEMORY_LOCAL;
	memory->ptr = (void*)AlignUp((uintptr_t)memory + sizeof(Memory), PHI_MEMORY_ALIGNMENT);
	memory->size = request->size;
	memory->scif_size = 0;

	return memory;
}

int HandleNewMemory(PhiEndpoint endpoint, const PhiMessageHeader* header)
{
	PhiNewMemoryReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
		.remote_handle = 0,
		.size = 0,
	};

	if(header->payload_size != sizeof(PhiAllocMemoryRequest) && header->payload_size != sizeof(PhiMapHostMemoryRequest))
	{
		if(DrainPayload(endpoint, header->payload_size) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	Memory* memory = NULL;

	if(header->type == PHI_PACKET_ALLOC_MEMORY)
	{
		PhiAllocMemoryRequest request;
		if(ReadAll(endpoint, &request, sizeof(request)) < 0)
			return -1;
		memory = AllocMemory(endpoint, &request);
		if(memory == NULL)
			PhiLogErrorFmt("Failed to allocate %zu bytes", (size_t)request.size);
		else
			PhiLogInfoFmt("Allocated %llu bytes to handle 0x%X", request.size, (uintptr_t)memory);
	}
	else if(header->type == PHI_PACKET_MAP_HOST_MEMORY)
	{
		PhiMapHostMemoryRequest request;
		if(ReadAll(endpoint, &request, sizeof(request)) < 0)
			return -1;
		memory = MapHostMemory(endpoint, &request);
		if(memory == NULL)
			reply.result.status = PHI_STATUS_MAP_HOST_MEMORY_FAILED;
		else
			PhiLogInfoFmt("Mapped host memory to handle 0x%X", (uint64_t)(uintptr_t)memory);
	}

	if(memory != NULL)
	{
		reply.remote_handle = (uint64_t)(uintptr_t)memory;
		reply.size = memory->size;
	}
	else if(reply.result.status == PHI_STATUS_OK)
		reply.result.status = PHI_STATUS_OUT_OF_MEMORY;

	return SendReply(endpoint, header, &reply, sizeof(reply));
}

int HandleDestroyMemory(PhiEndpoint endpoint, const PhiMessageHeader* header)
{
	PhiDestroyMemoryRequest request;
	PhiResultReply reply = {
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
		const Memory* memory = (const Memory*)(uintptr_t)request.remote_handle;

		if(memory->type == PHI_MEMORY_LOCAL)
			free((void*)memory);
		else if(memory->type == PHI_MEMORY_HOST_MAPPED)
			scif_munmap((void*)memory->ptr, memory->size);

		PhiLogInfoFmt("Destroyed %s memory handle 0x%X",
		              memory->type == PHI_MEMORY_LOCAL ? "local" : "host-mapped",
		              request.remote_handle);
	}

	return SendReply(endpoint, header, &reply, sizeof(reply));
}
