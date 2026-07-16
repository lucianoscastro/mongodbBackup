# Estágio 1: UI web + agendador (backupd). Binário estático, sem CGO —
# a lógica de backup continua toda nos scripts; o Go só orquestra e serve a UI.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY web/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/backupd .

FROM alpine:3.22

# mongodb-tools traz 8 binários (~104 MB); só usamos dump/restore.
# Removê-los no mesmo layer é o que mantém a imagem enxuta.
# curl 8.x assina SigV4 corretamente (o 7.76 não enviava x-amz-content-sha256),
# então o upload S3 não precisa de aws-cli nem mc.
RUN apk add --no-cache mongodb-tools bash curl ca-certificates tzdata \
 && rm -f /usr/bin/mongoexport /usr/bin/mongoimport /usr/bin/mongofiles \
          /usr/bin/mongostat /usr/bin/mongotop /usr/bin/bsondump \
 && mongodump --version | head -1

# sqlcmd da Microsoft (go-sqlcmd): binário Go estático — é o único sqlcmd que
# roda em Alpine, o mssql-tools oficial exige glibc.
ARG SQLCMD_VERSION=v1.10.0
RUN apk add --no-cache --virtual .fetch bzip2 \
 && case "$(apk --print-arch)" in \
        x86_64) arch=amd64 ;; \
        aarch64) arch=arm64 ;; \
        *) echo "arquitetura sem build do sqlcmd: $(apk --print-arch)" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://github.com/microsoft/go-sqlcmd/releases/download/${SQLCMD_VERSION}/sqlcmd-linux-${arch}.tar.bz2" \
    | tar -xjf - -C /usr/local/bin sqlcmd \
 && apk del .fetch \
 && sqlcmd --version

COPY --from=build /out/backupd /usr/local/bin/backupd
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
