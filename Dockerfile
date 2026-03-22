FROM alpine:3.20 AS builder

ARG MICROSOCKS_REF=v1.0.5
RUN apk add --no-cache build-base curl tar
RUN curl -fsSL "https://github.com/rofl0r/microsocks/archive/refs/tags/${MICROSOCKS_REF}.tar.gz" -o /tmp/microsocks.tar.gz \
    && mkdir -p /src \
    && tar -xzf /tmp/microsocks.tar.gz -C /src --strip-components=1 \
    && make -C /src

FROM alpine:3.20

RUN apk add --no-cache wireguard-tools iptables iproute2 wget curl netcat-openbsd

COPY --from=builder /src/microsocks /usr/local/bin/microsocks
WORKDIR /app
COPY entrypoint.sh healthcheck.sh ./
RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

EXPOSE 1080
HEALTHCHECK --interval=30s --timeout=15s --start-period=20s --retries=3 CMD ["/app/healthcheck.sh"]
CMD ["/app/entrypoint.sh"]
