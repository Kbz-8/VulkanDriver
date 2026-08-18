#include <stddef.h>
#include <stdint.h>

#include <Image.h>
#include <Logger.h>
#include <Memory.h>

#include <avx/Avx.h>

static int GetRegionSpan(uint64_t row_pitch,
                         uint64_t slice_pitch,
                         uint64_t layer_pitch,
                         uint64_t row_size,
                         uint32_t row_count,
                         uint32_t slice_count,
                         uint32_t layer_count,
                         uint64_t* span)
{
	uint64_t result = 0;
	uint64_t term = 0;

	if(row_size == 0 || row_count == 0 || slice_count == 0 || layer_count == 0)
		return 0;

	if(row_count > 1)
	{
		if(__builtin_mul_overflow((uint64_t)row_count - 1, row_pitch, &term))
			return 0;
		if(__builtin_add_overflow(result, term, &result))
			return 0;
	}

	if(slice_count > 1)
	{
		if(__builtin_mul_overflow((uint64_t)slice_count - 1, slice_pitch, &term))
			return 0;
		if(__builtin_add_overflow(result, term, &result))
			return 0;
	}

	if(layer_count > 1)
	{
		if(__builtin_mul_overflow((uint64_t)layer_count - 1, layer_pitch, &term))
			return 0;
		if(__builtin_add_overflow(result, term, &result))
			return 0;
	}

	if(__builtin_add_overflow(result, row_size, &result))
		return 0;

	*span = result;
	return 1;
}

static inline int IsMemoryRangeValid(const Memory* memory, uint64_t offset, uint64_t size)
{
	if(memory == NULL)
		return 0;
	if(offset > memory->size)
		return 0;
	return size <= memory->size - offset;
}

