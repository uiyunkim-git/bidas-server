FROM nginx:alpine

# Config is generated at container start from $BIDAS_BUCKETS so that bucket
# routes stay in sync with the compose environment.
COPY 40-bidas-config.sh /docker-entrypoint.d/40-bidas-config.sh
RUN chmod +x /docker-entrypoint.d/40-bidas-config.sh

EXPOSE 80 9000
