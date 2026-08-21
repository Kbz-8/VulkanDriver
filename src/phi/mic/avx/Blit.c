#include <immintrin.h>
#include <stdint.h>

#include <Protocol.h>
#include <avx/Intrinsic.h>

#define BLIT_WEIGHT_SCALE 1024u
#define BLIT_WEIGHT_SHIFT 20u
#define BLIT_WEIGHT_ROUND (1u << (BLIT_WEIGHT_SHIFT - 1))

static inline int IsBgra(uint32_t format)
{
	return format == PHI_FORMAT_B8G8R8A8_UNORM;
}

static inline __m512i SwapRedBlue(__m512i packed)
{
	const __m512i keep_mask = _mm512_set1_epi32_knc(0xff00ff00u);
	const __m512i red_mask = _mm512_set1_epi32_knc(0x000000ffu);
	const __m512i blue_mask = _mm512_set1_epi32_knc(0x00ff0000u);
	const __m512i keep = _mm512_and_epi32(packed, keep_mask);
	const __m512i red = _mm512_slli_epi32(_mm512_and_epi32(packed, red_mask), 16);
	const __m512i blue = _mm512_srli_epi32(_mm512_and_epi32(packed, blue_mask), 16);
	return _mm512_or_epi32(keep, _mm512_or_epi32(red, blue));
}

static inline __m512i ToCanonicalRgba(__m512i packed, uint32_t format)
{
	return IsBgra(format) ? SwapRedBlue(packed) : packed;
}

static inline __m512i FromCanonicalRgba(__m512i packed, uint32_t format)
{
	return IsBgra(format) ? SwapRedBlue(packed) : packed;
}

static inline __m512i GatherCanonical(const uint8_t* source_row, __m512i indices, uint32_t format)
{
	const __m512i packed = _mm512_i32gather_epi32_knc(indices, (const uint32_t*)source_row);
	return ToCanonicalRgba(packed, format);
}

#define EXTRACT_CHANNEL(packed, shift) _mm512_and_epi32(_mm512_srli_epi32((packed), (shift)), _mm512_set1_epi32_knc(0xffu))

static inline __m512i LerpHorizontal(__m512i a, __m512i b, __m512i weight)
{
	const __m512i scale = _mm512_set1_epi32_knc(BLIT_WEIGHT_SCALE);
	const __m512i inverse_weight = _mm512_sub_epi32(scale, weight);
	return _mm512_add_epi32(_mm512_mullo_epi32(a, inverse_weight), _mm512_mullo_epi32(b, weight));
}

static inline __m512i LerpVertical(__m512i a, __m512i b, __m512i weight)
{
	const __m512i scale = _mm512_set1_epi32_knc(BLIT_WEIGHT_SCALE);
	const __m512i round = _mm512_set1_epi32_knc(BLIT_WEIGHT_ROUND);
	const __m512i inverse_weight = _mm512_sub_epi32(scale, weight);
	const __m512i sum = _mm512_add_epi32(_mm512_mullo_epi32(a, inverse_weight), _mm512_mullo_epi32(b, weight));
	return _mm512_srli_epi32(_mm512_add_epi32(sum, round), BLIT_WEIGHT_SHIFT);
}

static inline __m512i InterpolateChannel(__m512i color_0_0,
                                         __m512i color_0_1,
                                         __m512i color_1_0,
                                         __m512i color_1_1,
                                         __m512i weight_x,
                                         __m512i weight_y)
{
	const __m512i row_0 = LerpHorizontal(color_0_0, color_0_1, weight_x);
	const __m512i row_1 = LerpHorizontal(color_1_0, color_1_1, weight_x);
	return LerpVertical(row_0, row_1, weight_y);
}

static inline __m512i PackChannels(__m512i red, __m512i green, __m512i blue, __m512i alpha)
{
	green = _mm512_slli_epi32(green, 8);
	blue = _mm512_slli_epi32(blue, 16);
	alpha = _mm512_slli_epi32(alpha, 24);
	return _mm512_or_epi32(_mm512_or_epi32(red, green), _mm512_or_epi32(blue, alpha));
}

void AvxBlitNearestUnorm8x4(uint8_t* dst,
                            const uint8_t* src_row,
                            const uint32_t* source_indices,
                            uint32_t src_format,
                            uint32_t dst_format)
{
	const __m512i indices = _mm512_load_epi32(source_indices);
	__m512i packed = GatherCanonical(src_row, indices, src_format);
	packed = FromCanonicalRgba(packed, dst_format);
	_mm512_store_epi32(dst, packed);
}

void AvxBlitLinearUnorm8x4(uint8_t* dst,
                           const uint8_t* src_row_0,
                           const uint8_t* src_row_1,
                           const uint32_t* source_x0,
                           const uint32_t* source_x1,
                           const uint32_t* weights_x,
                           uint32_t weight_y,
                           uint32_t src_format,
                           uint32_t dst_format)
{
	const __m512i x0 = _mm512_load_epi32(source_x0);
	const __m512i x1 = _mm512_load_epi32(source_x1);
	const __m512i weight_x = _mm512_load_epi32(weights_x);
	const __m512i vector_weight_y = _mm512_set1_epi32_knc(weight_y);
	const __m512i color_0_0 = GatherCanonical(src_row_0, x0, src_format);
	const __m512i color_0_1 = GatherCanonical(src_row_0, x1, src_format);
	const __m512i color_1_0 = GatherCanonical(src_row_1, x0, src_format);
	const __m512i color_1_1 = GatherCanonical(src_row_1, x1, src_format);

	__m512i packed = PackChannels(InterpolateChannel(EXTRACT_CHANNEL(color_0_0, 0),
	                                                 EXTRACT_CHANNEL(color_0_1, 0),
	                                                 EXTRACT_CHANNEL(color_1_0, 0),
	                                                 EXTRACT_CHANNEL(color_1_1, 0),
	                                                 weight_x,
	                                                 vector_weight_y),
	                              InterpolateChannel(EXTRACT_CHANNEL(color_0_0, 8),
	                                                 EXTRACT_CHANNEL(color_0_1, 8),
	                                                 EXTRACT_CHANNEL(color_1_0, 8),
	                                                 EXTRACT_CHANNEL(color_1_1, 8),
	                                                 weight_x,
	                                                 vector_weight_y),
	                              InterpolateChannel(EXTRACT_CHANNEL(color_0_0, 16),
	                                                 EXTRACT_CHANNEL(color_0_1, 16),
	                                                 EXTRACT_CHANNEL(color_1_0, 16),
	                                                 EXTRACT_CHANNEL(color_1_1, 16),
	                                                 weight_x,
	                                                 vector_weight_y),
	                              InterpolateChannel(EXTRACT_CHANNEL(color_0_0, 24),
	                                                 EXTRACT_CHANNEL(color_0_1, 24),
	                                                 EXTRACT_CHANNEL(color_1_0, 24),
	                                                 EXTRACT_CHANNEL(color_1_1, 24),
	                                                 weight_x,
	                                                 vector_weight_y));
	packed = FromCanonicalRgba(packed, dst_format);
	_mm512_store_epi32(dst, packed);
}
