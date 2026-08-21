#include <BlitFormats.h>

#include <math.h>
#include <stddef.h>
#include <string.h>

static uint16_t LoadU16(const uint8_t* map)
{
	uint16_t value;
	memcpy(&value, map, sizeof(value));
	return value;
}

static uint32_t LoadU32(const uint8_t* map)
{
	uint32_t value;
	memcpy(&value, map, sizeof(value));
	return value;
}

static float LoadF32(const uint8_t* map)
{
	float value;
	memcpy(&value, map, sizeof(value));
	return value;
}

static void StoreU16(uint8_t* map, uint16_t value)
{
	memcpy(map, &value, sizeof(value));
}

static void StoreU32(uint8_t* map, uint32_t value)
{
	memcpy(map, &value, sizeof(value));
}

static void StoreF32(uint8_t* map, float value)
{
	memcpy(map, &value, sizeof(value));
}

static uint32_t FloatBits(float value)
{
	uint32_t bits;
	memcpy(&bits, &value, sizeof(bits));
	return bits;
}

static float BitsFloat(uint32_t bits)
{
	float value;
	memcpy(&value, &bits, sizeof(value));
	return value;
}

static float HalfToFloat(uint16_t half)
{
	uint32_t sign = ((uint32_t)half & 0x8000u) << 16;
	uint32_t exponent = ((uint32_t)half >> 10) & 0x1fu;
	uint32_t mantissa = (uint32_t)half & 0x3ffu;
	uint32_t bits;

	if(exponent == 0u)
	{
		if(mantissa == 0u)
			bits = sign;
		else
		{
			int shift = 0;
			while((mantissa & 0x400u) == 0u)
			{
				mantissa <<= 1;
				++shift;
			}
			mantissa &= 0x3ffu;
			bits = sign | ((uint32_t)(113 - shift) << 23) | (mantissa << 13);
		}
	}
	else if(exponent == 31u)
		bits = sign | 0x7f800000u | (mantissa << 13);
	else
		bits = sign | ((exponent + 112u) << 23) | (mantissa << 13);

	return BitsFloat(bits);
}

static uint16_t FloatToHalf(float value)
{
	uint32_t bits = FloatBits(value);
	uint32_t sign = (bits >> 16) & 0x8000u;
	uint32_t exponent = (bits >> 23) & 0xffu;
	uint32_t mantissa = bits & 0x7fffffu;
	int half_exponent;

	if(exponent == 255u)
	{
		if(mantissa == 0u)
			return (uint16_t)(sign | 0x7c00u);
		mantissa >>= 13;
		return (uint16_t)(sign | 0x7c00u | mantissa | (mantissa == 0u));
	}

	half_exponent = (int)exponent - 127 + 15;
	if(half_exponent >= 31)
		return (uint16_t)(sign | 0x7c00u);
	if(half_exponent <= 0)
	{
		uint32_t rounded;
		uint32_t shift;
		uint32_t remainder;
		uint32_t halfway;
		if(half_exponent < -10)
			return (uint16_t)sign;
		mantissa |= 0x800000u;
		shift = (uint32_t)(14 - half_exponent);
		rounded = mantissa >> shift;
		remainder = mantissa & ((1u << shift) - 1u);
		halfway = 1u << (shift - 1u);
		if(remainder > halfway || (remainder == halfway && (rounded & 1u) != 0u))
			++rounded;
		return (uint16_t)(sign | rounded);
	}
	else
	{
		uint32_t rounded = mantissa >> 13;
		uint32_t remainder = mantissa & 0x1fffu;
		if(remainder > 0x1000u || (remainder == 0x1000u && (rounded & 1u) != 0u))
		{
			++rounded;
			if(rounded == 0x400u)
			{
				rounded = 0u;
				++half_exponent;
				if(half_exponent >= 31)
					return (uint16_t)(sign | 0x7c00u);
			}
		}
		return (uint16_t)(sign | ((uint32_t)half_exponent << 10) | rounded);
	}
}

static int32_t SignedBits(uint32_t value, unsigned bits)
{
	uint32_t sign = 1u << (bits - 1u);
	return (int32_t)((value ^ sign) - sign);
}

static float NormalizedI8(uint8_t value)
{
	int32_t signed_value = (int32_t)(int8_t)value;
	float result = (float)signed_value / 127.0f;
	return result < -1.0f ? -1.0f : result;
}

static float NormalizedI16(uint16_t value)
{
	int32_t signed_value = (int32_t)(int16_t)value;
	float result = (float)signed_value / 32767.0f;
	return result < -1.0f ? -1.0f : result;
}

static float NormalizedSignedBits(uint32_t value, unsigned bits)
{
	float result = (float)SignedBits(value, bits) / (float)((1u << (bits - 1u)) - 1u);
	return result < -1.0f ? -1.0f : result;
}

static uint32_t SignExtend8(uint8_t value)
{
	return (uint32_t)(int32_t)(int8_t)value;
}

static uint32_t SignExtend16(uint16_t value)
{
	return (uint32_t)(int32_t)(int16_t)value;
}

static float Clamp(float value, float low, float high)
{
	if(value < low)
		return low;
	if(value > high)
		return high;
	return value;
}

static uint32_t RoundUnsigned(float value)
{
	return (uint32_t)roundf(value);
}

static int32_t RoundSigned(float value)
{
	return (int32_t)roundf(value);
}

static float DecodeUFloat(uint32_t value, unsigned mantissa_bits)
{
	uint32_t mantissa_mask = (1u << mantissa_bits) - 1u;
	uint32_t mantissa = value & mantissa_mask;
	uint32_t exponent = (value >> mantissa_bits) & 0x1fu;

	if(exponent == 0u)
		return mantissa == 0u ? 0.0f : ldexpf((float)mantissa / (float)(1u << mantissa_bits), -14);
	if(exponent == 31u)
		return mantissa == 0u ? INFINITY : NAN;
	return ldexpf(1.0f + (float)mantissa / (float)(1u << mantissa_bits), (int)exponent - 15);
}

static uint32_t EncodeUFloat(float value, unsigned mantissa_bits)
{
	const uint32_t max_exponent = 31u;
	int exponent;
	int adjusted_exponent;
	float normalized;
	uint32_t mantissa;
	uint32_t exp_bits;

	if(isnan(value))
		return (max_exponent << mantissa_bits) | 1u;
	if(isinf(value))
		return max_exponent << mantissa_bits;
	if(value <= 0.0f)
		return 0u;

	normalized = frexpf(value, &exponent);
	adjusted_exponent = exponent - 1 + 15;
	if(adjusted_exponent >= 31)
		return max_exponent << mantissa_bits;
	if(adjusted_exponent <= 0)
		return RoundUnsigned(value * (float)(1u << (mantissa_bits + 14u)));

	mantissa = RoundUnsigned((normalized * 2.0f - 1.0f) * (float)(1u << mantissa_bits));
	exp_bits = (uint32_t)adjusted_exponent;
	if(mantissa == (1u << mantissa_bits))
	{
		mantissa = 0u;
		++exp_bits;
		if(exp_bits >= max_exponent)
			return max_exponent << mantissa_bits;
	}
	return (exp_bits << mantissa_bits) | mantissa;
}

static float ClampE5Component(float value)
{
	const float max_value = 65408.0f;
	if(isnan(value) || value <= 0.0f)
		return 0.0f;
	if(isinf(value) || value >= max_value)
		return max_value;
	return value;
}

static uint32_t EncodeE5B9G9R9(PhiBlitFloat4 color)
{
	float r = ClampE5Component(color.values[0]);
	float g = ClampE5Component(color.values[1]);
	float b = ClampE5Component(color.values[2]);
	float maximum = fmaxf(r, fmaxf(g, b));
	float scale;
	int exponent_part;
	int exponent_i;
	uint32_t exponent;
	uint32_t rounded_max;
	uint32_t rm;
	uint32_t gm;
	uint32_t bm;

	if(maximum == 0.0f)
		return 0u;
	(void)frexpf(maximum, &exponent_part);
	exponent_i = exponent_part + 15;
	if(exponent_i < 0)
		exponent_i = 0;
	if(exponent_i > 31)
		exponent_i = 31;
	exponent = (uint32_t)exponent_i;
	scale = ldexpf(1.0f, exponent_i - 24);
	rounded_max = RoundUnsigned(maximum / scale);
	if(rounded_max > 0x1ffu && exponent < 31u)
	{
		++exponent;
		scale *= 2.0f;
	}
	rm = RoundUnsigned(r / scale);
	gm = RoundUnsigned(g / scale);
	bm = RoundUnsigned(b / scale);
	if(rm > 0x1ffu)
		rm = 0x1ffu;
	if(gm > 0x1ffu)
		gm = 0x1ffu;
	if(bm > 0x1ffu)
		bm = 0x1ffu;
	return rm | (gm << 9) | (bm << 18) | (exponent << 27);
}

