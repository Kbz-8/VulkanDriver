#include <immintrin.h>
#include <stdint.h>

#include <avx/Intrinsic.h>

// Dst must be 64-byte aligned
void AvxFill256(void* dst, uint32_t value)
{
	__m512i v = _mm512_set1_epi32_knc((int)value);

	uint8_t* d = (uint8_t*)dst;

	_mm512_store_epi32((void*)(d + 0), v);
	_mm512_store_epi32((void*)(d + 64), v);
	_mm512_store_epi32((void*)(d + 128), v);
	_mm512_store_epi32((void*)(d + 192), v);
}

// Dst must be 64-byte aligned
void AvxFill64(void* dst, uint32_t value)
{
	__m512i v = _mm512_set1_epi32_knc((int)value);

	_mm512_store_epi32(dst, v);
}
