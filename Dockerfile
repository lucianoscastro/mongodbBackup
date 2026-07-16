# Estágio 1: UI web + agendador (backupd) e executor T-SQL (sqlrun).
# Binários estáticos, sem CGO — a lógica de backup continua toda nos scripts;
# o Go só orquestra, serve a UI e fala TDS com o SQL Server.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY web/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/backupd . \
 && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/sqlrun ./sqlrun

FROM alpine:3.22

# mongodb-tools traz 8 binários (~104 MB); só usamos dump/restore.
# Removê-los no mesmo layer é o que mantém a imagem enxuta.
# curl 8.x assina SigV4 corretamente (o 7.76 não enviava x-amz-content-sha256),
# então o upload S3 não precisa de aws-cli nem mc.
RUN apk add --no-cache mongodb-tools bash curl ca-certificates tzdata \
 && rm -f /usr/bin/mongoexport /usr/bin/mongoimport /usr/bin/mongofiles \
          /usr/bin/mongostat /usr/bin/mongotop /usr/bin/bsondump \
 && mongodump --version | head -1

COPY --from=build /out/backupd /out/sqlrun /usr/local/bin/
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/drivers/*.sh

# Roda sem privilégios; o uid 1000 casa com o dono usual do volume no host.
RUN adduser -D -u 1000 backup && mkdir -p /backups && chown backup /backups
USER backup

VOLUME ["/backups"]
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# "serve" = UI web + agendador. Use "daemon" para rodar sem porta exposta.
CMD ["serve"]
