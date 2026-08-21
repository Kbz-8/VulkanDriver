#ifndef APE_PHI_AVX_INTRINSIC_H
#define APE_PHI_AVX_INTRINSIC_H

#include <immintrin.h>
#include <stdint.h>

inline __attribute__((always_inline, __artificial__)) __m512i _mm512_set1_epi32_knc(uint32_t value)
{
	__m512i result;
	__asm__ volatile("vpbroadcastd %1, %0" : "=x"(result) : "m"(value));
	return result;
}

inline __attribute__((always_inline, __artificial__)) __m512i _mm512_i32gather_epi32_knc(__m512i indices, const uint32_t* base)
{
	__m512i result = _mm512_setzero_epi32();
	uint32_t pending = UINT16_MAX;

	do
	{
		__asm__ volatile("kmov %1, %%k1\n\t"
		                 "vpgatherdd (%2,%3,4), %0%{%%k1%}\n\t"
		                 "kmov %%k1, %1"
		                 : "+v"(result), "+r"(pending)
		                 : "r"(base), "v"(indices)
		                 : "k1", "cc", "memory");
	} while(pending != 0);

	return result;
}

inline __m512i __attribute__((always_inline, __artificial__)) _mm512_loadunpacklo_epi32(__m512i src, const void* ptr)
{
	__asm__ volatile("vloadunpackld (%1), %0" : "+v"(src) : "r"(ptr) : "memory");
	return src;
}

inline __m512i __attribute__((always_inline, __artificial__)) _mm512_loadunpackhi_epi32(__m512i src, const void* ptr)
{
	__asm__ volatile("vloadunpackhd (%1), %0" : "+v"(src) : "r"(ptr) : "memory");
	return src;
}

#endif
