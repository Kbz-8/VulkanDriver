#ifndef APE_PHI_MEMORY_H
#define APE_PHI_MEMORY_H

#include <Daemon.h>

int HandleAllocMemory(scif_epd_t endpoint, const PhiMessageHeader* header);
int HandleFreeMemory(scif_epd_t endpoint, const PhiMessageHeader* header);

#endif
