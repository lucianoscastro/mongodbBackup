FROM alpine:3.22

# mongodb-tools traz 8 binários (~104 MB); só usamos dump/restore.
# Removê-los no mesmo layer é o que mantém a imagem em ~45 MB.
# curl 8.x assina SigV4 corretamente (o 7.76 não enviava x-amz-content-sha256),
# então o upload S3 não precisa de aws-cli nem mc.
RUN apk add --no-cache mongodb-tools bash curl ca-certificates tzdata \
 && rm -f /usr/bin/mongoexport /usr/bin/mongoimport /usr/bin/mongofiles \
          /usr/bin/mongostat /usr/bin/mongotop /usr/bin/bsondump \
 && mongodump --version | head -1

COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Roda sem privilégios; o uid 1000 casa com o dono usual do volume no host.
RUN adduser -D -u 1000 backup && mkdir -p /backups && chown backup /backups
USER backup

VOLUME ["/backups"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["daemon"]
