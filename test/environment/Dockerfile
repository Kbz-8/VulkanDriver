FROM ubuntu:latest

WORKDIR /root

RUN apt update && apt install -y git rustup clang curl libgl1 libsm6 libwayland-egl1 libwayland-cursor0 libwayland-server0;
RUN rustup default stable;
RUN cargo install deqp-runner && cp $HOME/.cargo/bin/deqp-runner /usr/bin;
RUN curl -L https://github.com/marler8997/anyzig/releases/latest/download/anyzig-x86_64-linux.tar.gz | tar xz && mv zig /usr/bin/;
RUN git clone https://git.kbz8.me/kbz_8/VulkanDriver.git && cd VulkanDriver;

ENTRYPOINT ["/usr/bin/bash"]
