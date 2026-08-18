#ifndef APE_PHI_AVX_INTRINSIC_H
#define APE_PHI_AVX_INTRINSIC_H

#include <immintrin.h>
#include <stdint.h>

static inline __attribute__((always_inline)) __m512i _mm512_set1_epi32_knc(uint32_t value)
{
	__m512i result;
	__asm__("vpbroadcastd %1, %0" : "=x"(result) : "m"(value));
	return result;
}

#endif
