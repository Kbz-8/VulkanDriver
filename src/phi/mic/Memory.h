#ifndef APE_PHI_MEMORY_H
#define APE_PHI_MEMORY_H

#include <Daemon.h>

int HandleAllocMemory(PhiEndpoint endpoint, const PhiMessageHeader* header);
int HandleFreeMemory(PhiEndpoint endpoint, const PhiMessageHeader* header);

#endif
