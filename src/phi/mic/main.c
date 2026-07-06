#include <Daemon.h>
#include <Logger.h>

int main(void)
{
	scif_epd_t endpoint = StartDaemon();

	if(endpoint == 0)
		return 1;

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

		(void)HandlePacket(client);

		scif_close(client);
	}

	ShutdownDaemon(endpoint);

	return 0;
}
