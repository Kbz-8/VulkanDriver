#include <BlitFormats.h>
#include <Blitter.h>
#include <Logger.h>
#include <Memory.h>
#include <WorkerPool.h>

#include <avx/Avx.h>

#include <stddef.h>
#include <stdint.h>

#define BLIT_WEIGHT_SCALE 1024.0f
#define BLIT_PARALLEL_MIN_PIXELS (256u * 1024u)
#define BLIT_TASK_TARGET_BYTES (64u * 1024u)
#define BLIT_MAX_GRAIN_ROWS 64u

enum
{
	PHI_FILTER_NEAREST = 0,
	PHI_FILTER_LINEAR = 1,
};

typedef PhiBlitFloat4 Color;
typedef PhiBlitFormatInfo FormatInfo;

typedef struct SampleCoordinate
{
	uint32_t lo;
	uint32_t hi;
	float factor;
} SampleCoordinate;

typedef struct BlitWork
{
	const PhiCmdBlitImage* command;
	const FormatInfo* src_info;
	const FormatInfo* dst_info;
	const uint8_t* src;
	uint8_t* dst;
	uint32_t row_count;
	uint64_t rows_per_layer;
} BlitWork;

static inline Color LerpColor(Color a, Color b, float factor)
{
	Color result;
	for(uint32_t component = 0; component < 4; ++component)
		result.values[component] = a.values[component] + (b.values[component] - a.values[component]) * factor;
	return result;
}

static inline double ClampCoordinate(float coordinate, uint32_t dimension)
{
	const double upper = (double)dimension - 0.5;

	if(coordinate < 0.5f)
		return 0.5;
	if((double)coordinate > upper)
		return upper;
	return (double)coordinate;
}

static inline uint32_t GetNearestCoordinate(float coordinate, uint32_t dimension)
{
	return (uint32_t)ClampCoordinate(coordinate, dimension);
}

static SampleCoordinate GetLinearCoordinate(float coordinate, uint32_t dimension)
{
	const double source = ClampCoordinate(coordinate, dimension) - 0.5;
	SampleCoordinate result;
	result.lo = (uint32_t)source;
	result.hi = result.lo + 1 < dimension ? result.lo + 1 : result.lo;
	result.factor = (float)(source - (double)result.lo);
	return result;
}

static inline uint32_t QuantizeBlitWeight(float factor)
{
	return (uint32_t)(factor * BLIT_WEIGHT_SCALE + 0.5f);
}

static Color ReadTexel(const uint8_t* src,
                       PhiFormat format,
                       uint32_t texel_size,
                       uint64_t row_pitch,
                       uint64_t slice_pitch,
                       uint32_t x,
                       uint32_t y,
                       uint32_t z)
{
	const uint64_t offset = (uint64_t)z * slice_pitch + (uint64_t)y * row_pitch + (uint64_t)x * texel_size;
	return PhiReadBlitFloat4(src + (size_t)offset, format);
}

static inline Color PrepareLinearSample(Color color,
                                        const PhiCmdBlitImage* command,
                                        const FormatInfo* src_info,
                                        int* apply_srgb_conversion)
{
	if(command->allow_srgb_conversion && src_info->is_srgb)
	{
		*apply_srgb_conversion = 0;
		return PhiConvertBlitFloat4(color, (PhiFormat)command->src_format, (PhiFormat)command->dst_format, 1, 1);
	}
	return color;
}