static int CanReadFloat(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_USCALED:
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SRGB:
		case PHI_FORMAT_R8_SSCALED:
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8_SNORM:
		case PHI_FORMAT_R16_USCALED:
		case PHI_FORMAT_R16_SSCALED:
		case PHI_FORMAT_R16_SNORM:
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_D16_UNORM:
		case PHI_FORMAT_X8_D24_UNORM_PACK32:
		case PHI_FORMAT_D24_UNORM_S8_UINT:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_SRGB:
		case PHI_FORMAT_R8G8B8A8_UNORM:
		case PHI_FORMAT_R8G8_USCALED:
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SRGB:
		case PHI_FORMAT_R8G8_SSCALED:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8_SNORM:
		case PHI_FORMAT_R8G8B8_UNORM:
		case PHI_FORMAT_B8G8R8_UNORM:
		case PHI_FORMAT_R8G8B8A8_USCALED:
		case PHI_FORMAT_R8G8B8A8_SSCALED:
		case PHI_FORMAT_R8G8B8A8_SNORM:
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16_SFLOAT:
		case PHI_FORMAT_R16G16_USCALED:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R16G16_SSCALED:
		case PHI_FORMAT_R16G16_SNORM:
		case PHI_FORMAT_R16G16_UNORM:
		case PHI_FORMAT_R16G16_SFLOAT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_D32_SFLOAT:
		case PHI_FORMAT_R32G32_SFLOAT:
		case PHI_FORMAT_R32G32B32_SFLOAT:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_UNORM:
		case PHI_FORMAT_R16G16B16A16_USCALED:
		case PHI_FORMAT_R16G16B16A16_SSCALED:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SNORM:
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_S8_UINT:
		case PHI_FORMAT_B8G8R8A8_SRGB:
		case PHI_FORMAT_B8G8R8A8_UNORM:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
		case PHI_FORMAT_A8B8G8R8_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_USCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_SNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_USCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SNORM_PACK32:
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
			return 1;
		default:
			return 0;
	}
}

static int CanWriteFloat(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SRGB:
		case PHI_FORMAT_S8_UINT:
		case PHI_FORMAT_R8_SNORM:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16_SNORM:
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_D16_UNORM:
		case PHI_FORMAT_R16_SFLOAT:
		case PHI_FORMAT_X8_D24_UNORM_PACK32:
		case PHI_FORMAT_D24_UNORM_S8_UINT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_D32_SFLOAT:
		case PHI_FORMAT_R8G8_SNORM:
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SRGB:
		case PHI_FORMAT_R8G8B8_UNORM:
		case PHI_FORMAT_B8G8R8_UNORM:
		case PHI_FORMAT_R16G16_SNORM:
		case PHI_FORMAT_R16G16_UNORM:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R16G16_SFLOAT:
		case PHI_FORMAT_R32G32_SFLOAT:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_UNORM:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SNORM:
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
		case PHI_FORMAT_B8G8R8A8_SRGB:
		case PHI_FORMAT_B8G8R8A8_UNORM:
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
		case PHI_FORMAT_R8G8B8A8_UNORM:
		case PHI_FORMAT_R8G8B8A8_SRGB:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_USCALED:
		case PHI_FORMAT_R8G8B8A8_SNORM:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
			return 1;
		default:
			return 0;
	}
}

static int CanReadInt(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_S8_UINT:
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_UINT:
		case PHI_FORMAT_R32G32B32_SINT:
		case PHI_FORMAT_R32G32B32_UINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_SINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_SINT_PACK32:
			return 1;
		default:
			return 0;
	}
}

static int CanWriteInt(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_S8_UINT:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_UINT:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_USCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
			return 1;
		default:
			return 0;
	}
}

static int IsInteger(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_SINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_SINT_PACK32:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32G32_UINT:
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32B32_UINT:
		case PHI_FORMAT_R32G32B32_SINT:
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_S8_UINT:
			return 1;
		default:
			return 0;
	}
}

static int IsSigned(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R8_SNORM:
		case PHI_FORMAT_R8_SSCALED:
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8G8_SNORM:
		case PHI_FORMAT_R8G8_SSCALED:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8B8A8_SNORM:
		case PHI_FORMAT_R8G8B8A8_SSCALED:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SSCALED_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_SNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_SNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_SINT_PACK32:
		case PHI_FORMAT_R16_SNORM:
		case PHI_FORMAT_R16_SSCALED:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_SFLOAT:
		case PHI_FORMAT_R16G16_SNORM:
		case PHI_FORMAT_R16G16_SSCALED:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_SFLOAT:
		case PHI_FORMAT_R16G16B16A16_SNORM:
		case PHI_FORMAT_R16G16B16A16_SSCALED:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_SFLOAT:
		case PHI_FORMAT_R32G32B32_SINT:
		case PHI_FORMAT_R32G32B32_SFLOAT:
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
		case PHI_FORMAT_D32_SFLOAT:
			return 1;
		default:
			return 0;
	}
}

static int IsFloat(PhiFormat format)
{
	switch((int)format)
	{
		case PHI_FORMAT_R16_SFLOAT:
		case PHI_FORMAT_R16G16_SFLOAT:
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_R32G32_SFLOAT:
		case PHI_FORMAT_R32G32B32_SFLOAT:
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
		case PHI_FORMAT_D32_SFLOAT:
			return 1;
		default:
			return 0;
	}
}

static int IsSrgb(PhiFormat format)
{
	return format == PHI_FORMAT_R8_SRGB || format == PHI_FORMAT_R8G8_SRGB || format == PHI_FORMAT_R8G8B8A8_SRGB ||
	       format == PHI_FORMAT_B8G8R8A8_SRGB || format == PHI_FORMAT_A8B8G8R8_SRGB_PACK32;
}

static int IsUnsignedComponent(PhiFormat format, unsigned component)
{
	if(IsFloat(format))
	{
		if(format == PHI_FORMAT_B10G11R11_UFLOAT_PACK32 || format == PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32 ||
		   format == PHI_FORMAT_D32_SFLOAT)
			return 1;
		if(format == PHI_FORMAT_R16_SFLOAT || format == PHI_FORMAT_R32_SFLOAT)
			return component >= 1u;
		if(format == PHI_FORMAT_R16G16_SFLOAT || format == PHI_FORMAT_R32G32_SFLOAT)
			return component >= 2u;
		if(format == PHI_FORMAT_R32G32B32_SFLOAT)
			return component >= 3u;
		return 0;
	}
	if(IsSigned(format))
	{
		if(format == PHI_FORMAT_R8_SNORM || format == PHI_FORMAT_R8_SSCALED || format == PHI_FORMAT_R8_SINT ||
		   format == PHI_FORMAT_R16_SNORM || format == PHI_FORMAT_R16_SSCALED || format == PHI_FORMAT_R16_SINT ||
		   format == PHI_FORMAT_R32_SINT)
			return component >= 1u;
		if(format == PHI_FORMAT_R8G8_SNORM || format == PHI_FORMAT_R8G8_SSCALED || format == PHI_FORMAT_R8G8_SINT ||
		   format == PHI_FORMAT_R16G16_SNORM || format == PHI_FORMAT_R16G16_SSCALED || format == PHI_FORMAT_R16G16_SINT ||
		   format == PHI_FORMAT_R32G32_SINT)
			return component >= 2u;
		if(format == PHI_FORMAT_R32G32B32_SINT)
			return component >= 3u;
		return 0;
	}
	/* Match format.isUnsignedComponent, including its R8_USCALED component-zero behavior. */
	if(format == PHI_FORMAT_R8_USCALED)
		return component >= 1u;
	return 1;
}

