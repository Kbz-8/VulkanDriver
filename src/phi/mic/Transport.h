#ifndef APE_PHI_TRANSPORT_H
#define APE_PHI_TRANSPORT_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include <scif.h>
typedef scif_epd_t PhiEndpoint;

#define PHI_ENDPOINT_INVALID ((PhiEndpoint) - 1)

PhiEndpoint TransportAccept(PhiEndpoint endpoint);
int TransportClose(PhiEndpoint endpoint);

PhiEndpoint TransportListen(uint16_t port);
ssize_t TransportReceive(PhiEndpoint endpoint, void* data, size_t size);
ssize_t TransportSend(PhiEndpoint endpoint, const void* data, size_t size);

#endif
