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