static float MaxElementValue(PhiFormat format)
{
	if(format == PHI_FORMAT_D16_UNORM || format == PHI_FORMAT_X8_D24_UNORM_PACK32 || format == PHI_FORMAT_D24_UNORM_S8_UINT ||
	   format == PHI_FORMAT_D32_SFLOAT)
		return 1.0f;
	if(format == PHI_FORMAT_S8_UINT)
		return 255.0f;
	if(IsSrgb(format))
		return 1.0f;
	switch((int)format)
	{
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SNORM:
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SNORM:
		case PHI_FORMAT_R8G8B8_UNORM:
		case PHI_FORMAT_B8G8R8_UNORM:
		case PHI_FORMAT_R8G8B8A8_UNORM:
		case PHI_FORMAT_R8G8B8A8_SNORM:
		case PHI_FORMAT_B8G8R8A8_UNORM:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_SNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_SNORM_PACK32:
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_R16_SNORM:
		case PHI_FORMAT_R16G16_UNORM:
		case PHI_FORMAT_R16G16_SNORM:
		case PHI_FORMAT_R16G16B16A16_UNORM:
		case PHI_FORMAT_R16G16B16A16_SNORM:
			return 1.0f;
		default:
			break;
	}
	if(IsFloat(format))
		return (format == PHI_FORMAT_R16_SFLOAT || format == PHI_FORMAT_R16G16_SFLOAT ||
		        format == PHI_FORMAT_R16G16B16A16_SFLOAT || format == PHI_FORMAT_B10G11R11_UFLOAT_PACK32 ||
		        format == PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32)
		           ? 65504.0f
		           : 3.402823466e+38f;
	if(format == PHI_FORMAT_R8_USCALED || format == PHI_FORMAT_R8_UINT || format == PHI_FORMAT_R8G8_USCALED ||
	   format == PHI_FORMAT_R8G8_UINT || format == PHI_FORMAT_R8G8B8A8_USCALED || format == PHI_FORMAT_R8G8B8A8_UINT ||
	   format == PHI_FORMAT_A8B8G8R8_USCALED_PACK32 || format == PHI_FORMAT_A8B8G8R8_UINT_PACK32)
		return 255.0f;
	if(format == PHI_FORMAT_R8_SSCALED || format == PHI_FORMAT_R8_SINT || format == PHI_FORMAT_R8G8_SSCALED ||
	   format == PHI_FORMAT_R8G8_SINT || format == PHI_FORMAT_R8G8B8A8_SSCALED || format == PHI_FORMAT_R8G8B8A8_SINT ||
	   format == PHI_FORMAT_A8B8G8R8_SSCALED_PACK32 || format == PHI_FORMAT_A8B8G8R8_SINT_PACK32)
		return 127.0f;
	if(format == PHI_FORMAT_R16_USCALED || format == PHI_FORMAT_R16_UINT || format == PHI_FORMAT_R16G16_USCALED ||
	   format == PHI_FORMAT_R16G16_UINT || format == PHI_FORMAT_R16G16B16A16_USCALED || format == PHI_FORMAT_R16G16B16A16_UINT)
		return 65535.0f;
	if(format == PHI_FORMAT_R16_SSCALED || format == PHI_FORMAT_R16_SINT || format == PHI_FORMAT_R16G16_SSCALED ||
	   format == PHI_FORMAT_R16G16_SINT || format == PHI_FORMAT_R16G16B16A16_SSCALED || format == PHI_FORMAT_R16G16B16A16_SINT)
		return 32767.0f;
	if(format == PHI_FORMAT_R32_UINT || format == PHI_FORMAT_R32G32_UINT || format == PHI_FORMAT_R32G32B32_UINT ||
	   format == PHI_FORMAT_R32G32B32A32_UINT)
		return 4294967295.0f;
	if(format == PHI_FORMAT_R32_SINT || format == PHI_FORMAT_R32G32_SINT || format == PHI_FORMAT_R32G32B32_SINT ||
	   format == PHI_FORMAT_R32G32B32A32_SINT)
		return 2147483647.0f;
	if(format == PHI_FORMAT_A2R10G10B10_USCALED_PACK32 || format == PHI_FORMAT_A2R10G10B10_UINT_PACK32 ||
	   format == PHI_FORMAT_A2B10G10R10_USCALED_PACK32 || format == PHI_FORMAT_A2B10G10R10_UINT_PACK32)
		return 1023.0f;
	if(format == PHI_FORMAT_A2R10G10B10_SSCALED_PACK32 || format == PHI_FORMAT_A2R10G10B10_SINT_PACK32 ||
	   format == PHI_FORMAT_A2B10G10R10_SSCALED_PACK32 || format == PHI_FORMAT_A2B10G10R10_SINT_PACK32)
		return 511.0f;
	return 1.0f;
}

static float MinElementValue(PhiFormat format)
{
	if(format == PHI_FORMAT_D16_UNORM || format == PHI_FORMAT_X8_D24_UNORM_PACK32 || format == PHI_FORMAT_D24_UNORM_S8_UINT ||
	   format == PHI_FORMAT_D32_SFLOAT || format == PHI_FORMAT_S8_UINT || IsSrgb(format))
		return 0.0f;
	if(IsSigned(format))
	{
		if(format == PHI_FORMAT_R8_SNORM || format == PHI_FORMAT_R8G8_SNORM || format == PHI_FORMAT_R8G8B8A8_SNORM ||
		   format == PHI_FORMAT_A8B8G8R8_SNORM_PACK32 || format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 ||
		   format == PHI_FORMAT_A2B10G10R10_SNORM_PACK32 || format == PHI_FORMAT_R16_SNORM ||
		   format == PHI_FORMAT_R16G16_SNORM || format == PHI_FORMAT_R16G16B16A16_SNORM)
			return -1.0f;
		if(IsFloat(format))
			return -MaxElementValue(format);
		if(MaxElementValue(format) == 127.0f)
			return -128.0f;
		if(MaxElementValue(format) == 32767.0f)
			return -32768.0f;
		if(MaxElementValue(format) == 511.0f)
			return -512.0f;
		return -2147483648.0f;
	}
	return 0.0f;
}

static void ScaleForFormat(PhiFormat format, float scale[4])
{
	unsigned i;
	for(i = 0; i < 4; ++i)
		scale[i] = 1.0f;
	if(format == PHI_FORMAT_R4G4B4A4_UNORM_PACK16 || format == PHI_FORMAT_B4G4R4A4_UNORM_PACK16 ||
	   format == PHI_FORMAT_A4R4G4B4_UNORM_PACK16 || format == PHI_FORMAT_A4B4G4R4_UNORM_PACK16)
		for(i = 0; i < 4; ++i)
			scale[i] = 15.0f;
	else if(format == PHI_FORMAT_R8_UNORM || format == PHI_FORMAT_R8G8_UNORM || format == PHI_FORMAT_R8G8B8_UNORM ||
	        format == PHI_FORMAT_B8G8R8_UNORM || format == PHI_FORMAT_R8G8B8A8_UNORM || format == PHI_FORMAT_B8G8R8A8_UNORM ||
	        format == PHI_FORMAT_A8B8G8R8_UNORM_PACK32 || IsSrgb(format))
		for(i = 0; i < 4; ++i)
			scale[i] = 255.0f;
	else if(format == PHI_FORMAT_R8_SNORM || format == PHI_FORMAT_R8G8_SNORM || format == PHI_FORMAT_R8G8B8A8_SNORM ||
	        format == PHI_FORMAT_A8B8G8R8_SNORM_PACK32)
		for(i = 0; i < 4; ++i)
			scale[i] = 127.0f;
	else if(format == PHI_FORMAT_R16_UNORM || format == PHI_FORMAT_R16G16_UNORM || format == PHI_FORMAT_R16G16B16A16_UNORM)
		for(i = 0; i < 4; ++i)
			scale[i] = 65535.0f;
	else if(format == PHI_FORMAT_R16_SNORM || format == PHI_FORMAT_R16G16_SNORM || format == PHI_FORMAT_R16G16B16A16_SNORM)
		for(i = 0; i < 4; ++i)
			scale[i] = 32767.0f;
	else if(format == PHI_FORMAT_R5G6B5_UNORM_PACK16 || format == PHI_FORMAT_B5G6R5_UNORM_PACK16)
	{
		scale[0] = 31.0f;
		scale[1] = 63.0f;
		scale[2] = 31.0f;
	}
	else if(format == PHI_FORMAT_R5G5B5A1_UNORM_PACK16 || format == PHI_FORMAT_B5G5R5A1_UNORM_PACK16 ||
	        format == PHI_FORMAT_A1R5G5B5_UNORM_PACK16)
	{
		scale[0] = scale[1] = scale[2] = 31.0f;
	}
	else if(format == PHI_FORMAT_A2R10G10B10_UNORM_PACK32 || format == PHI_FORMAT_A2B10G10R10_UNORM_PACK32)
	{
		scale[0] = scale[1] = scale[2] = 1023.0f;
		scale[3] = 3.0f;
	}
	else if(format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 || format == PHI_FORMAT_A2B10G10R10_SNORM_PACK32)
	{
		scale[0] = scale[1] = scale[2] = 511.0f;
	}
	else if(format == PHI_FORMAT_D16_UNORM)
	{
		scale[0] = 65535.0f;
		scale[1] = scale[2] = scale[3] = 0.0f;
	}
	else if(format == PHI_FORMAT_X8_D24_UNORM_PACK32 || format == PHI_FORMAT_D24_UNORM_S8_UINT)
	{
		scale[0] = 16777215.0f;
		scale[1] = scale[2] = scale[3] = 0.0f;
	}
}

