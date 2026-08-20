#ifndef APE_PHI_PROTOCOL_H
#define APE_PHI_PROTOCOL_H

#include "Commands.h" // IWYU pragma: keep
#include <stdint.h>

#define PHI_MEMORY_ALIGNMENT 64

#define PHI_PROTOCOL_MAGIC 0x50484941u
#define PHI_PROTOCOL_VERSION 2u
#define PHI_SCIF_PORT 43616u

#define PHI_QUEUE_RING_CAPACITY 64u
#define PHI_QUEUE_SHUTDOWN_SEQUENCE UINT64_MAX

#ifndef PHI_TRANSPORT_PORT
#define PHI_TRANSPORT_PORT PHI_SCIF_PORT
#endif

typedef enum PhiPacketType
{
	PHI_PACKET_HELLO = 1,
	PHI_PACKET_ALLOC_MEMORY = 2,
	PHI_PACKET_DESTROY_MEMORY = 3,
	PHI_PACKET_UPLOAD = 4,
	PHI_PACKET_DOWNLOAD = 5,
	PHI_PACKET_WORK_EXECUTION = 6,
	PHI_PACKET_SHUTDOWN = 7,
	PHI_PACKET_MAP_HOST_MEMORY = 8,
	PHI_PACKET_QUEUE_SETUP = 9,
} PhiPacketType;

// When adding status, update StatusName in Logger.h
typedef enum PhiStatus
{
	PHI_STATUS_OK = 0,
	PHI_STATUS_BAD_MESSAGE = 1,
	PHI_STATUS_UNSUPPORTED_VERSION = 2,
	PHI_STATUS_UNSUPPORTED_PACKET = 3,
	PHI_STATUS_OUT_OF_MEMORY = 4,
	PHI_STATUS_INVALID_HANDLE = 5,
	PHI_STATUS_MAP_HOST_MEMORY_FAILED = 6,
	PHI_STATUS_INVALID_ARGUMENT = 7,
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

typedef struct PhiResultReply
{
	PhiResult result;
} PhiResultReply;

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

typedef struct PhiNewMemoryReply
{
	PhiResult result;
	uint64_t remote_handle;
	uint64_t size;
} PhiNewMemoryReply;

typedef struct PhiMapHostMemoryRequest
{
	uint64_t scif_offset;
	uint64_t scif_size;
	uint64_t size;
} PhiMapHostMemoryRequest;

typedef struct PhiDestroyMemoryRequest
{
	uint64_t remote_handle;
} PhiDestroyMemoryRequest;

typedef struct PhiWorkExecutionRequest
{
	uint64_t cmd_count;
	uint64_t command_buffer_size;
} PhiWorkExecutionRequest;

typedef struct PhiQueueSubmission
{
	uint64_t sequence;
	uint64_t command_scif_offset;
	uint64_t command_size;
	uint64_t command_count;
} PhiQueueSubmission;

typedef struct PhiQueueShared
{
	// Host-written producer timeline. Keep it on its own cache line
	uint64_t producer_sequence;
	uint8_t producer_padding[56];

	// MIC-written completion timeline. Keep it on its own cache line
	uint64_t completed_sequence;
	uint8_t completion_padding[56];

	PhiQueueSubmission submissions[PHI_QUEUE_RING_CAPACITY];
} PhiQueueShared;

typedef struct PhiQueueSetupRequest
{
	uint64_t scif_offset;
	uint64_t scif_size;
	uint32_t ring_capacity;
	uint32_t reserved;
} PhiQueueSetupRequest;

typedef struct PhiQueueDoorbell
{
	uint64_t sequence;
} PhiQueueDoorbell;

typedef struct PhiQueueCompletion
{
	uint64_t sequence;
	int32_t status;
	uint32_t reserved;
} PhiQueueCompletion;

#endif
