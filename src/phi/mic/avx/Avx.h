#ifndef APE_PHI_AVX_H
#define APE_PHI_AVX_H

#include <stddef.h>
#include <stdint.h>

void AvxCopy(uint8_t* dst, const uint8_t* src, size_t size);

void AvxFill64(void* dst, uint32_t value);
void AvxFill256(void* dst, uint32_t value);

#endif