int PhiGetBlitFormatInfo(PhiFormat format, PhiBlitFormatInfo* info)
{
	uint32_t size;
	if(info == NULL)
		return 0;
	switch((int)format)
	{
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SNORM:
		case PHI_FORMAT_R8_USCALED:
		case PHI_FORMAT_R8_SSCALED:
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8_SRGB:
		case PHI_FORMAT_S8_UINT:
			size = 1;
			break;
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_R16_SNORM:
		case PHI_FORMAT_R16_USCALED:
		case PHI_FORMAT_R16_SSCALED:
		case PHI_FORMAT_R16_UINT:
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_SFLOAT:
		case PHI_FORMAT_D16_UNORM:
			size = 2;
			break;
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SNORM:
		case PHI_FORMAT_R8G8_USCALED:
		case PHI_FORMAT_R8G8_SSCALED:
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8_SRGB:
			size = 2;
			break;
		case PHI_FORMAT_R8G8B8_UNORM:
		case PHI_FORMAT_B8G8R8_UNORM:
			size = 3;
			break;
		case PHI_FORMAT_R8G8B8A8_UNORM:
		case PHI_FORMAT_R8G8B8A8_SNORM:
		case PHI_FORMAT_R8G8B8A8_USCALED:
		case PHI_FORMAT_R8G8B8A8_SSCALED:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R8G8B8A8_SRGB:
		case PHI_FORMAT_B8G8R8A8_UNORM:
		case PHI_FORMAT_B8G8R8A8_SRGB:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
		case PHI_FORMAT_A8B8G8R8_SSCALED_PACK32:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_SNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_USCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_SINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_SNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_USCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_SINT_PACK32:
		case PHI_FORMAT_R16G16_UNORM:
		case PHI_FORMAT_R16G16_SNORM:
		case PHI_FORMAT_R16G16_USCALED:
		case PHI_FORMAT_R16G16_SSCALED:
		case PHI_FORMAT_R16G16_UINT:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_SFLOAT:
		case PHI_FORMAT_R32_UINT:
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
		case PHI_FORMAT_X8_D24_UNORM_PACK32:
		case PHI_FORMAT_D24_UNORM_S8_UINT:
		case PHI_FORMAT_D32_SFLOAT:
			size = 4;
			break;
		case PHI_FORMAT_R16G16B16A16_UNORM:
		case PHI_FORMAT_R16G16B16A16_SNORM:
		case PHI_FORMAT_R16G16B16A16_USCALED:
		case PHI_FORMAT_R16G16B16A16_SSCALED:
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
		case PHI_FORMAT_R32G32_UINT:
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_SFLOAT:
			size = 8;
			break;
		case PHI_FORMAT_R32G32B32_UINT:
		case PHI_FORMAT_R32G32B32_SINT:
		case PHI_FORMAT_R32G32B32_SFLOAT:
			size = 12;
			break;
		case PHI_FORMAT_R32G32B32A32_UINT:
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
			size = 16;
			break;
		default:
			return 0;
	}
	memset(info, 0, sizeof(*info));
	info->texel_size = size;
	info->is_integer = (uint8_t)IsInteger(format);
	info->is_signed = (uint8_t)IsSigned(format);
	info->is_float = (uint8_t)IsFloat(format);
	info->is_srgb = (uint8_t)IsSrgb(format);
	info->is_unsigned = (uint8_t)IsUnsignedComponent(format, 0u);
	info->can_read_float = (uint8_t)CanReadFloat(format);
	info->can_write_float = (uint8_t)CanWriteFloat(format);
	info->can_read_int = (uint8_t)CanReadInt(format);
	info->can_write_int = (uint8_t)CanWriteInt(format);
	info->vector_unorm8x4 = (uint8_t)(format == PHI_FORMAT_R8G8B8A8_UNORM || format == PHI_FORMAT_B8G8R8A8_UNORM ||
	                                  format == PHI_FORMAT_A8B8G8R8_UNORM_PACK32);
	return 1;
}

