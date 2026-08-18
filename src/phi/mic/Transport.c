#include <Transport.h>

PhiEndpoint PhiTransportAccept(PhiEndpoint endpoint)
{
	struct scif_portID peer;
	PhiEndpoint client = PHI_ENDPOINT_INVALID;
	if(scif_accept(endpoint, &peer, &client, SCIF_ACCEPT_SYNC) < 0)
		return PHI_ENDPOINT_INVALID;
	return client;
}

int PhiTransportClose(PhiEndpoint endpoint)
{
	return scif_close(endpoint);
}

PhiEndpoint PhiTransportListen(uint16_t port)
{
	PhiEndpoint endpoint = scif_open();
	if(endpoint == PHI_ENDPOINT_INVALID)
		return PHI_ENDPOINT_INVALID;

	if(scif_bind(endpoint, port) < 0 || scif_listen(endpoint, 16) < 0)
	{
		PhiTransportClose(endpoint);
		return PHI_ENDPOINT_INVALID;
	}
	return endpoint;
}

ssize_t PhiTransportReceive(PhiEndpoint endpoint, void* data, size_t size)
{
	return scif_recv(endpoint, data, size, SCIF_RECV_BLOCK);
}

ssize_t PhiTransportSend(PhiEndpoint endpoint, const void* data, size_t size)
{
	return scif_send(endpoint, (void*)data, size, SCIF_SEND_BLOCK);
}
