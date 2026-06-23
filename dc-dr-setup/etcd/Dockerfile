FROM alpine:3.19

# Alpine has BusyBox wget built-in — no apk needed.
# --no-check-certificate bypasses the corporate SSL inspection proxy's cert.
ARG ETCD_VER=v3.5.9
ARG ARCH=amd64

RUN wget --no-check-certificate -q \
    "https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-${ARCH}.tar.gz" \
    -O /tmp/etcd.tar.gz \
    && tar -xzf /tmp/etcd.tar.gz -C /tmp \
    && mv /tmp/etcd-${ETCD_VER}-linux-${ARCH}/etcd     /usr/local/bin/etcd \
    && mv /tmp/etcd-${ETCD_VER}-linux-${ARCH}/etcdctl  /usr/local/bin/etcdctl \
    && rm -rf /tmp/etcd*

EXPOSE 2379 2380
ENTRYPOINT ["/usr/local/bin/etcd"]