PhiBlitFloat4 PhiReadBlitFloat4(const uint8_t* map, PhiFormat format)
{
	PhiBlitFloat4 c = { { 0.0f, 0.0f, 0.0f, 1.0f } };
	uint32_t pack;
	uint16_t value;
	unsigned i;
	if(map == NULL || !CanReadFloat(format))
		return c;
	switch((int)format)
	{
		case PHI_FORMAT_R8_USCALED:
			c.values[0] = (float)map[0];
			break;
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SRGB:
			c.values[0] = (float)map[0] / 255.0f;
			break;
		case PHI_FORMAT_R8_SSCALED:
			c.values[0] = (float)(int8_t)map[0];
			break;
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8_SNORM:
			c.values[0] = NormalizedI8(map[0]);
			break;
		case PHI_FORMAT_R16_USCALED:
			c.values[0] = (float)LoadU16(map);
			break;
		case PHI_FORMAT_R16_SSCALED:
			c.values[0] = (float)(int16_t)LoadU16(map);
			break;
		case PHI_FORMAT_R16_SNORM:
			c.values[0] = NormalizedI16(LoadU16(map));
			break;
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_D16_UNORM:
			c.values[0] = (float)LoadU16(map) / 65535.0f;
			break;
		case PHI_FORMAT_X8_D24_UNORM_PACK32:
		case PHI_FORMAT_D24_UNORM_S8_UINT:
			c.values[0] = (float)(LoadU32(map) & 0xffffffu) / 16777215.0f;
			break;
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_SRGB:
		case PHI_FORMAT_R8G8B8A8_UNORM:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)map[i] / 255.0f;
			break;
		case PHI_FORMAT_R8G8_USCALED:
			c.values[0] = (float)map[0];
			c.values[1] = (float)map[1];
			break;
		case PHI_FORMAT_R8G8_UINT:
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SRGB:
			c.values[0] = (float)map[0] / 255.0f;
			c.values[1] = (float)map[1] / 255.0f;
			break;
		case PHI_FORMAT_R8G8_SSCALED:
			c.values[0] = (float)(int8_t)map[0];
			c.values[1] = (float)(int8_t)map[1];
			break;
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8_SNORM:
			c.values[0] = NormalizedI8(map[0]);
			c.values[1] = NormalizedI8(map[1]);
			break;
		case PHI_FORMAT_R8G8B8_UNORM:
			c.values[0] = (float)map[0] / 255.0f;
			c.values[1] = (float)map[1] / 255.0f;
			c.values[2] = (float)map[2] / 255.0f;
			break;
		case PHI_FORMAT_B8G8R8_UNORM:
			c.values[0] = (float)map[2] / 255.0f;
			c.values[1] = (float)map[1] / 255.0f;
			c.values[2] = (float)map[0] / 255.0f;
			break;
		case PHI_FORMAT_R8G8B8A8_USCALED:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)map[i];
			break;
		case PHI_FORMAT_R8G8B8A8_SSCALED:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)(int8_t)map[i];
			break;
		case PHI_FORMAT_R8G8B8A8_SNORM:
			for(i = 0; i < 4; ++i)
				c.values[i] = NormalizedI8(map[i]);
			break;
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
			value = LoadU16(map);
			if(format == PHI_FORMAT_R4G4B4A4_UNORM_PACK16)
			{
				c.values[0] = (float)((value >> 12) & 15u) / 15.0f;
				c.values[1] = (float)((value >> 8) & 15u) / 15.0f;
				c.values[2] = (float)((value >> 4) & 15u) / 15.0f;
				c.values[3] = (float)(value & 15u) / 15.0f;
			}
			else if(format == PHI_FORMAT_B4G4R4A4_UNORM_PACK16)
			{
				c.values[2] = (float)((value >> 12) & 15u) / 15.0f;
				c.values[1] = (float)((value >> 8) & 15u) / 15.0f;
				c.values[0] = (float)((value >> 4) & 15u) / 15.0f;
				c.values[3] = (float)(value & 15u) / 15.0f;
			}
			else if(format == PHI_FORMAT_A4R4G4B4_UNORM_PACK16)
			{
				c.values[3] = (float)((value >> 12) & 15u) / 15.0f;
				c.values[0] = (float)((value >> 8) & 15u) / 15.0f;
				c.values[1] = (float)((value >> 4) & 15u) / 15.0f;
				c.values[2] = (float)(value & 15u) / 15.0f;
			}
			else
			{
				c.values[3] = (float)((value >> 12) & 15u) / 15.0f;
				c.values[2] = (float)((value >> 8) & 15u) / 15.0f;
				c.values[1] = (float)((value >> 4) & 15u) / 15.0f;
				c.values[0] = (float)(value & 15u) / 15.0f;
			}
			break;
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
			c.values[0] = (float)LoadU16(map);
			break;
		case PHI_FORMAT_R16_SFLOAT:
			c.values[0] = HalfToFloat(LoadU16(map));
			break;
		case PHI_FORMAT_R16G16_USCALED:
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_UINT:
			c.values[0] = (float)LoadU16(map);
			c.values[1] = (float)LoadU16(map + 2);
			break;
		case PHI_FORMAT_R16G16_SSCALED:
			c.values[0] = (float)(int16_t)LoadU16(map);
			c.values[1] = (float)(int16_t)LoadU16(map + 2);
			break;
		case PHI_FORMAT_R16G16_SNORM:
			c.values[0] = NormalizedI16(LoadU16(map));
			c.values[1] = NormalizedI16(LoadU16(map + 2));
			break;
		case PHI_FORMAT_R16G16_UNORM:
			c.values[0] = (float)LoadU16(map) / 65535.0f;
			c.values[1] = (float)LoadU16(map + 2) / 65535.0f;
			break;
		case PHI_FORMAT_R16G16_SFLOAT:
			c.values[0] = HalfToFloat(LoadU16(map));
			c.values[1] = HalfToFloat(LoadU16(map + 2));
			break;
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
			c.values[0] = (float)LoadU32(map);
			break;
		case PHI_FORMAT_R32G32_SFLOAT:
			c.values[0] = LoadF32(map);
			c.values[1] = LoadF32(map + 4);
			break;
		case PHI_FORMAT_R32G32B32_SFLOAT:
			c.values[0] = LoadF32(map);
			c.values[1] = LoadF32(map + 4);
			c.values[2] = LoadF32(map + 8);
			break;
		case PHI_FORMAT_D32_SFLOAT:
		case PHI_FORMAT_R32_SFLOAT:
			c.values[0] = LoadF32(map);
			break;
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_UNORM:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)LoadU16(map + 2 * i) / 65535.0f;
			break;
		case PHI_FORMAT_R16G16B16A16_USCALED:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)LoadU16(map + 2 * i);
			break;
		case PHI_FORMAT_R16G16B16A16_SSCALED:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)(int16_t)LoadU16(map + 2 * i);
			break;
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SNORM:
			for(i = 0; i < 4; ++i)
				c.values[i] = NormalizedI16(LoadU16(map + 2 * i));
			break;
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
			for(i = 0; i < 4; ++i)
				c.values[i] = HalfToFloat(LoadU16(map + 2 * i));
			break;
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
			for(i = 0; i < 4; ++i)
				c.values[i] = LoadF32(map + 4 * i);
			break;
		case PHI_FORMAT_R32G32B32A32_UINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)LoadU32(map + 4 * i);
			break;
		case PHI_FORMAT_S8_UINT:
			c.values[0] = (float)map[0];
			break;
		case PHI_FORMAT_B8G8R8A8_SRGB:
		case PHI_FORMAT_B8G8R8A8_UNORM:
			c.values[0] = (float)map[2] / 255.0f;
			c.values[1] = (float)map[1] / 255.0f;
			c.values[2] = (float)map[0] / 255.0f;
			c.values[3] = (float)map[3] / 255.0f;
			break;
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)map[i] / 255.0f;
			break;
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = NormalizedI8(map[i]);
			break;
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)map[i];
			break;
		case PHI_FORMAT_A8B8G8R8_SSCALED_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = (float)(int8_t)map[i];
			break;
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
			pack = LoadU32(map);
			c.values[0] = (float)(pack & 1023u) / 1023.0f;
			c.values[1] = (float)((pack >> 10) & 1023u) / 1023.0f;
			c.values[2] = (float)((pack >> 20) & 1023u) / 1023.0f;
			c.values[3] = (float)(pack >> 30) / 3.0f;
			break;
		case PHI_FORMAT_A2B10G10R10_USCALED_PACK32:
			pack = LoadU32(map);
			c.values[0] = (float)(pack & 1023u);
			c.values[1] = (float)((pack >> 10) & 1023u);
			c.values[2] = (float)((pack >> 20) & 1023u);
			c.values[3] = (float)(pack >> 30);
			break;
		case PHI_FORMAT_A2B10G10R10_SSCALED_PACK32:
		case PHI_FORMAT_A2B10G10R10_SNORM_PACK32:
			pack = LoadU32(map);
			for(i = 0; i < 3; ++i)
				c.values[i] = format == PHI_FORMAT_A2B10G10R10_SNORM_PACK32
				                  ? NormalizedSignedBits((pack >> (10 * i)) & 1023u, 10)
				                  : (float)SignedBits((pack >> (10 * i)) & 1023u, 10);
			c.values[3] = format == PHI_FORMAT_A2B10G10R10_SNORM_PACK32 ? NormalizedSignedBits(pack >> 30, 2)
			                                                            : (float)SignedBits(pack >> 30, 2);
			break;
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
			pack = LoadU32(map);
			c.values[2] = (float)(pack & 1023u) / 1023.0f;
			c.values[1] = (float)((pack >> 10) & 1023u) / 1023.0f;
			c.values[0] = (float)((pack >> 20) & 1023u) / 1023.0f;
			c.values[3] = (float)(pack >> 30) / 3.0f;
			break;
		case PHI_FORMAT_A2R10G10B10_USCALED_PACK32:
			pack = LoadU32(map);
			c.values[2] = (float)(pack & 1023u);
			c.values[1] = (float)((pack >> 10) & 1023u);
			c.values[0] = (float)((pack >> 20) & 1023u);
			c.values[3] = (float)(pack >> 30);
			break;
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SNORM_PACK32:
			pack = LoadU32(map);
			c.values[2] = format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 ? NormalizedSignedBits(pack & 1023u, 10)
			                                                            : (float)SignedBits(pack & 1023u, 10);
			c.values[1] = format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 ? NormalizedSignedBits((pack >> 10) & 1023u, 10)
			                                                            : (float)SignedBits((pack >> 10) & 1023u, 10);
			c.values[0] = format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 ? NormalizedSignedBits((pack >> 20) & 1023u, 10)
			                                                            : (float)SignedBits((pack >> 20) & 1023u, 10);
			c.values[3] = format == PHI_FORMAT_A2R10G10B10_SNORM_PACK32 ? NormalizedSignedBits(pack >> 30, 2)
			                                                            : (float)SignedBits(pack >> 30, 2);
			break;
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
			value = LoadU16(map);
			c.values[1] = (float)((value >> 5) & 63u) / 63.0f;
			if(format == PHI_FORMAT_R5G6B5_UNORM_PACK16)
			{
				c.values[0] = (float)(value >> 11) / 31.0f;
				c.values[2] = (float)(value & 31u) / 31.0f;
			}
			else
			{
				c.values[2] = (float)(value >> 11) / 31.0f;
				c.values[0] = (float)(value & 31u) / 31.0f;
			}
			break;
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
			value = LoadU16(map);
			c.values[1] = (float)((value >> 6) & 31u) / 31.0f;
			c.values[3] = (float)(value & 1u);
			if(format == PHI_FORMAT_R5G5B5A1_UNORM_PACK16)
			{
				c.values[0] = (float)(value >> 11) / 31.0f;
				c.values[2] = (float)((value >> 1) & 31u) / 31.0f;
			}
			else
			{
				c.values[2] = (float)(value >> 11) / 31.0f;
				c.values[0] = (float)((value >> 1) & 31u) / 31.0f;
			}
			break;
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
			value = LoadU16(map);
			c.values[0] = (float)((value >> 10) & 31u) / 31.0f;
			c.values[1] = (float)((value >> 5) & 31u) / 31.0f;
			c.values[2] = (float)(value & 31u) / 31.0f;
			c.values[3] = (float)(value >> 15);
			break;
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
			pack = LoadU32(map);
			c.values[0] = DecodeUFloat(pack & 0x7ffu, 6);
			c.values[1] = DecodeUFloat((pack >> 11) & 0x7ffu, 6);
			c.values[2] = DecodeUFloat(pack >> 22, 5);
			break;
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
			pack = LoadU32(map);
			c.values[0] = (float)(pack & 0x1ffu) * ldexpf(1.0f, (int)(pack >> 27) - 24);
			c.values[1] = (float)((pack >> 9) & 0x1ffu) * ldexpf(1.0f, (int)(pack >> 27) - 24);
			c.values[2] = (float)((pack >> 18) & 0x1ffu) * ldexpf(1.0f, (int)(pack >> 27) - 24);
			break;
		default:
			break;
	}
	return c;
}

