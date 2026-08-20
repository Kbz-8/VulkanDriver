#include <Blitter.h>
#include <Memory.h>

PhiStatus BlitImage(const PhiCmdBlitImage* command)
{
	const Memory* src_memory = (const Memory*)(uintptr_t)command->src_memory;
	Memory* dst_memory = (Memory*)(uintptr_t)command->dst_memory;

	for(uint32_t layer = 0; layer < command->layer_count; ++layer)
	{
	}

	return PHI_STATUS_OK;
}
