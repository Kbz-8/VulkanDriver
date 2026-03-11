## Small testing environment

A simple small testing environment in a docker container to test the driver with controlled resources usage.

To launch the container with 8GB of memory limit: `docker compose up -d`\
To launch the container with custom memory limit: `MEM_LIMIT="20g" docker compose up -d`\
To shell into it: `docker compose run --rm ubuntu-shell`
