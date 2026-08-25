FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        clang \
        llvm \
        libbpf-dev \
        linux-headers-generic \
        make \
        bpftool \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY Makefile ./
COPY bpf ./bpf
COPY config ./config

# /sys is shared with the host, so vmlinux.h is generated from the host BTF.
# The resulting object is CO-RE relocatable and runs on any BTF-enabled kernel.
# HOST_UID/HOST_GID keep the artifacts owned by the invoking user instead of root.
CMD ["sh", "-c", "make build && cp dist/* /out/ && chown -R ${HOST_UID:-0}:${HOST_GID:-0} /out"]
