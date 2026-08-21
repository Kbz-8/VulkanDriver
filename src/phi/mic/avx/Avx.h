#ifndef APE_PHI_AVX_H
#define APE_PHI_AVX_H

#include <stddef.h>
#include <stdint.h>

void AvxCopy(uint8_t* dst, const uint8_t* src, size_t size);

void AvxBlitNearestUnorm8x4(uint8_t* dst,
                            const uint8_t* src_row,
                            const uint32_t* source_indices,
                            uint32_t src_format,
                            uint32_t dst_format);
void AvxBlitLinearUnorm8x4(uint8_t* dst,
                           const uint8_t* src_row_0,
                           const uint8_t* src_row_1,
                           const uint32_t* source_x0,
                           const uint32_t* source_x1,
                           const uint32_t* weights_x,
                           uint32_t weight_y,
                           uint32_t src_format,
                           uint32_t dst_format);

void AvxFill64(void* dst, uint32_t value);
void AvxFill256(void* dst, uint32_t value);

#endif