void PhiWriteBlitFloat4(PhiBlitFloat4 input, uint8_t* map, PhiFormat format)
{
	PhiBlitFloat4 c = input;
	float low;
	float high;
	uint32_t pack;
	uint32_t r, g, b, a;
	unsigned i;
	if(map == NULL || !CanWriteFloat(format))
		return;
	low = MinElementValue(format);
	high = MaxElementValue(format);
	for(i = 0; i < 4; ++i)
		c.values[i] = Clamp(c.values[i], low, high);
	switch((int)format)
	{
		case PHI_FORMAT_R8_UNORM:
		case PHI_FORMAT_R8_SRGB:
		case PHI_FORMAT_S8_UINT:
			map[0] = (uint8_t)RoundUnsigned(c.values[0] * 255.0f);
			break;
		case PHI_FORMAT_R8_SNORM:
			map[0] = (uint8_t)RoundSigned(c.values[0] * 127.0f);
			break;
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
			StoreU16(map, (uint16_t)RoundUnsigned(c.values[0]));
			break;
		case PHI_FORMAT_R16_SNORM:
			StoreU16(map, (uint16_t)RoundSigned(c.values[0] * 32767.0f));
			break;
		case PHI_FORMAT_R16_UNORM:
		case PHI_FORMAT_D16_UNORM:
			StoreU16(map, (uint16_t)RoundUnsigned(c.values[0] * 65535.0f));
			break;
		case PHI_FORMAT_X8_D24_UNORM_PACK32:
		case PHI_FORMAT_D24_UNORM_S8_UINT:
			pack = (LoadU32(map) & 0xff000000u) | RoundUnsigned(c.values[0] * 16777215.0f);
			StoreU32(map, pack);
			break;
		case PHI_FORMAT_R16_SFLOAT:
			StoreU16(map, FloatToHalf(c.values[0]));
			break;
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
			StoreU32(map, RoundUnsigned(c.values[0]));
			break;
		case PHI_FORMAT_R32_SFLOAT:
		case PHI_FORMAT_D32_SFLOAT:
			StoreF32(map, c.values[0]);
			break;
		case PHI_FORMAT_R8G8_SNORM:
			for(i = 0; i < 2; ++i)
				map[i] = (uint8_t)RoundSigned(c.values[i] * 127.0f);
			break;
		case PHI_FORMAT_R8G8_UNORM:
		case PHI_FORMAT_R8G8_SRGB:
			for(i = 0; i < 2; ++i)
				map[i] = (uint8_t)RoundUnsigned(c.values[i] * 255.0f);
			break;
		case PHI_FORMAT_R16G16_SNORM:
			for(i = 0; i < 2; ++i)
				StoreU16(map + 2 * i, (uint16_t)RoundSigned(c.values[i] * 32767.0f));
			break;
		case PHI_FORMAT_R16G16_UNORM:
			for(i = 0; i < 2; ++i)
				StoreU16(map + 2 * i, (uint16_t)RoundUnsigned(c.values[i] * 65535.0f));
			break;
		case PHI_FORMAT_R16G16_UINT:
			for(i = 0; i < 2; ++i)
				StoreU16(map + 2 * i, (uint16_t)RoundUnsigned(c.values[i]));
			break;
		case PHI_FORMAT_R16G16_SFLOAT:
			for(i = 0; i < 2; ++i)
				StoreU16(map + 2 * i, FloatToHalf(c.values[i]));
			break;
		case PHI_FORMAT_R32G32_SFLOAT:
			for(i = 0; i < 2; ++i)
				StoreF32(map + 4 * i, c.values[i]);
			break;
		case PHI_FORMAT_R16G16B16A16_UINT:
		case PHI_FORMAT_R16G16B16A16_UNORM:
			for(i = 0; i < 4; ++i)
				StoreU16(map + 2 * i, (uint16_t)RoundUnsigned(c.values[i] * 65535.0f));
			break;
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_SNORM:
			for(i = 0; i < 4; ++i)
				StoreU16(map + 2 * i, (uint16_t)RoundSigned(c.values[i] * 32767.0f));
			break;
		case PHI_FORMAT_R16G16B16A16_SFLOAT:
			for(i = 0; i < 4; ++i)
				StoreU16(map + 2 * i, FloatToHalf(c.values[i]));
			break;
		case PHI_FORMAT_R8G8B8_UNORM:
			map[0] = (uint8_t)RoundUnsigned(c.values[0] * 255.0f);
			map[1] = (uint8_t)RoundUnsigned(c.values[1] * 255.0f);
			map[2] = (uint8_t)RoundUnsigned(c.values[2] * 255.0f);
			break;
		case PHI_FORMAT_B8G8R8_UNORM:
			map[0] = (uint8_t)RoundUnsigned(c.values[2] * 255.0f);
			map[1] = (uint8_t)RoundUnsigned(c.values[1] * 255.0f);
			map[2] = (uint8_t)RoundUnsigned(c.values[0] * 255.0f);
			break;
		case PHI_FORMAT_B8G8R8A8_SRGB:
		case PHI_FORMAT_B8G8R8A8_UNORM:
			map[0] = (uint8_t)RoundUnsigned(c.values[2] * 255.0f);
			map[1] = (uint8_t)RoundUnsigned(c.values[1] * 255.0f);
			map[2] = (uint8_t)RoundUnsigned(c.values[0] * 255.0f);
			map[3] = (uint8_t)RoundUnsigned(c.values[3] * 255.0f);
			break;
		case PHI_FORMAT_R4G4B4A4_UNORM_PACK16:
		case PHI_FORMAT_B4G4R4A4_UNORM_PACK16:
		case PHI_FORMAT_A4R4G4B4_UNORM_PACK16:
		case PHI_FORMAT_A4B4G4R4_UNORM_PACK16:
			r = RoundUnsigned(c.values[0] * 15.0f);
			g = RoundUnsigned(c.values[1] * 15.0f);
			b = RoundUnsigned(c.values[2] * 15.0f);
			a = RoundUnsigned(c.values[3] * 15.0f);
			if(format == PHI_FORMAT_R4G4B4A4_UNORM_PACK16)
				pack = (r << 12) | (g << 8) | (b << 4) | a;
			else if(format == PHI_FORMAT_B4G4R4A4_UNORM_PACK16)
				pack = (b << 12) | (g << 8) | (r << 4) | a;
			else if(format == PHI_FORMAT_A4R4G4B4_UNORM_PACK16)
				pack = (a << 12) | (r << 8) | (g << 4) | b;
			else
				pack = (a << 12) | (b << 8) | (g << 4) | r;
			StoreU16(map, (uint16_t)pack);
			break;
		case PHI_FORMAT_R8G8B8A8_UNORM:
		case PHI_FORMAT_R8G8B8A8_SRGB:
		case PHI_FORMAT_R8G8B8A8_UINT:
		case PHI_FORMAT_R8G8B8A8_USCALED:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
			for(i = 0; i < 4; ++i)
				map[i] = (uint8_t)RoundUnsigned(c.values[i] * 255.0f);
			break;
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
		case PHI_FORMAT_R8G8B8A8_SNORM:
			for(i = 0; i < 4; ++i)
				map[i] = (uint8_t)RoundSigned(c.values[i] * 127.0f);
			break;
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
			r = RoundUnsigned(c.values[0] * 1023.0f);
			g = RoundUnsigned(c.values[1] * 1023.0f);
			b = RoundUnsigned(c.values[2] * 1023.0f);
			a = RoundUnsigned(c.values[3] * 3.0f);
			StoreU32(map, (b) | (g << 10) | (r << 20) | (a << 30));
			break;
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
			r = RoundUnsigned(c.values[0] * 1023.0f);
			g = RoundUnsigned(c.values[1] * 1023.0f);
			b = RoundUnsigned(c.values[2] * 1023.0f);
			a = RoundUnsigned(c.values[3] * 3.0f);
			StoreU32(map, r | (g << 10) | (b << 20) | (a << 30));
			break;
		case PHI_FORMAT_R32G32B32A32_UINT:
			for(i = 0; i < 4; ++i)
				StoreU32(map + 4 * i, RoundUnsigned(c.values[i]));
			break;
		case PHI_FORMAT_R32G32B32A32_SFLOAT:
			for(i = 0; i < 4; ++i)
				StoreF32(map + 4 * i, c.values[i]);
			break;
		case PHI_FORMAT_R5G6B5_UNORM_PACK16:
		case PHI_FORMAT_B5G6R5_UNORM_PACK16:
			r = RoundUnsigned(c.values[0] * 31.0f);
			g = RoundUnsigned(c.values[1] * 63.0f);
			b = RoundUnsigned(c.values[2] * 31.0f);
			StoreU16(
			    map,
			    (uint16_t)(format == PHI_FORMAT_R5G6B5_UNORM_PACK16 ? (r << 11) | (g << 5) | b : (b << 11) | (g << 5) | r));
			break;
		case PHI_FORMAT_R5G5B5A1_UNORM_PACK16:
		case PHI_FORMAT_B5G5R5A1_UNORM_PACK16:
			r = RoundUnsigned(c.values[0] * 31.0f);
			g = RoundUnsigned(c.values[1] * 31.0f);
			b = RoundUnsigned(c.values[2] * 31.0f);
			a = RoundUnsigned(c.values[3]);
			StoreU16(map,
			         (uint16_t)(format == PHI_FORMAT_R5G5B5A1_UNORM_PACK16 ? (r << 11) | (g << 6) | (b << 1) | a
			                                                               : (b << 11) | (g << 6) | (r << 1) | a));
			break;
		case PHI_FORMAT_A1R5G5B5_UNORM_PACK16:
			r = RoundUnsigned(c.values[0] * 31.0f);
			g = RoundUnsigned(c.values[1] * 31.0f);
			b = RoundUnsigned(c.values[2] * 31.0f);
			a = RoundUnsigned(c.values[3]);
			StoreU16(map, (uint16_t)(b | (g << 5) | (r << 10) | (a << 15)));
			break;
		case PHI_FORMAT_B10G11R11_UFLOAT_PACK32:
			StoreU32(map,
			         EncodeUFloat(c.values[0], 6) | (EncodeUFloat(c.values[1], 6) << 11) |
			             (EncodeUFloat(c.values[2], 5) << 22));
			break;
		case PHI_FORMAT_E5B9G9R9_UFLOAT_PACK32:
			StoreU32(map, EncodeE5B9G9R9(c));
			break;
		default:
			break;
	}
}

