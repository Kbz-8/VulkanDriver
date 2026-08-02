#ifndef APE_PHI_DAEMON_H
#define APE_PHI_DAEMON_H

#include <sys/types.h>

#include <Protocol.h>
#include <Transport.h>

PhiEndpoint StartDaemon(void);
void ShutdownDaemon(PhiEndpoint endpoint);

int DrainPayload(PhiEndpoint endpoint, uint64_t size);
int HandlePacket(PhiEndpoint endpoint);
int ReadAll(PhiEndpoint endpoint, void* data, size_t size);
int SendReply(PhiEndpoint endpoint, const PhiMessageHeader* request, const void* payload, uint64_t payload_size);
int SendStatus(PhiEndpoint endpoint, const PhiMessageHeader* request, PhiStatus status);
int WriteAll(PhiEndpoint endpoint, const void* data, size_t size);

#endif
