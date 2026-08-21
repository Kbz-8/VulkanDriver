#include <Queue.h>

#include <CommandBuffer.h>
#include <Daemon.h>
#include <Logger.h>

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static PhiStatus ExecuteQueueSubmission(PhiEndpoint endpoint, const PhiQueueSubmission* submission)
{
	if(submission->command_size == 0)
		return submission->command_count == 0 ? PHI_STATUS_OK : PHI_STATUS_BAD_MESSAGE;

	if(submission->command_count == 0)
		return PHI_STATUS_BAD_MESSAGE;

	void* commands = malloc((size_t)submission->command_size);
	if(commands == NULL)
		return PHI_STATUS_OUT_OF_MEMORY;

	PhiStatus status = PHI_STATUS_OK;
	if(TransportReadRemote(endpoint, commands, (size_t)submission->command_size, submission->command_scif_offset) < 0)
	{
		LogErrorFmt("Failed to read from host: %s", strerror(errno));
		status = PHI_STATUS_INVALID_HANDLE;
	}
	else
		status = ExecuteCommandBuffer(commands, submission->command_size, submission->command_count);

	free(commands);
	return status;
}

static int SendQueueCompletion(PhiEndpoint endpoint, uint64_t sequence, PhiStatus status)
{
	const PhiQueueCompletion completion = {
		.sequence = sequence,
		.status = status,
		.reserved = 0,
	};
	return WriteAll(endpoint, &completion, sizeof(completion));
}

// Returns 1 for a graceful queue shutdown, 0 when the peer disconnects, and -1 for a transport failure
static int RunQueue(PhiEndpoint endpoint, volatile PhiQueueShared* shared)
{
	uint64_t next_sequence = 1;

	for(;;)
	{
		PhiQueueDoorbell doorbell;
		if(ReadAll(endpoint, &doorbell, sizeof(doorbell)) < 0)
		{
			LogWarningFmt("Queue peer disconnected while waiting for sequence %llu", (unsigned long long)next_sequence);
			return 0;
		}

		if(doorbell.sequence == PHI_QUEUE_SHUTDOWN_SEQUENCE)
		{
			LogInfoFmt("Received queue shutdown doorbell at sequence %llu", (unsigned long long)next_sequence);
			return 1;
		}

		if(doorbell.sequence < next_sequence)
			continue;

		while(next_sequence <= doorbell.sequence)
		{
			const size_t slot = (size_t)((next_sequence - 1u) % PHI_QUEUE_RING_CAPACITY);

			__atomic_thread_fence(__ATOMIC_ACQUIRE);
			const volatile PhiQueueSubmission* remote_submission = &shared->submissions[slot];
			const PhiQueueSubmission submission = {
				.sequence = remote_submission->sequence,
				.command_scif_offset = remote_submission->command_scif_offset,
				.command_size = remote_submission->command_size,
				.command_count = remote_submission->command_count,
			};

			PhiStatus status;
			if(submission.sequence != next_sequence)
				status = PHI_STATUS_BAD_MESSAGE;
			else
				status = ExecuteQueueSubmission(endpoint, &submission);

			if(status != PHI_STATUS_OK)
				LogErrorFmt("Queue submission %llu failed: %s", (unsigned long long)next_sequence, StatusName[status]);

			__atomic_store_n(&shared->completed_sequence, next_sequence, __ATOMIC_RELEASE);
			if(SendQueueCompletion(endpoint, next_sequence, status) < 0)
				return -1;

			++next_sequence;
		}
	}
}

int HandleQueueSetup(PhiEndpoint endpoint, const PhiMessageHeader* header)
{
	PhiQueueSetupRequest request;
	PhiResultReply reply = {
		.result = {
			.status = PHI_STATUS_OK,
			.reserved = 0,
		},
	};

	if(header->payload_size != sizeof(request))
	{
		if(DrainPayload(endpoint, header->payload_size) < 0)
			return -1;
		reply.result.status = PHI_STATUS_BAD_MESSAGE;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	if(ReadAll(endpoint, &request, sizeof(request)) < 0)
		return -1;

	if(request.ring_capacity != PHI_QUEUE_RING_CAPACITY || request.scif_size < sizeof(PhiQueueShared))
	{
		reply.result.status = PHI_STATUS_INVALID_ARGUMENT;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	volatile PhiQueueShared* shared =
	    scif_mmap(NULL, (size_t)request.scif_size, PROT_READ | PROT_WRITE, 0, endpoint, request.scif_offset);
	if(shared == MAP_FAILED)
	{
		reply.result.status = PHI_STATUS_MAP_HOST_MEMORY_FAILED;
		return SendReply(endpoint, header, &reply, sizeof(reply));
	}

	if(SendReply(endpoint, header, &reply, sizeof(reply)) < 0)
	{
		scif_munmap((void*)shared, (size_t)request.scif_size);
		return -1;
	}

	const int run_result = RunQueue(endpoint, shared);
	if(scif_munmap((void*)shared, (size_t)request.scif_size) != 0)
	{
		LogErrorFmt("Failed to unmap queue ring during shutdown: %s", strerror(errno));
		return -1;
	}

	if(run_result == 1)
	{
		LogInfo("Queue ring unmapped; sending shutdown acknowledgement");
		if(SendQueueCompletion(endpoint, PHI_QUEUE_SHUTDOWN_SEQUENCE, PHI_STATUS_OK) < 0)
		{
			LogErrorFmt("Failed to send queue shutdown acknowledgement: %s", strerror(errno));
			return -1;
		}
		LogInfo("Queue shutdown acknowledgement sent");
		return 0;
	}

	return run_result;
}
