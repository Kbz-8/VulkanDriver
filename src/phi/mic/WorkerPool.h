#ifndef APE_PHI_WORKER_POOL_H
#define APE_PHI_WORKER_POOL_H

#include <stdint.h>

typedef void (*WorkerPoolTask)(void* context, uint64_t begin, uint64_t end);

uint32_t WorkerPoolGetWorkerCount(void);
void WorkerPoolParallelFor(uint64_t item_count, uint64_t grain_size, WorkerPoolTask task, void* context);

#endif
