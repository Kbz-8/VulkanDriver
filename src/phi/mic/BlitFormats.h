#ifndef APE_PHI_BLIT_FORMATS_H
#define APE_PHI_BLIT_FORMATS_H

#include <Protocol.h>
#include <stdint.h>

typedef struct PhiBlitFormatInfo
{
	uint32_t texel_size;
	uint8_t is_integer;
	uint8_t is_signed;
	uint8_t is_float;
	uint8_t is_srgb;
	uint8_t is_unsigned;
	uint8_t can_read_float;
	uint8_t can_write_float;
	uint8_t can_read_int;
	uint8_t can_write_int;
	uint8_t vector_unorm8x4;
} PhiBlitFormatInfo;

typedef struct PhiBlitFloat4
{
	float values[4];
} PhiBlitFloat4;

typedef struct PhiBlitInt4
{
	uint32_t values[4];
} PhiBlitInt4;

int PhiGetBlitFormatInfo(PhiFormat format, PhiBlitFormatInfo* info);
PhiBlitFloat4 PhiReadBlitFloat4(const uint8_t* map, PhiFormat format);
void PhiWriteBlitFloat4(PhiBlitFloat4 color, uint8_t* map, PhiFormat format);
PhiBlitInt4 PhiReadBlitInt4(const uint8_t* map, PhiFormat format);
void PhiWriteBlitInt4(PhiBlitInt4 color, uint8_t* map, PhiFormat format);
PhiBlitFloat4 PhiConvertBlitFloat4(PhiBlitFloat4 color,
                                   PhiFormat src_format,
                                   PhiFormat dst_format,
                                   int allow_srgb_conversion,
                                   int apply_srgb_conversion);

#endif
