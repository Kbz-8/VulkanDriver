#include <immintrin.h>
#include <stdint.h>

// Dst must be 64-byte aligned
void PhiFill256KNC(void* dst, uint32_t value)
{
	__m512i v = _mm512_set1_epi32((int)value);

	uint8_t* d = (uint8_t*)dst;

	_mm512_store_epi32((void*)(d + 0), v);
	_mm512_store_epi32((void*)(d + 64), v);
	_mm512_store_epi32((void*)(d + 128), v);
	_mm512_store_epi32((void*)(d + 192), v);
}

// Dst must be 64-byte aligned
void PhiFill64KNC(void* dst, uint32_t value)
{
	__m512i v = _mm512_set1_epi32((int)value);

	_mm512_store_epi32(dst, v);
}
