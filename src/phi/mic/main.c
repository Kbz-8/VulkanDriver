#include <errno.h>
#include <pthread.h>
#include <stdint.h>

#include <Daemon.h>
#include <Logger.h>

static void* HandleClient(void* const argument)
{
	scif_epd_t client = (scif_epd_t)(intptr_t)argument;

	(void)HandlePacket(client);
	scif_close(client);
	return NULL;
}

int main(void)
{
	scif_epd_t endpoint = StartDaemon();
	pthread_attr_t client_thread_attributes;

	if(endpoint == 0)
		return 1;

	if(pthread_attr_init(&client_thread_attributes) != 0 ||
	   pthread_attr_setdetachstate(&client_thread_attributes, PTHREAD_CREATE_DETACHED) != 0)
	{
		PhiLogError("Could not initialize client thread attributes");
		ShutdownDaemon(endpoint);
		return 1;
	}

	for(;;)
	{
		struct scif_portID peer;
		scif_epd_t client;

		if(scif_accept(endpoint, &peer, &client, SCIF_ACCEPT_SYNC) < 0)
		{
			if(errno == EINTR)
				continue;
			PhiLogError("Could not accept SCIF connection");
			break;
		}

		pthread_t client_thread;
		if(pthread_create(&client_thread, &client_thread_attributes, HandleClient, (void*)(intptr_t)client) != 0)
		{
			PhiLogError("Could not create SCIF client thread");
			scif_close(client);
		}
	}

	pthread_attr_destroy(&client_thread_attributes);
	ShutdownDaemon(endpoint);

	return 0;
}
