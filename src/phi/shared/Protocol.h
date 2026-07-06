#ifndef APE_PHI_PROTOCOL_H
#define APE_PHI_PROTOCOL_H

#include <stdint.h>

#define PHI_PROTOCOL_MAGIC 0x50484941u
#define PHI_PROTOCOL_VERSION 1u
#define PHI_RPOTOCOL_VERSION PHI_PROTOCOL_VERSION
#define PHI_SCIF_PORT 43616u

typedef enum PhiCommandType
{
	PHI_COMMAND_HELLO = 1,
	PHI_COMMAND_ALLOC_MEMORY = 2,
	PHI_COMMAND_FREE_MEMORY = 3,
	PHI_COMMAND_UPLOAD = 4,
	PHI_COMMAND_DOWNLOAD = 5,
	PHI_COMMAND_SUBMIT = 6,
	PHI_COMMAND_SHUTDOWN = 7,
} PhiCommandType;

typedef enum PhiStatus
{
	PHI_STATUS_OK = 0,
	PHI_STATUS_BAD_MESSAGE = 1,
	PHI_STATUS_UNSUPPORTED_VERSION = 2,
	PHI_STATUS_UNSUPPORTED_COMMAND = 3,
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

#endif
