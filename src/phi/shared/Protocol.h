#ifndef APE_PHI_PROTOCOL_H
#define APE_PHI_PROTOCOL_H

#include "Commands.h" // IWYU pragma: keep
#include <stdint.h>

#define PHI_PROTOCOL_MAGIC 0x50484941u
#define PHI_PROTOCOL_VERSION 1u
#define PHI_SCIF_PORT 43616u

typedef enum PhiPacketType
{
	PHI_PACKET_HELLO = 1,
	PHI_PACKET_ALLOC_MEMORY = 2,
	PHI_PACKET_FREE_MEMORY = 3,
	PHI_PACKET_UPLOAD = 4,
	PHI_PACKET_DOWNLOAD = 5,
	PHI_PACKET_WORK_EXECUTION = 6,
	PHI_PACKET_SHUTDOWN = 7,
} PhiPacketType;

typedef enum PhiStatus
{
	PHI_STATUS_OK = 0,
	PHI_STATUS_BAD_MESSAGE = 1,
	PHI_STATUS_UNSUPPORTED_VERSION = 2,
	PHI_STATUS_UNSUPPORTED_PACKET = 3,
	PHI_STATUS_OUT_OF_MEMORY = 4,
	PHI_STATUS_INVALID_HANDLE = 5,
} PhiStatus;

typedef struct PhiMessageHeader
{
	uint32_t magic;
	uint16_t version;
	uint16_t type;
	uint64_t sequence;
	uint64_t payload_size;
} PhiMessageHeader;

typedef struct PhiResult
{
	int32_t status;
	uint32_t reserved;
} PhiResult;

typedef struct PhiHelloRequest
{
	uint32_t host_protocol_version;
	uint32_t reserved;
} PhiHelloRequest;

typedef struct PhiHelloReply
{
	PhiResult result;
	uint32_t device_protocol_version;
	uint32_t pointer_bits;
} PhiHelloReply;

typedef struct PhiAllocMemoryRequest
{
	uint64_t size;
	uint32_t memory_type_index;
	uint32_t flags;
} PhiAllocMemoryRequest;

typedef struct PhiAllocMemoryReply
{
	PhiResult result;
	uint64_t remote_handle;
	uint64_t size;
} PhiAllocMemoryReply;

typedef struct PhiFreeMemoryRequest
{
	uint64_t remote_handle;
} PhiFreeMemoryRequest;

typedef struct PhiFreeMemoryReply
{
	PhiResult result;
} PhiFreeMemoryReply;

typedef struct PhiWorkExecutionRequest
{
	uint64_t cmd_count;
	uint64_t command_buffer_size;
} PhiWorkExecutionRequest;

typedef struct PhiWorkExecutionReply
{
	PhiResult result;
} PhiWorkExecutionReply;

#endif
