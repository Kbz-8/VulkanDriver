#ifndef APE_PHI_COMMAND_BUFFER_H
#define APE_PHI_COMMAND_BUFFER_H

#include <Daemon.h>

typedef struct PhiCommandReader
{
	PhiEndpoint endpoint;
	uint64_t remaining;
} PhiCommandReader;

int HandleWorkExecution(PhiEndpoint endpoint, const PhiMessageHeader* header);
int PhiDrainCommandReader(PhiCommandReader* reader);
PhiStatus PhiReadCommandData(PhiCommandReader* reader, void* data, uint64_t size);

#endif
