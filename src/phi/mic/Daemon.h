#ifndef APE_PHI_DAEMON_H
#define APE_PHI_DAEMON_H

#include <sys/types.h>

#include <scif.h>

#include <Protocol.h>

scif_epd_t StartDaemon();
void ShutdownDaemon(scif_epd_t endpoint);

int DrainPayload(scif_epd_t endpoint, uint64_t size);
int HandlePacket(scif_epd_t endpoint);
int ReadAll(scif_epd_t endpoint, void* data, size_t size);
int SendReply(scif_epd_t endpoint, const PhiMessageHeader* request, const void* payload, uint64_t payload_size);
int SendStatus(scif_epd_t endpoint, const PhiMessageHeader* request, PhiStatus status);
int WriteAll(scif_epd_t endpoint, const void* data, size_t size);

#endif