PhiBlitInt4 PhiReadBlitInt4(const uint8_t* map, PhiFormat format)
{
	PhiBlitInt4 c = { { 0u, 0u, 0u, 1u } };
	uint32_t pack;
	unsigned i;
	if(map == NULL || !CanReadInt(format))
		return c;
	switch((int)format)
	{
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_S8_UINT:
			c.values[0] = map[0];
			break;
		case PHI_FORMAT_R8_SINT:
			c.values[0] = SignExtend8(map[0]);
			break;
		case PHI_FORMAT_R16_UINT:
			c.values[0] = LoadU16(map);
			break;
		case PHI_FORMAT_R16_SINT:
			c.values[0] = SignExtend16(LoadU16(map));
			break;
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
			c.values[0] = LoadU32(map);
			break;
		case PHI_FORMAT_R8G8_UINT:
			for(i = 0; i < 2; ++i)
				c.values[i] = map[i];
			break;
		case PHI_FORMAT_R8G8_SINT:
			for(i = 0; i < 2; ++i)
				c.values[i] = SignExtend8(map[i]);
			break;
		case PHI_FORMAT_R16G16_UINT:
			for(i = 0; i < 2; ++i)
				c.values[i] = LoadU16(map + 2 * i);
			break;
		case PHI_FORMAT_R16G16_SINT:
			for(i = 0; i < 2; ++i)
				c.values[i] = SignExtend16(LoadU16(map + 2 * i));
			break;
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_UINT:
			for(i = 0; i < 2; ++i)
				c.values[i] = LoadU32(map + 4 * i);
			break;
		case PHI_FORMAT_R32G32B32_SINT:
		case PHI_FORMAT_R32G32B32_UINT:
			for(i = 0; i < 3; ++i)
				c.values[i] = LoadU32(map + 4 * i);
			break;
		case PHI_FORMAT_R8G8B8A8_UINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = map[i];
			break;
		case PHI_FORMAT_R8G8B8A8_SINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = SignExtend8(map[i]);
			break;
		case PHI_FORMAT_R16G16B16A16_UINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = LoadU16(map + 2 * i);
			break;
		case PHI_FORMAT_R16G16B16A16_SINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = SignExtend16(LoadU16(map + 2 * i));
			break;
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_UINT:
			for(i = 0; i < 4; ++i)
				c.values[i] = LoadU32(map + 4 * i);
			break;
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SNORM_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = map[i];
			break;
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
			for(i = 0; i < 4; ++i)
				c.values[i] = SignExtend8(map[i]);
			break;
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
			pack = LoadU32(map);
			c.values[0] = pack & 1023u;
			c.values[1] = (pack >> 10) & 1023u;
			c.values[2] = (pack >> 20) & 1023u;
			c.values[3] = pack >> 30;
			break;
		case PHI_FORMAT_A2B10G10R10_SINT_PACK32:
			pack = LoadU32(map);
			c.values[0] = (uint32_t)SignedBits(pack & 1023u, 10);
			c.values[1] = (uint32_t)SignedBits((pack >> 10) & 1023u, 10);
			c.values[2] = (uint32_t)SignedBits((pack >> 20) & 1023u, 10);
			c.values[3] = (uint32_t)SignedBits(pack >> 30, 2);
			break;
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
			pack = LoadU32(map);
			c.values[2] = pack & 1023u;
			c.values[1] = (pack >> 10) & 1023u;
			c.values[0] = (pack >> 20) & 1023u;
			c.values[3] = pack >> 30;
			break;
		case PHI_FORMAT_A2R10G10B10_SINT_PACK32:
			pack = LoadU32(map);
			c.values[2] = (uint32_t)SignedBits(pack & 1023u, 10);
			c.values[1] = (uint32_t)SignedBits((pack >> 10) & 1023u, 10);
			c.values[0] = (uint32_t)SignedBits((pack >> 20) & 1023u, 10);
			c.values[3] = (uint32_t)SignedBits(pack >> 30, 2);
			break;
		default:
			break;
	}
	return c;
}