static PhiStatus ValidateCopyCommand(const PhiCmdCopyImage* command, const Memory* src_memory, const Memory* dst_memory)
{
	uint64_t src_span;
	uint64_t dst_span;

	if(command->row_size == 0 || command->row_count == 0 || command->slice_count == 0 || command->layer_count == 0)
	{
		LogErrorFmt("Invalid image copy command: one of this arguments is zero: row_size=%lu row_count=%u slice_count=%u"
		            "layer_count=%u",
		            command->row_size,
		            command->row_count,
		            command->slice_count,
		            command->layer_count);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(command->row_count > 1)
	{
		if(command->src_row_pitch < command->row_size || command->dst_row_pitch < command->row_size)
		{
			LogErrorFmt("Invalid image copy command: row_size=%lu is larger than src_row_pitch=%lu or dst_row_pitch=%lu",
			            command->row_size,
			            command->src_row_pitch,
			            command->dst_row_pitch);
			return PHI_STATUS_INVALID_ARGUMENT;
		}
	}

	if(!GetRegionSpan(command->src_row_pitch,
	                  command->src_slice_pitch,
	                  command->src_layer_pitch,
	                  command->row_size,
	                  command->row_count,
	                  command->slice_count,
	                  command->layer_count,
	                  &src_span))
	{
		LogErrorFmt("Invalid image copy command: computed src region span is zero: src_row_pitch=%lu src_slice_pitch=%lu "
		            "src_layer_pitch=%lu",
		            command->src_row_pitch,
		            command->src_slice_pitch,
		            command->src_layer_pitch);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(!GetRegionSpan(command->dst_row_pitch,
	                  command->dst_slice_pitch,
	                  command->dst_layer_pitch,
	                  command->row_size,
	                  command->row_count,
	                  command->slice_count,
	                  command->layer_count,
	                  &dst_span))
	{
		LogErrorFmt("Invalid image copy command: computed dst region span is zero: dst_row_pitch=%lu dst_slice_pitch=%lu "
		            "dst_layer_pitch=%lu",
		            command->dst_row_pitch,
		            command->dst_slice_pitch,
		            command->dst_layer_pitch);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(!IsMemoryRangeValid(src_memory, command->src_offset, src_span))
	{
		LogErrorFmt("Invalid image copy command: src memory range is invalid: src_offset=%lu src_span=%lu",
		            command->src_offset,
		            src_span);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(!IsMemoryRangeValid(dst_memory, command->dst_offset, dst_span))
	{
		LogErrorFmt("Invalid image copy command: dst memory range is invalid: dst_offset=%lu dst_span=%lu",
		            command->dst_offset,
		            dst_span);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(command->src_offset > SIZE_MAX || command->dst_offset > SIZE_MAX || command->src_row_pitch > SIZE_MAX ||
	   command->dst_row_pitch > SIZE_MAX || command->src_slice_pitch > SIZE_MAX || command->dst_slice_pitch > SIZE_MAX ||
	   command->src_layer_pitch > SIZE_MAX || command->dst_layer_pitch > SIZE_MAX || command->row_size > SIZE_MAX)
	{
		LogErrorFmt(
		    "Invalid image copy command: size_t overflow: src_offset=%lu dst_offset=%lu src_row_pitch=%lu dst_row_pitch=%lu "
		    "src_slice_pitch=%lu dst_slice_pitch=%lu src_layer_pitch=%lu dst_layer_pitch=%lu row_size=%lu",
		    command->src_offset,
		    command->dst_offset,
		    command->src_row_pitch,
		    command->dst_row_pitch,
		    command->src_slice_pitch,
		    command->dst_slice_pitch,
		    command->src_layer_pitch,
		    command->dst_layer_pitch,
		    command->row_size);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	return PHI_STATUS_OK;
}

static inline int GetTightSliceSize(const PhiCmdCopyImage* command, uint64_t* slice_size)
{
	return !__builtin_mul_overflow(command->row_size, command->row_count, slice_size);
}

static inline int GetTightLayerSize(const PhiCmdCopyImage* command, uint64_t* layer_size)
{
	uint64_t slice_size;
	if(!GetTightSliceSize(command, &slice_size))
		return 0;
	return !__builtin_mul_overflow(slice_size, command->slice_count, layer_size);
}

static inline int GetTightCopySize(const PhiCmdCopyImage* command, uint64_t* copy_size)
{
	uint64_t layer_size;
	if(!GetTightLayerSize(command, &layer_size))
		return 0;
	return !__builtin_mul_overflow(layer_size, command->layer_count, copy_size);
}

static inline int RowsAreContiguous(const PhiCmdCopyImage* command)
{
	if(command->row_count <= 1)
		return 1;
	return command->src_row_pitch == command->row_size && command->dst_row_pitch == command->row_size;
}

static int SlicesAreContiguous(const PhiCmdCopyImage* command)
{
	uint64_t slice_size;

	if(!RowsAreContiguous(command))
		return 0;
	if(command->slice_count <= 1)
		return 1;
	if(!GetTightSliceSize(command, &slice_size))
		return 0;

	return command->src_slice_pitch == slice_size && command->dst_slice_pitch == slice_size;
}

static int LayersAreContiguous(const PhiCmdCopyImage* command)
{
	uint64_t layer_size;

	if(!SlicesAreContiguous(command))
		return 0;
	if(command->layer_count <= 1)
		return 1;
	if(!GetTightLayerSize(command, &layer_size))
		return 0;

	return command->src_layer_pitch == layer_size && command->dst_layer_pitch == layer_size;
}

static PhiStatus CopyImageRegion(const PhiCmdCopyImage* command)
{
	if(command->src_memory == 0)
	{
		LogError("Invalid src memory handle");
		return PHI_STATUS_INVALID_HANDLE;
	}
	if(command->dst_memory == 0)
	{
		LogError("Invalid dst memory handle");
		return PHI_STATUS_INVALID_HANDLE;
	}

	const Memory* src_memory = (const Memory*)(uintptr_t)command->src_memory;
	Memory* dst_memory = (Memory*)(uintptr_t)command->dst_memory;

	PhiStatus status = ValidateCopyCommand(command, src_memory, dst_memory);
	if(status != PHI_STATUS_OK)
		return status;

	const uint8_t* src = (const uint8_t*)src_memory->ptr + (size_t)command->src_offset;
	uint8_t* dst = (uint8_t*)dst_memory->ptr + (size_t)command->dst_offset;

	// Fast path: the entire region is tightly packed on both sides
	if(LayersAreContiguous(command))
	{
		uint64_t copy_size;

		if(!GetTightCopySize(command, &copy_size) || copy_size > SIZE_MAX)
		{
			LogErrorFmt("Invalid copy size: %lu", copy_size);
			return PHI_STATUS_INVALID_ARGUMENT;
		}

		AvxCopy(dst, src, (size_t)copy_size);

		return PHI_STATUS_OK;
	}

	// Second fast path: all slices inside each layer are contiguous, but layers themselves have padding
	if(SlicesAreContiguous(command))
	{
		uint64_t layer_size;

		if(!GetTightLayerSize(command, &layer_size) || layer_size > SIZE_MAX)
		{
			LogErrorFmt("Invalid layer size: %lu", layer_size);
			return PHI_STATUS_INVALID_ARGUMENT;
		}

		for(uint32_t layer = 0; layer < command->layer_count; ++layer)
		{
			const uint64_t src_layer_offset = (uint64_t)layer * command->src_layer_pitch;
			const uint64_t dst_layer_offset = (uint64_t)layer * command->dst_layer_pitch;

			AvxCopy(dst + (size_t)dst_layer_offset, src + (size_t)src_layer_offset, (size_t)layer_size);
		}

		return PHI_STATUS_OK;
	}

	// Third fast path: rows are tightly packed, so each slice is a single AVX copy
	if(RowsAreContiguous(command))
	{
		uint64_t slice_size;

		if(!GetTightSliceSize(command, &slice_size) || slice_size > SIZE_MAX)
		{
			LogErrorFmt("Invalid slice size: %lu", slice_size);
			return PHI_STATUS_INVALID_ARGUMENT;
		}

		for(uint32_t layer = 0; layer < command->layer_count; ++layer)
		{
			const uint64_t src_layer_offset = (uint64_t)layer * command->src_layer_pitch;
			const uint64_t dst_layer_offset = (uint64_t)layer * command->dst_layer_pitch;

			for(uint32_t slice = 0; slice < command->slice_count; ++slice)
			{
				const uint64_t src_slice_offset = src_layer_offset + (uint64_t)slice * command->src_slice_pitch;
				const uint64_t dst_slice_offset = dst_layer_offset + (uint64_t)slice * command->dst_slice_pitch;

				AvxCopy(dst + (size_t)dst_slice_offset, src + (size_t)src_slice_offset, (size_t)slice_size);
			}
		}

		return PHI_STATUS_OK;
	}

	// General path: only performs a pitched byte copy
	for(uint32_t layer = 0; layer < command->layer_count; ++layer)
	{
		const uint64_t src_layer_offset = (uint64_t)layer * command->src_layer_pitch;
		const uint64_t dst_layer_offset = (uint64_t)layer * command->dst_layer_pitch;

		for(uint32_t slice = 0; slice < command->slice_count; ++slice)
		{
			const uint64_t src_slice_offset = src_layer_offset + (uint64_t)slice * command->src_slice_pitch;
			const uint64_t dst_slice_offset = dst_layer_offset + (uint64_t)slice * command->dst_slice_pitch;

			for(uint32_t row = 0; row < command->row_count; ++row)
			{
				const uint64_t src_row_offset = src_slice_offset + (uint64_t)row * command->src_row_pitch;
				const uint64_t dst_row_offset = dst_slice_offset + (uint64_t)row * command->dst_row_pitch;

				AvxCopy(dst + (size_t)dst_row_offset, src + (size_t)src_row_offset, (size_t)command->row_size);
			}
		}
	}

	return PHI_STATUS_OK;
}

static PhiStatus ExecuteCopyImage(PhiCommandReader* reader)
{
	PhiCmdCopyImage command;

	PhiStatus status = ReadCommandData(reader, &command, sizeof(command));

	if(status != PHI_STATUS_OK)
		return status;

	return CopyImageRegion(&command);
}

int IsImageCommand(const PhiCmdHeader* header)
{
	switch((PhiCmdType)header->type)
	{
		case PHI_CMD_COPY_BUFFER_TO_IMAGE:
		case PHI_CMD_COPY_IMAGE_TO_BUFFER:
		case PHI_CMD_COPY_IMAGE:
			return 1;

		default:
			return 0;
	}
}

PhiStatus ExecuteImageCommand(PhiCommandReader* reader, const PhiCmdHeader* header)
{
	switch((PhiCmdType)header->type)
	{
		case PHI_CMD_COPY_BUFFER_TO_IMAGE:
		case PHI_CMD_COPY_IMAGE_TO_BUFFER:
		case PHI_CMD_COPY_IMAGE:
			return ExecuteCopyImage(reader);

		default:
			return PHI_STATUS_BAD_MESSAGE;
	}
}
