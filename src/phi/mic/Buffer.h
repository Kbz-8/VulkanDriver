#ifndef APE_PHI_BUFFER_H
#define APE_PHI_BUFFER_H

#include <CommandBuffer.h>

int PhiIsBufferCommand(const PhiCmdHeader* header);
PhiStatus PhiExecuteBufferCommand(PhiCommandReader* reader, const PhiCmdHeader* header);

#endif
