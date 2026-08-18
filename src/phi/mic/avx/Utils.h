#ifndef APE_PHI_AVX_UTILS_H
#define APE_PHI_AVX_UTILS_H

#include <immintrin.h>
#include <stdint.h>

#include <avx/Intrinsic.h>

#define PHI_CACHE_LINE_SIZE 64

static inline __m512i Load512Unaligned(const uint8_t* src)
{
	__m512i value = _mm512_setzero_epi32();
	value = _mm512_loadunpacklo_epi32(value, (const void*)src);
	value = _mm512_loadunpackhi_epi32(value, (const void*)(src + PHI_CACHE_LINE_SIZE));
	return value;
}

#endif
