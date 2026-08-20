#ifndef APE_PHI_COMMAND_BUFFER_H
#define APE_PHI_COMMAND_BUFFER_H

#include <Daemon.h>

typedef struct PhiCommandReader
{
	PhiEndpoint endpoint;
	const uint8_t* memory;
	uint64_t remaining;
} PhiCommandReader;

int HandleWorkExecution(PhiEndpoint endpoint, const PhiMessageHeader* header);
int DrainCommandReader(PhiCommandReader* reader);
PhiStatus ExecuteCommandBuffer(const void* data, uint64_t size, uint64_t cmd_count);
PhiStatus ReadCommandData(PhiCommandReader* reader, void* data, uint64_t size);

#endif
