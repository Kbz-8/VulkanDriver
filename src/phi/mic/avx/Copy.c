#include <immintrin.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define PHI_CACHE_LINE_SIZE 64

static inline __m512i Load512KNC(const uint8_t* src)
{
	return _mm512_load_epi32((const void*)src);
}

void AvxCopy(uint8_t* dst, const uint8_t* src, size_t size)
{
	if(size == 0)
		return;

	// Generic fallback if not 4-byte aligned
	if((((uintptr_t)dst | (uintptr_t)src | size) & 3) != 0)
	{
		memcpy(dst, src, size);
		return;
	}

	// Align the destination to 64 bytes.
	size_t prefix = (-(uintptr_t)dst) & (PHI_CACHE_LINE_SIZE - 1);

	if(prefix > size)
		prefix = size;

	if(prefix != 0)
	{
		memcpy(dst, src, prefix);

		dst += prefix;
		src += prefix;
		size -= prefix;
	}

	if(((uintptr_t)src & (PHI_CACHE_LINE_SIZE - 1)) == 0)
	{
		// Unroll four cache lines at a time
		while(size >= 256)
		{
			const __m512i v0 = _mm512_load_epi32((const void*)(src + 0));
			const __m512i v1 = _mm512_load_epi32((const void*)(src + 64));
			const __m512i v2 = _mm512_load_epi32((const void*)(src + 128));
			const __m512i v3 = _mm512_load_epi32((const void*)(src + 192));

			_mm512_store_epi32((void*)(dst + 0), v0);
			_mm512_store_epi32((void*)(dst + 64), v1);
			_mm512_store_epi32((void*)(dst + 128), v2);
			_mm512_store_epi32((void*)(dst + 192), v3);

			src += 256;
			dst += 256;
			size -= 256;
		}

		while(size >= 64)
		{
			const __m512i value = _mm512_load_epi32((const void*)src);

			_mm512_store_epi32((void*)dst, value);

			src += 64;
			dst += 64;
			size -= 64;
		}
	}
	else
	{
		// Source is only 4-byte aligned.
		// KNC's loadunpack pair implements the conceptual unaligned 64-byte load.
		while(size >= 256)
		{
			const __m512i v0 = Load512KNC(src + 0);
			const __m512i v1 = Load512KNC(src + 64);
			const __m512i v2 = Load512KNC(src + 128);
			const __m512i v3 = Load512KNC(src + 192);

			_mm512_store_epi32((void*)(dst + 0), v0);
			_mm512_store_epi32((void*)(dst + 64), v1);
			_mm512_store_epi32((void*)(dst + 128), v2);
			_mm512_store_epi32((void*)(dst + 192), v3);

			src += 256;
			dst += 256;
			size -= 256;
		}

		while(size >= 64)
		{
			const __m512i value = Load512KNC(src);

			_mm512_store_epi32((void*)dst, value);

			src += 64;
			dst += 64;
			size -= 64;
		}
	}

	// At most 63 bytes remain
	if(size != 0)
		memcpy(dst, src, size);
}
