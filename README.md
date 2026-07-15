# mongo-backup

Imagem Docker (~68 MB) que faz o backup periódico de **todas as bases de um cluster MongoDB**, guarda um arquivo por base e envia cada um para o S3.

- **Um diretório por base**: `/backups/<base>/<base>_<timestamp>.tar`
- **Agendamento próprio**: roda a cada `INTERVAL_HOURS`, sem cron no host
- **S3 opcional**: `S3_ENABLED=false` mantém só o backup local
- **Restore** a partir do arquivo local ou direto do S3

## Uso

```bash
cp .env.example .env    # preencha MONGO_URI e, se quiser, o S3

docker run -d --name mongo-backup \
  --restart unless-stopped \
  --env-file .env \
  -v ./backups:/backups \
  lucianoscastro/mongo-backup:latest
```

Ou, com um `docker-compose.yml`:

```yaml
services:
  mongo-backup:
    image: lucianoscastro/mongo-backup:latest
    container_name: mongo-backup
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./backups:/backups
    deploy:
      resources:
        limits:
          memory: 256m
          cpus: "0.5"
```

## Variáveis

| Variável | Padrão | Descrição |
|---|---|---|
| `MONGO_URI` | — | **Obrigatória.** Cluster de origem |
| `BACKUP_DIR` | `/backups` | Onde os arquivos são gravados (monte um volume aqui) |
| `INTERVAL_HOURS` | `6` | Intervalo entre os backups. Aceita fração (`0.5` = 30 min) |
| `MAX_BACKUPS` | `3` | Arquivos mantidos **por base** no disco local |
| `RETRY_MINUTES` | `15` | Espera antes de tentar de novo, se o ciclo falhar |
| `RUN_ON_START` | `true` | Faz um backup ao subir o container |
| `DUMP_TIMEOUT_MINUTES` | `60` | Aborta um dump travado. **Aumente se as bases forem grandes** |
| `EXCLUDE_DBS` | `admin config local` | Bases ignoradas |
| `S3_ENABLED` | `false` | Liga o envio offsite |
| `S3_BUCKET` | — | Bucket de destino |
| `S3_PREFIX` | `mongo` | Prefixo das keys: `<prefix>/<base>/<arquivo>` |
| `S3_REGION` | `us-east-1` | Região |
| `S3_ENDPOINT` | — | Só para S3-compatíveis (MinIO, R2). Vazio = AWS |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | — | Credencial do upload |

## Comandos

Prefixe os comandos abaixo com `docker run --rm --env-file .env -v ./backups:/backups lucianoscastro/mongo-backup:latest`:

```bash
backup             # backup avulso, fora do ciclo
list               # lista os backups locais
restore loja       # restaura do arquivo local mais recente
restore loja --from-s3
restore loja --drop # apaga as coleções antes de restaurar
```

## Segurança: a credencial do backup não deveria conseguir restaurar

A recomendação é dar ao container uma credencial IAM **só com `s3:PutObject`** no prefixo:

```json
{
  "Effect": "Allow",
  "Action": "s3:PutObject",
  "Resource": "arn:aws:s3:::MEU-BUCKET/mongo/*"
}
```

Quem invadir o servidor não consegue **ler nem apagar** os backups — só escrever por cima de keys novas. A contrapartida é que `restore --from-s3` **não funciona com essa credencial**: o restore precisa de outra, com `GetObject`/`ListBucket`, usada só na hora de restaurar.

Com `PutObject` apenas, a retenção remota é responsabilidade da **lifecycle policy do bucket** — o container é incapaz de apagar objetos.

## Como funciona

O `mongodump` roda uma vez por ciclo sem `--db`, o que já descobre e dumpa todas as bases do cluster; cada base sai como um `.tar` próprio. É por isso que a imagem não precisa do `mongosh` (Node.js, ~200 MB, que só serviria para listar as bases) nem do `aws-cli`/`mc` — o upload é `curl --aws-sigv4`.

Limites conhecidos:

- O upload usa PUT simples: **teto de 5 GB por base**. Acima disso o backup local continua, mas o envio falha com erro explícito (seria preciso multipart).
- O dump vai para um diretório temporário antes de virar `.tar`, então o pico de disco é ~2× o tamanho do dump comprimido.
- A retenção local só apaga o arquivo antigo **depois** que o novo foi gravado e validado.