static Color
Sample(const uint8_t* src, const PhiCmdBlitImage* command, const FormatInfo* src_info, float x, float y, float z, int filter_3d)
{
	const PhiFormat format = (PhiFormat)command->src_format;
	int apply_srgb_conversion = 1;

	if(command->filter == PHI_FILTER_NEAREST)
	{
		Color color = ReadTexel(src,
		                        format,
		                        src_info->texel_size,
		                        command->src_row_pitch,
		                        command->src_slice_pitch,
		                        GetNearestCoordinate(x, command->src_width),
		                        GetNearestCoordinate(y, command->src_height),
		                        GetNearestCoordinate(z, command->src_depth));
		return PhiConvertBlitFloat4(color, format, (PhiFormat)command->dst_format, command->allow_srgb_conversion, 1);
	}

	const SampleCoordinate sample_x = GetLinearCoordinate(x, command->src_width);
	const SampleCoordinate sample_y = GetLinearCoordinate(y, command->src_height);
	const SampleCoordinate sample_z = GetLinearCoordinate(z, command->src_depth);

	Color color_0_0 = ReadTexel(src,
	                            format,
	                            src_info->texel_size,
	                            command->src_row_pitch,
	                            command->src_slice_pitch,
	                            sample_x.lo,
	                            sample_y.lo,
	                            sample_z.lo);
	Color color_0_1 = ReadTexel(src,
	                            format,
	                            src_info->texel_size,
	                            command->src_row_pitch,
	                            command->src_slice_pitch,
	                            sample_x.hi,
	                            sample_y.lo,
	                            sample_z.lo);
	Color color_1_0 = ReadTexel(src,
	                            format,
	                            src_info->texel_size,
	                            command->src_row_pitch,
	                            command->src_slice_pitch,
	                            sample_x.lo,
	                            sample_y.hi,
	                            sample_z.lo);
	Color color_1_1 = ReadTexel(src,
	                            format,
	                            src_info->texel_size,
	                            command->src_row_pitch,
	                            command->src_slice_pitch,
	                            sample_x.hi,
	                            sample_y.hi,
	                            sample_z.lo);
	color_0_0 = PrepareLinearSample(color_0_0, command, src_info, &apply_srgb_conversion);
	color_0_1 = PrepareLinearSample(color_0_1, command, src_info, &apply_srgb_conversion);
	color_1_0 = PrepareLinearSample(color_1_0, command, src_info, &apply_srgb_conversion);
	color_1_1 = PrepareLinearSample(color_1_1, command, src_info, &apply_srgb_conversion);

	const Color row_0 = LerpColor(color_0_0, color_0_1, sample_x.factor);
	const Color row_1 = LerpColor(color_1_0, color_1_1, sample_x.factor);
	const Color slice_0 = LerpColor(row_0, row_1, sample_y.factor);

	if(!filter_3d)
		return PhiConvertBlitFloat4(
		    slice_0, format, (PhiFormat)command->dst_format, command->allow_srgb_conversion, apply_srgb_conversion);

	Color color_0_0_1 = ReadTexel(src,
	                              format,
	                              src_info->texel_size,
	                              command->src_row_pitch,
	                              command->src_slice_pitch,
	                              sample_x.lo,
	                              sample_y.lo,
	                              sample_z.hi);
	Color color_0_1_1 = ReadTexel(src,
	                              format,
	                              src_info->texel_size,
	                              command->src_row_pitch,
	                              command->src_slice_pitch,
	                              sample_x.hi,
	                              sample_y.lo,
	                              sample_z.hi);
	Color color_1_0_1 = ReadTexel(src,
	                              format,
	                              src_info->texel_size,
	                              command->src_row_pitch,
	                              command->src_slice_pitch,
	                              sample_x.lo,
	                              sample_y.hi,
	                              sample_z.hi);
	Color color_1_1_1 = ReadTexel(src,
	                              format,
	                              src_info->texel_size,
	                              command->src_row_pitch,
	                              command->src_slice_pitch,
	                              sample_x.hi,
	                              sample_y.hi,
	                              sample_z.hi);
	color_0_0_1 = PrepareLinearSample(color_0_0_1, command, src_info, &apply_srgb_conversion);
	color_0_1_1 = PrepareLinearSample(color_0_1_1, command, src_info, &apply_srgb_conversion);
	color_1_0_1 = PrepareLinearSample(color_1_0_1, command, src_info, &apply_srgb_conversion);
	color_1_1_1 = PrepareLinearSample(color_1_1_1, command, src_info, &apply_srgb_conversion);

	const Color row_0_1 = LerpColor(color_0_0_1, color_0_1_1, sample_x.factor);
	const Color row_1_1 = LerpColor(color_1_0_1, color_1_1_1, sample_x.factor);
	const Color slice_1 = LerpColor(row_0_1, row_1_1, sample_y.factor);
	Color color = LerpColor(slice_0, slice_1, sample_z.factor);
	return PhiConvertBlitFloat4(
	    color, format, (PhiFormat)command->dst_format, command->allow_srgb_conversion, apply_srgb_conversion);
}

