#ifndef APE_PHI_IMAGE_H
#define APE_PHI_IMAGE_H

#include <CommandBuffer.h>

int IsImageCommand(const PhiCmdHeader* header);
PhiStatus ExecuteImageCommand(PhiCommandReader* reader, const PhiCmdHeader* header);

#endif
