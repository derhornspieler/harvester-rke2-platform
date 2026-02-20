FROM alpine:3.21
RUN apk add --no-cache curl jq coreutils ca-certificates
COPY sync.sh /usr/local/bin/sync.sh
RUN chmod +x /usr/local/bin/sync.sh
USER nobody
ENTRYPOINT ["sh", "/usr/local/bin/sync.sh"]
