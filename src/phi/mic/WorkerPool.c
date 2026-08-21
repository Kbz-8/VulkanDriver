#include <WorkerPool.h>

#include <errno.h>

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#define PHI_WORKER_STACK_SIZE (128u * 1024u)
#define PHI_WORKER_MAX_COUNT 255u

typedef struct WorkerPool
{
	pthread_mutex_t submission_mutex;
	pthread_mutex_t work_mutex;
	pthread_cond_t work_available;
	pthread_cond_t work_complete;

	uint64_t generation;
	uint64_t item_count;
	uint64_t grain_size;
	uint64_t next_item;

	WorkerPoolTask task;
	void* context;

	uint32_t worker_count;
	uint32_t workers_pending;
} WorkerPool;

static WorkerPool Pool = {
	.submission_mutex = PTHREAD_MUTEX_INITIALIZER,
	.work_mutex = PTHREAD_MUTEX_INITIALIZER,
	.work_available = PTHREAD_COND_INITIALIZER,
	.work_complete = PTHREAD_COND_INITIALIZER,
};
static pthread_once_t PoolInitialization = PTHREAD_ONCE_INIT;

static int TakeWork(WorkerPoolTask* task, void** context, uint64_t* begin, uint64_t* end)
{
	int has_work = 0;
	pthread_mutex_lock(&Pool.work_mutex);

	if(Pool.next_item < Pool.item_count)
	{
		*begin = Pool.next_item;
		uint64_t remaining = Pool.item_count - Pool.next_item;
		uint64_t count = remaining < Pool.grain_size ? remaining : Pool.grain_size;
		Pool.next_item += count;
		*end = Pool.next_item;
		*task = Pool.task;
		*context = Pool.context;
		has_work = 1;
	}

	pthread_mutex_unlock(&Pool.work_mutex);
	return has_work;
}

static void RunAvailableWork(void)
{
	WorkerPoolTask task;
	void* context;
	uint64_t begin;
	uint64_t end;

	while(TakeWork(&task, &context, &begin, &end))
		task(context, begin, end);
}

static void* WorkerMain(void* argument)
{
	(void)argument;
	uint64_t generation = 0;

	for(;;)
	{
		pthread_mutex_lock(&Pool.work_mutex);
		while(Pool.generation == generation)
			pthread_cond_wait(&Pool.work_available, &Pool.work_mutex);
		generation = Pool.generation;
		pthread_mutex_unlock(&Pool.work_mutex);

		RunAvailableWork();

		pthread_mutex_lock(&Pool.work_mutex);
		--Pool.workers_pending;
		if(Pool.workers_pending == 0)
			pthread_cond_signal(&Pool.work_complete);
		pthread_mutex_unlock(&Pool.work_mutex);
	}

	return NULL;
}

static uint32_t GetConfiguredWorkerCount(void)
{
	long online_cpu_count = sysconf(_SC_NPROCESSORS_ONLN);
	uint32_t worker_count = online_cpu_count > 1 ? (uint32_t)(online_cpu_count - 1) : 0;
	if(worker_count > PHI_WORKER_MAX_COUNT)
		worker_count = PHI_WORKER_MAX_COUNT;

	const char* configured_count = getenv("PHI_BLIT_THREADS");
	if(configured_count != NULL && configured_count[0] != '\0')
	{
		char* end;
		errno = 0;
		unsigned long value = strtoul(configured_count, &end, 10);
		if(errno == 0 && *end == '\0' && value <= PHI_WORKER_MAX_COUNT)
			worker_count = (uint32_t)value;
	}

	return worker_count;
}

static void InitializePool(void)
{
	const uint32_t requested_count = GetConfiguredWorkerCount();
	if(requested_count == 0)
		return;

	pthread_attr_t attributes;
	if(pthread_attr_init(&attributes) != 0)
		return;

	(void)pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
	size_t stack_size = PHI_WORKER_STACK_SIZE;
	const long minimum_stack_size = sysconf(_SC_THREAD_STACK_MIN);
	if(minimum_stack_size > 0 && stack_size < (size_t)minimum_stack_size)
		stack_size = (size_t)minimum_stack_size;
	(void)pthread_attr_setstacksize(&attributes, stack_size);

	for(uint32_t worker = 0; worker < requested_count; ++worker)
	{
		pthread_t thread;
		if(pthread_create(&thread, &attributes, WorkerMain, NULL) != 0)
			break;
		++Pool.worker_count;
	}

	pthread_attr_destroy(&attributes);
}

uint32_t WorkerPoolGetWorkerCount(void)
{
	pthread_once(&PoolInitialization, InitializePool);
	return Pool.worker_count;
}

void WorkerPoolParallelFor(uint64_t item_count, uint64_t grain_size, WorkerPoolTask task, void* context)
{
	if(item_count == 0 || task == NULL)
		return;
	if(grain_size == 0)
		grain_size = 1;

	pthread_once(&PoolInitialization, InitializePool);
	if(Pool.worker_count == 0 || item_count <= grain_size)
	{
		task(context, 0, item_count);
		return;
	}

	pthread_mutex_lock(&Pool.submission_mutex);
	pthread_mutex_lock(&Pool.work_mutex);
	Pool.item_count = item_count;
	Pool.grain_size = grain_size;
	Pool.next_item = 0;
	Pool.task = task;
	Pool.context = context;
	Pool.workers_pending = Pool.worker_count;
	++Pool.generation;
	pthread_cond_broadcast(&Pool.work_available);
	pthread_mutex_unlock(&Pool.work_mutex);

	RunAvailableWork();

	pthread_mutex_lock(&Pool.work_mutex);
	while(Pool.workers_pending != 0)
		pthread_cond_wait(&Pool.work_complete, &Pool.work_mutex);
	pthread_mutex_unlock(&Pool.work_mutex);
	pthread_mutex_unlock(&Pool.submission_mutex);
}
