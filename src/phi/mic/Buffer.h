#ifndef APE_PHI_BUFFER_H
#define APE_PHI_BUFFER_H

#include <CommandBuffer.h>

int IsBufferCommand(const PhiCmdHeader* header);
PhiStatus ExecuteBufferCommand(PhiCommandReader* reader, const PhiCmdHeader* header);

#endif
