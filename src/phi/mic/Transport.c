#include <Transport.h>

#ifdef PHI_HOST_EMULATION

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static struct sockaddr_in PhiLoopbackAddress(uint16_t port)
{
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_port = htons(port),
		.sin_addr = {
			.s_addr = htonl(INADDR_LOOPBACK),
		},
	};
	return address;
}

PhiEndpoint PhiTransportAccept(PhiEndpoint endpoint)
{
	return accept(endpoint, NULL, NULL);
}

int PhiTransportClose(PhiEndpoint endpoint)
{
	return close(endpoint);
}

PhiEndpoint PhiTransportListen(uint16_t port)
{
	PhiEndpoint endpoint = socket(AF_INET, SOCK_STREAM, 0);
	if(endpoint == PHI_ENDPOINT_INVALID)
		return PHI_ENDPOINT_INVALID;

	const int reuse_address = 1;
	if(setsockopt(endpoint, SOL_SOCKET, SO_REUSEADDR, &reuse_address, sizeof(reuse_address)) < 0)
	{
		PhiTransportClose(endpoint);
		return PHI_ENDPOINT_INVALID;
	}

	const struct sockaddr_in address = PhiLoopbackAddress(port);
	if(bind(endpoint, (const struct sockaddr*)&address, sizeof(address)) < 0 || listen(endpoint, 16) < 0)
	{
		PhiTransportClose(endpoint);
		return PHI_ENDPOINT_INVALID;
	}

	return endpoint;
}

ssize_t PhiTransportReceive(PhiEndpoint endpoint, void* data, size_t size)
{
	return recv(endpoint, data, size, 0);
}

ssize_t PhiTransportSend(PhiEndpoint endpoint, const void* data, size_t size)
{
#ifdef MSG_NOSIGNAL
	return send(endpoint, data, size, MSG_NOSIGNAL);
#else
	return send(endpoint, data, size, 0);
#endif
}

#else

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

#endif