static inline int IsMemoryRangeValid(const Memory* memory, uint64_t offset, uint64_t size)
{
	if(memory == NULL || memory->ptr == NULL || offset > memory->size)
		return 0;
	return size <= memory->size - offset;
}

static int ComputeRegionSpan(uint64_t row_pitch,
                             uint64_t slice_pitch,
                             uint64_t layer_pitch,
                             uint64_t row_size,
                             uint32_t row_count,
                             uint32_t slice_count,
                             uint32_t layer_count,
                             uint64_t* span)
{
	uint64_t result = 0;
	uint64_t term;

	if(row_size == 0 || row_count == 0 || slice_count == 0 || layer_count == 0)
		return 0;
	if(__builtin_mul_overflow((uint64_t)row_count - 1, row_pitch, &term) || __builtin_add_overflow(result, term, &result))
		return 0;
	if(__builtin_mul_overflow((uint64_t)slice_count - 1, slice_pitch, &term) || __builtin_add_overflow(result, term, &result))
		return 0;
	if(__builtin_mul_overflow((uint64_t)layer_count - 1, layer_pitch, &term) || __builtin_add_overflow(result, term, &result))
		return 0;
	if(__builtin_add_overflow(result, row_size, &result))
		return 0;

	*span = result;
	return 1;
}

