#include <errno.h>
#include <pthread.h>
#include <stdint.h>

#include <Daemon.h>
#include <Logger.h>

static void* HandleClient(void* const argument)
{
	PhiEndpoint client = (PhiEndpoint)(intptr_t)argument;

	(void)HandlePacket(client);
	PhiTransportClose(client);
	return NULL;
}

int main(int argc, char** argv)
{
	(void)argc;
	(void)argv;

	PhiEndpoint endpoint = StartDaemon();
	pthread_attr_t client_thread_attributes;

	if(endpoint == PHI_ENDPOINT_INVALID)
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
		PhiEndpoint client = PhiTransportAccept(endpoint);

		if(client == PHI_ENDPOINT_INVALID)
		{
			if(errno == EINTR)
				continue;
			PhiLogError("Could not accept transport connection");
			break;
		}

		PhiLogInfo("Host connected to the daemon");

		pthread_t client_thread;
		if(pthread_create(&client_thread, &client_thread_attributes, HandleClient, (void*)(intptr_t)client) != 0)
		{
			PhiLogError("Could not create transport client thread");
			PhiTransportClose(client);
		}
	}

	pthread_attr_destroy(&client_thread_attributes);
	ShutdownDaemon(endpoint);

	return 0;
}
