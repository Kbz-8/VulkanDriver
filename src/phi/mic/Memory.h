#ifndef APE_PHI_MEMORY_H
#define APE_PHI_MEMORY_H

#include <Daemon.h>

typedef enum MemoryType
{
	PHI_MEMORY_LOCAL,
	PHI_MEMORY_HOST_MAPPED,
} MemoryType;

typedef struct Memory
{
	MemoryType type;

	void* ptr;

	uint64_t size;
	uint64_t scif_size;

	off_t scif_offset;
} Memory;

int HandleNewMemory(PhiEndpoint endpoint, const PhiMessageHeader* header);
int HandleDestroyMemory(PhiEndpoint endpoint, const PhiMessageHeader* header);

#endif