static PhiStatus ValidateCommand(const PhiCmdBlitImage* command,
                                 const Memory* src_memory,
                                 const Memory* dst_memory,
                                 const FormatInfo* src_info,
                                 const FormatInfo* dst_info)
{
	if(command->src_width == 0 || command->src_height == 0 || command->src_depth == 0 || command->layer_count == 0 ||
	   command->dst_x0 < 0 || command->dst_y0 < 0 || command->dst_z0 < 0 || command->dst_x1 <= command->dst_x0 ||
	   command->dst_y1 <= command->dst_y0 || command->dst_z1 <= command->dst_z0 || command->filter > PHI_FILTER_LINEAR ||
	   !__builtin_isfinite(command->src_x0) || !__builtin_isfinite(command->src_y0) || !__builtin_isfinite(command->src_z0) ||
	   !__builtin_isfinite(command->step_x) || !__builtin_isfinite(command->step_y) || !__builtin_isfinite(command->step_z))
	{
		LogError("Invalid blit image dimensions, coordinates, or filter");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(command->src_offset > SIZE_MAX || command->dst_offset > SIZE_MAX || command->src_row_pitch > SIZE_MAX ||
	   command->src_slice_pitch > SIZE_MAX || command->src_layer_pitch > SIZE_MAX || command->dst_row_pitch > SIZE_MAX ||
	   command->dst_slice_pitch > SIZE_MAX || command->dst_layer_pitch > SIZE_MAX)
	{
		LogError("Blit image address does not fit in size_t");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	uint64_t src_row_size;
	uint64_t src_slice_span;
	uint64_t src_volume_span;
	uint64_t src_span;
	if(__builtin_mul_overflow((uint64_t)command->src_width, src_info->texel_size, &src_row_size) ||
	   command->src_row_pitch < src_row_size ||
	   !ComputeRegionSpan(command->src_row_pitch, 0, 0, src_row_size, command->src_height, 1, 1, &src_slice_span) ||
	   command->src_slice_pitch < src_slice_span ||
	   !ComputeRegionSpan(command->src_row_pitch,
	                      command->src_slice_pitch,
	                      0,
	                      src_row_size,
	                      command->src_height,
	                      command->src_depth,
	                      1,
	                      &src_volume_span) ||
	   command->src_layer_pitch < src_volume_span ||
	   !ComputeRegionSpan(command->src_row_pitch,
	                      command->src_slice_pitch,
	                      command->src_layer_pitch,
	                      src_row_size,
	                      command->src_height,
	                      command->src_depth,
	                      command->layer_count,
	                      &src_span))
	{
		LogError("Invalid blit image source pitches");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	uint64_t dst_row_size;
	uint64_t dst_slice_span;
	uint64_t dst_volume_span;
	uint64_t dst_span;
	if(__builtin_mul_overflow((uint64_t)(uint32_t)command->dst_x1, dst_info->texel_size, &dst_row_size) ||
	   command->dst_row_pitch < dst_row_size ||
	   !ComputeRegionSpan(command->dst_row_pitch, 0, 0, dst_row_size, (uint32_t)command->dst_y1, 1, 1, &dst_slice_span) ||
	   command->dst_slice_pitch < dst_slice_span ||
	   !ComputeRegionSpan(command->dst_row_pitch,
	                      command->dst_slice_pitch,
	                      0,
	                      dst_row_size,
	                      (uint32_t)command->dst_y1,
	                      (uint32_t)command->dst_z1,
	                      1,
	                      &dst_volume_span) ||
	   command->dst_layer_pitch < dst_volume_span ||
	   !ComputeRegionSpan(command->dst_row_pitch,
	                      command->dst_slice_pitch,
	                      command->dst_layer_pitch,
	                      dst_row_size,
	                      (uint32_t)command->dst_y1,
	                      (uint32_t)command->dst_z1,
	                      command->layer_count,
	                      &dst_span))
	{
		LogError("Invalid blit image destination pitches");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	if(src_span > SIZE_MAX || dst_span > SIZE_MAX || !IsMemoryRangeValid(src_memory, command->src_offset, src_span) ||
	   !IsMemoryRangeValid(dst_memory, command->dst_offset, dst_span))
	{
		LogError("Blit image memory range is invalid");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	return PHI_STATUS_OK;
}

static inline void BlitScalarPixel(uint8_t* dst,
                                   const uint8_t* src,
                                   const PhiCmdBlitImage* command,
                                   const FormatInfo* src_info,
                                   const FormatInfo* dst_info,
                                   float source_x,
                                   float source_y,
                                   float source_z,
                                   int filter_3d)
{
	if(src_info->is_integer && dst_info->is_integer)
	{
		const uint32_t x = GetNearestCoordinate(source_x, command->src_width);
		const uint32_t y = GetNearestCoordinate(source_y, command->src_height);
		const uint32_t z = GetNearestCoordinate(source_z, command->src_depth);
		const uint64_t offset =
		    (uint64_t)z * command->src_slice_pitch + (uint64_t)y * command->src_row_pitch + (uint64_t)x * src_info->texel_size;
		const PhiBlitInt4 color = PhiReadBlitInt4(src + (size_t)offset, (PhiFormat)command->src_format);
		PhiWriteBlitInt4(color, dst, (PhiFormat)command->dst_format);
		return;
	}

	const Color color = Sample(src, command, src_info, source_x, source_y, source_z, filter_3d);
	PhiWriteBlitFloat4(color, dst, (PhiFormat)command->dst_format);
}

static void BlitRow(uint8_t* dst,
                    const uint8_t* src,
                    const PhiCmdBlitImage* command,
                    const FormatInfo* src_info,
                    const FormatInfo* dst_info,
                    float source_y,
                    float source_z)
{
	const uint32_t pixel_count = (uint32_t)(command->dst_x1 - command->dst_x0);
	const float first_source_x = command->src_x0 + (float)command->dst_x0 * command->step_x;
	const int filter_3d = command->step_z != 1.0f;

	// Fast path
	if(command->filter == PHI_FILTER_NEAREST && command->src_format == command->dst_format && command->step_x == 1.0f &&
	   !(command->allow_srgb_conversion && (src_info->is_srgb || dst_info->is_srgb)) && first_source_x >= 0.0f &&
	   first_source_x + (float)(pixel_count - 1) < (float)command->src_width)
	{
		const uint32_t source_texel_x = GetNearestCoordinate(first_source_x, command->src_width);
		const uint32_t source_texel_y = GetNearestCoordinate(source_y, command->src_height);
		const uint32_t source_texel_z = GetNearestCoordinate(source_z, command->src_depth);
		const uint64_t source_offset = (uint64_t)source_texel_z * command->src_slice_pitch +
		                               (uint64_t)source_texel_y * command->src_row_pitch +
		                               (uint64_t)source_texel_x * src_info->texel_size;
		AvxCopy(dst, src + (size_t)source_offset, (size_t)pixel_count * src_info->texel_size);
		return;
	}

	uint32_t processed = 0;
	if(src_info->vector_unorm8x4 && dst_info->vector_unorm8x4 && command->src_width <= INT32_MAX)
	{
		while(processed < pixel_count && ((uintptr_t)(dst + (size_t)processed * 4) & 63) != 0)
		{
			const int32_t destination_x = command->dst_x0 + (int32_t)processed;
			const float source_x = command->src_x0 + (float)destination_x * command->step_x;
			BlitScalarPixel(
			    dst + (size_t)processed * 4, src, command, src_info, dst_info, source_x, source_y, source_z, filter_3d);
			++processed;
		}

		_Alignas(64) uint32_t source_x0[16];
		_Alignas(64) uint32_t source_x1[16];
		_Alignas(64) uint32_t weights_x[16];

		if(command->filter == PHI_FILTER_NEAREST)
		{
			const uint32_t source_row = GetNearestCoordinate(source_y, command->src_height);
			const uint32_t source_slice = GetNearestCoordinate(source_z, command->src_depth);
			const uint64_t source_offset =
			    (uint64_t)source_slice * command->src_slice_pitch + (uint64_t)source_row * command->src_row_pitch;
			const uint8_t* src_row = src + (size_t)source_offset;

			while(pixel_count - processed >= 16)
			{
				for(uint32_t lane = 0; lane < 16; ++lane)
				{
					const int32_t destination_x = command->dst_x0 + (int32_t)(processed + lane);
					const float source_x = command->src_x0 + (float)destination_x * command->step_x;
					source_x0[lane] = GetNearestCoordinate(source_x, command->src_width);
				}

				AvxBlitNearestUnorm8x4(
				    dst + (size_t)processed * 4, src_row, source_x0, command->src_format, command->dst_format);
				processed += 16;
			}
		}
		else if(!filter_3d)
		{
			const SampleCoordinate sample_y = GetLinearCoordinate(source_y, command->src_height);
			const SampleCoordinate sample_z = GetLinearCoordinate(source_z, command->src_depth);
			const uint64_t slice_offset = (uint64_t)sample_z.lo * command->src_slice_pitch;
			const uint8_t* src_row_0 = src + (size_t)(slice_offset + (uint64_t)sample_y.lo * command->src_row_pitch);
			const uint8_t* src_row_1 = src + (size_t)(slice_offset + (uint64_t)sample_y.hi * command->src_row_pitch);
			const uint32_t weight_y = QuantizeBlitWeight(sample_y.factor);

			while(pixel_count - processed >= 16)
			{
				for(uint32_t lane = 0; lane < 16; ++lane)
				{
					const int32_t destination_x = command->dst_x0 + (int32_t)(processed + lane);
					const float source_x = command->src_x0 + (float)destination_x * command->step_x;
					const SampleCoordinate sample_x = GetLinearCoordinate(source_x, command->src_width);
					source_x0[lane] = sample_x.lo;
					source_x1[lane] = sample_x.hi;
					weights_x[lane] = QuantizeBlitWeight(sample_x.factor);
				}

				AvxBlitLinearUnorm8x4(dst + (size_t)processed * 4,
				                      src_row_0,
				                      src_row_1,
				                      source_x0,
				                      source_x1,
				                      weights_x,
				                      weight_y,
				                      command->src_format,
				                      command->dst_format);
				processed += 16;
			}
		}
	}

	while(processed < pixel_count)
	{
		const int32_t destination_x = command->dst_x0 + (int32_t)processed;
		const float source_x = command->src_x0 + (float)destination_x * command->step_x;
		BlitScalarPixel(dst + (size_t)processed * dst_info->texel_size,
		                src,
		                command,
		                src_info,
		                dst_info,
		                source_x,
		                source_y,
		                source_z,
		                filter_3d);
		++processed;
	}
}

static void BlitRows(void* context, uint64_t begin, uint64_t end)
{
	const BlitWork* work = context;
	const PhiCmdBlitImage* command = work->command;

	for(uint64_t row = begin; row < end; ++row)
	{
		const uint32_t layer = (uint32_t)(row / work->rows_per_layer);
		const uint64_t row_in_layer = row - (uint64_t)layer * work->rows_per_layer;
		const uint32_t slice = (uint32_t)(row_in_layer / work->row_count);
		const uint32_t row_in_slice = (uint32_t)(row_in_layer - (uint64_t)slice * work->row_count);
		const int32_t z = command->dst_z0 + (int32_t)slice;
		const int32_t y = command->dst_y0 + (int32_t)row_in_slice;
		const float source_z = command->src_z0 + (float)z * command->step_z;
		const float source_y = command->src_y0 + (float)y * command->step_y;

		const uint8_t* src_layer = work->src + (size_t)((uint64_t)layer * command->src_layer_pitch);
		uint8_t* dst_layer = work->dst + (size_t)((uint64_t)layer * command->dst_layer_pitch);
		uint8_t* dst_slice = dst_layer + (size_t)((uint64_t)(uint32_t)z * command->dst_slice_pitch);
		const uint64_t row_offset =
		    (uint64_t)(uint32_t)y * command->dst_row_pitch + (uint64_t)(uint32_t)command->dst_x0 * work->dst_info->texel_size;

		BlitRow(dst_slice + (size_t)row_offset, src_layer, command, work->src_info, work->dst_info, source_y, source_z);
	}
}

PhiStatus BlitImage(const PhiCmdBlitImage* command)
{
	if(command->src_memory == 0 || command->dst_memory == 0)
	{
		LogError("Invalid blit image memory handle");
		return PHI_STATUS_INVALID_HANDLE;
	}

	const Memory* src_memory = (const Memory*)(uintptr_t)command->src_memory;
	Memory* dst_memory = (Memory*)(uintptr_t)command->dst_memory;
	FormatInfo src_info;
	FormatInfo dst_info;

	if(!PhiGetBlitFormatInfo((PhiFormat)command->src_format, &src_info) ||
	   !PhiGetBlitFormatInfo((PhiFormat)command->dst_format, &dst_info))
	{
		LogErrorFmt("Unsupported blit image formats: src=%u dst=%u", command->src_format, command->dst_format);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	const int integer_path = src_info.is_integer && dst_info.is_integer;
	if((integer_path && (!src_info.can_read_int || !dst_info.can_write_int)) ||
	   (!integer_path && (!src_info.can_read_float || !dst_info.can_write_float)))
	{
		LogErrorFmt("Unsupported blit image format direction: src=%u dst=%u", command->src_format, command->dst_format);
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	PhiStatus status = ValidateCommand(command, src_memory, dst_memory, &src_info, &dst_info);
	if(status != PHI_STATUS_OK)
		return status;

	const uint8_t* src = (const uint8_t*)src_memory->ptr + (size_t)command->src_offset;
	uint8_t* dst = (uint8_t*)dst_memory->ptr + (size_t)command->dst_offset;
	const uint32_t row_count = (uint32_t)(command->dst_y1 - command->dst_y0);
	const uint32_t slice_count = (uint32_t)(command->dst_z1 - command->dst_z0);
	const uint32_t width = (uint32_t)(command->dst_x1 - command->dst_x0);
	uint64_t rows_per_layer;
	uint64_t total_rows;
	uint64_t total_pixels;

	if(__builtin_mul_overflow((uint64_t)row_count, slice_count, &rows_per_layer) ||
	   __builtin_mul_overflow(rows_per_layer, command->layer_count, &total_rows) ||
	   __builtin_mul_overflow(total_rows, width, &total_pixels))
	{
		LogError("Blit image work size overflow");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	const BlitWork work = {
		.command = command,
		.src_info = &src_info,
		.dst_info = &dst_info,
		.src = src,
		.dst = dst,
		.row_count = row_count,
		.rows_per_layer = rows_per_layer,
	};

	uint64_t row_bytes;
	if(__builtin_mul_overflow((uint64_t)width, dst_info.texel_size, &row_bytes))
	{
		LogError("Blit image row size overflow");
		return PHI_STATUS_INVALID_ARGUMENT;
	}

	uint64_t grain_rows = row_bytes < BLIT_TASK_TARGET_BYTES ? BLIT_TASK_TARGET_BYTES / row_bytes : 1;
	if(grain_rows > BLIT_MAX_GRAIN_ROWS)
		grain_rows = BLIT_MAX_GRAIN_ROWS;

	if(src_memory != dst_memory && total_pixels >= BLIT_PARALLEL_MIN_PIXELS && WorkerPoolGetWorkerCount() != 0)
		WorkerPoolParallelFor(total_rows, grain_rows, BlitRows, (void*)&work);
	else
		BlitRows((void*)&work, 0, total_rows);

	return PHI_STATUS_OK;
}
