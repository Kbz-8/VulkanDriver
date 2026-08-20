#include <Transport.h>

PhiEndpoint TransportAccept(PhiEndpoint endpoint)
{
	struct scif_portID peer;
	PhiEndpoint client = PHI_ENDPOINT_INVALID;
	if(scif_accept(endpoint, &peer, &client, SCIF_ACCEPT_SYNC) < 0)
		return PHI_ENDPOINT_INVALID;
	return client;
}

int TransportClose(PhiEndpoint endpoint)
{
	return scif_close(endpoint);
}

PhiEndpoint TransportListen(uint16_t port)
{
	PhiEndpoint endpoint = scif_open();
	if(endpoint == PHI_ENDPOINT_INVALID)
		return PHI_ENDPOINT_INVALID;

	if(scif_bind(endpoint, port) < 0 || scif_listen(endpoint, 16) < 0)
	{
		TransportClose(endpoint);
		return PHI_ENDPOINT_INVALID;
	}
	return endpoint;
}

int TransportReadRemote(PhiEndpoint endpoint, void* data, size_t size, uint64_t remote_offset)
{
	if(size == 0)
		return 0;
	return scif_vreadfrom(endpoint, data, size, (off_t)remote_offset, SCIF_RMA_SYNC);
}

ssize_t TransportReceive(PhiEndpoint endpoint, void* data, size_t size)
{
	return scif_recv(endpoint, data, size, SCIF_RECV_BLOCK);
}

ssize_t TransportSend(PhiEndpoint endpoint, const void* data, size_t size)
{
	return scif_send(endpoint, (void*)data, size, SCIF_SEND_BLOCK);
}