static uint32_t ClampUnsignedBits(uint32_t value, uint32_t maximum)
{
	return value > maximum ? maximum : value;
}
static uint32_t ClampSignedBitsValue(uint32_t value, int32_t low, int32_t high)
{
	int32_t signed_value = (int32_t)value;
	if(signed_value < low)
		signed_value = low;
	if(signed_value > high)
		signed_value = high;
	return (uint32_t)signed_value;
}

void PhiWriteBlitInt4(PhiBlitInt4 input, uint8_t* map, PhiFormat format)
{
	PhiBlitInt4 c = input;
	uint32_t pack;
	unsigned i;
	if(map == NULL || !CanWriteInt(format))
		return;
	if(format == PHI_FORMAT_A2R10G10B10_UINT_PACK32 || format == PHI_FORMAT_A2B10G10R10_UINT_PACK32)
	{
		for(i = 0; i < 3; ++i)
			c.values[i] = ClampUnsignedBits(c.values[i], 1023u);
		c.values[3] = ClampUnsignedBits(c.values[3], 3u);
	}
	else if(format == PHI_FORMAT_A8B8G8R8_UINT_PACK32 || format == PHI_FORMAT_A8B8G8R8_USCALED_PACK32 ||
	        format == PHI_FORMAT_R8G8B8A8_UINT || format == PHI_FORMAT_R8G8_UINT || format == PHI_FORMAT_R8_UINT)
	{
		for(i = 0; i < 4; ++i)
			c.values[i] = ClampUnsignedBits(c.values[i], 255u);
	}
	else if(format == PHI_FORMAT_R16G16B16A16_UINT || format == PHI_FORMAT_R16G16_UINT || format == PHI_FORMAT_R16_UINT)
	{
		for(i = 0; i < 4; ++i)
			c.values[i] = ClampUnsignedBits(c.values[i], 65535u);
	}
	else if(format == PHI_FORMAT_A8B8G8R8_SINT_PACK32 || format == PHI_FORMAT_R8G8B8A8_SINT || format == PHI_FORMAT_R8G8_SINT ||
	        format == PHI_FORMAT_R8_SINT)
	{
		for(i = 0; i < 4; ++i)
			c.values[i] = ClampSignedBitsValue(c.values[i], -128, 127);
	}
	else if(format == PHI_FORMAT_R16G16B16A16_SINT || format == PHI_FORMAT_R16G16_SINT || format == PHI_FORMAT_R16_SINT)
	{
		for(i = 0; i < 4; ++i)
			c.values[i] = ClampSignedBitsValue(c.values[i], -32768, 32767);
	}
	switch((int)format)
	{
		case PHI_FORMAT_R8_SINT:
		case PHI_FORMAT_R8_UINT:
		case PHI_FORMAT_S8_UINT:
			map[0] = (uint8_t)c.values[0];
			break;
		case PHI_FORMAT_R8G8_SINT:
		case PHI_FORMAT_R8G8_UINT:
			for(i = 0; i < 2; ++i)
				map[i] = (uint8_t)c.values[i];
			break;
		case PHI_FORMAT_R16_SINT:
		case PHI_FORMAT_R16_UINT:
			StoreU16(map, (uint16_t)c.values[0]);
			break;
		case PHI_FORMAT_R16G16_SINT:
		case PHI_FORMAT_R16G16_UINT:
			for(i = 0; i < 2; ++i)
				StoreU16(map + 2 * i, (uint16_t)c.values[i]);
			break;
		case PHI_FORMAT_R32_SINT:
		case PHI_FORMAT_R32_UINT:
			StoreU32(map, c.values[0]);
			break;
		case PHI_FORMAT_R32G32_SINT:
		case PHI_FORMAT_R32G32_UINT:
			for(i = 0; i < 2; ++i)
				StoreU32(map + 4 * i, c.values[i]);
			break;
		case PHI_FORMAT_R8G8B8A8_SINT:
		case PHI_FORMAT_R8G8B8A8_UINT:
			for(i = 0; i < 4; ++i)
				map[i] = (uint8_t)c.values[i];
			break;
		case PHI_FORMAT_R16G16B16A16_SINT:
		case PHI_FORMAT_R16G16B16A16_UINT:
			for(i = 0; i < 4; ++i)
				StoreU16(map + 2 * i, (uint16_t)c.values[i]);
			break;
		case PHI_FORMAT_R32G32B32A32_SINT:
		case PHI_FORMAT_R32G32B32A32_UINT:
			for(i = 0; i < 4; ++i)
				StoreU32(map + 4 * i, c.values[i]);
			break;
		case PHI_FORMAT_A8B8G8R8_UNORM_PACK32:
		case PHI_FORMAT_A8B8G8R8_SINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_SRGB_PACK32:
		case PHI_FORMAT_A8B8G8R8_UINT_PACK32:
		case PHI_FORMAT_A8B8G8R8_USCALED_PACK32:
			for(i = 0; i < 4; ++i)
				map[i] = (uint8_t)c.values[i];
			break;
		case PHI_FORMAT_A2R10G10B10_UNORM_PACK32:
		case PHI_FORMAT_A2R10G10B10_UINT_PACK32:
		case PHI_FORMAT_A2R10G10B10_USCALED_PACK32:
		case PHI_FORMAT_A2R10G10B10_SSCALED_PACK32:
			pack = (c.values[0] << 20) | (c.values[2]) | (c.values[1] << 10) | (c.values[3] << 30);
			StoreU32(map, pack);
			break;
		case PHI_FORMAT_A2B10G10R10_UNORM_PACK32:
		case PHI_FORMAT_A2B10G10R10_UINT_PACK32:
			pack = (c.values[0] & 1023u) | ((c.values[1] & 1023u) << 10) | ((c.values[2] & 1023u) << 20) |
			       ((c.values[3] & 3u) << 30);
			StoreU32(map, pack);
			break;
		default:
			break;
	}
}

static float SrgbToLinear(float value)
{
	return value <= 0.04045f ? value / 12.92f : powf((value + 0.055f) / 1.055f, 2.4f);
}

static float LinearToSrgb(float value)
{
	return value <= 0.0031308f ? value * 12.92f : 1.055f * powf(value, 1.0f / 2.4f) - 0.055f;
}

PhiBlitFloat4 PhiConvertBlitFloat4(PhiBlitFloat4 color,
                                   PhiFormat src_format,
                                   PhiFormat dst_format,
                                   int allow_srgb_conversion,
                                   int apply_srgb_conversion)
{
	float scale[4];
	unsigned i;
	if(IsFloat(src_format) && !IsFloat(dst_format))
	{
		ScaleForFormat(dst_format, scale);
		for(i = 0; i < 4; ++i)
		{
			float low = IsUnsignedComponent(dst_format, i) ? 0.0f : -scale[i];
			color.values[i] = Clamp(color.values[i], low, scale[i]);
		}
	}
	if(allow_srgb_conversion && ((IsSrgb(src_format) && apply_srgb_conversion) || IsSrgb(dst_format)))
	{
		for(i = 0; i < 3; ++i)
			color.values[i] =
			    (IsSrgb(src_format) && apply_srgb_conversion) ? SrgbToLinear(color.values[i]) : LinearToSrgb(color.values[i]);
	}
	if(!IsUnsignedComponent(src_format, 0u) && IsUnsignedComponent(dst_format, 0u))
		for(i = 0; i < 4; ++i)
			if(color.values[i] < 0.0f)
				color.values[i] = 0.0f;
	return color;
}
