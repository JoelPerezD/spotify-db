# Spotify: plataforma de datos de reproducciones

Joel Alfonso Pérez Díaz

Plataforma de datos para Spotify, desarrollada como caso de estudio con una app simulada. Recibe en tiempo real, a través de Kafka, los eventos que genera la app de Spotify cada vez que alguien reproduce una canción. Los guarda sin modificar como historial en archivos y, cada 5 minutos, los limpia y mantiene los conteos que la app necesita mostrar: el **top 100 semanal** de canciones y las **20 canciones más escuchadas de cada suscriptor**. La base de datos de Spotify en PostgreSQL (catálogo, suscriptores, playlists y bibliotecas) guarda solo esos conteos, no cada evento, para no crecer sin fin ni competir con las consultas de la app. Los eventos completos quedan en archivos para análisis.

**Stack:** Python 3.13 · Apache Kafka 4.1 (KRaft) · PostgreSQL 18 · Docker Compose · cron · uv · psycopg 3 · confluent-kafka

**Resultado verificado:** después de 15 minutos de tráfico simulado con skips y duplicados, los conteos de la base coinciden evento por evento con lo enviado (774 de 774 reproducciones válidas; ver [Validación](#validación)).

## Arquitectura

```
producer ──→ Kafka (tópico streams) ──→ consumer ──→ crudo: un .log por hora
   │                                                    │ cada 5 minutos (cron)
   └─→ sent.log (referencia para verify.py)             ↓
                                processor: quita duplicados y skips,
                                actualiza los conteos ──→ PostgreSQL
```

| Servicio | Imagen | Responsabilidad |
|---|---|---|
| `postgres` | `postgres:18` | Esquema relacional del catálogo y los usuarios, más las tablas de conteos |
| `kafka` | `apache/kafka:4.1.0` | Broker en modo KRaft (sin ZooKeeper) |
| `producer` | propia (`Dockerfile`) | `app_simulator/producer.py`: simula la app de Spotify y publica reproducciones |
| `consumer` | propia | `ingestion/consumer.py`: guarda cada mensaje en el crudo, sin interpretarlo |
| `processor` | propia | cron ejecuta `ingestion/processor.py` cada 5 minutos |

Los tres programas usan **una sola imagen**; cada servicio elige qué ejecutar con su `command:`. Volúmenes: `datos` (PostgreSQL), `crudo` (compartido entre consumer y processor), `logs` (logs de los tres programas) y `enviados` (el `sent.log` del producer, que el processor solo lee).

`app_simulator/` va separado de `ingestion/` a propósito: la app y su productor serían de otro equipo; `ingestion/` es el sistema propio.

## Decisiones de ingeniería

### Crudo: un archivo por hora de llegada a Kafka

El consumer guarda cada mensaje, tal como llegó, en `/app/data/raw/streams/AAAA-MM-DDTHH.log`, según la hora (UTC) en que el mensaje llegó al broker. Los archivos no se borran.

- **Hora de llegada, no del productor.** Kafka está configurado con `KAFKA_LOG_MESSAGE_TIMESTAMP_TYPE: LogAppendTime`, así que el timestamp de cada mensaje lo pone el broker al recibirlo. No depende del reloj de cada productor, y con una sola partición avanza en el orden de llegada. La regla de duplicados se mide justo así.
- **Sin modificar el contenido.** La hora queda en el nombre del archivo, así que no hace falta agregarla al mensaje. Lo único que cambia el consumer es que guarda como espacio un salto de línea dentro de un mensaje (por ejemplo, un JSON con sangría). En JSON eso no cambia el significado y garantiza un mensaje por línea.
- **Archivos acotados**, en lugar de uno solo que crece sin fin.

### Ningún mensaje se pierde: entrega "al menos una vez"

El consumer marca un mensaje como leído (`enable.auto.offset.store: False` + `store_offsets`) **después** de escribirlo, no antes. Si se cae entre las dos cosas, al volver lo escribe otra vez: puede quedar repetido, pero nunca se pierde. Si se cae a mitad de una escritura, al arrancar cierra la línea incompleta, para que el mensaje que Kafka vuelve a entregar quede en su propia línea.

### Deduplicación entre corridas

Dos mensajes con el mismo `event_id` son la misma reproducción, y solo cuenta el primero. Un duplicado llega a Kafka a lo más 5 minutos después que el original, así que el original de un mensaje de la hora H está en el archivo de H o en el de H-1. En cada corrida, el processor relee los `event_id` ya procesados de esas dos horas y después revisa los mensajes nuevos en orden de llegada. Así reconoce duplicados aunque caigan en corridas distintas, sin un almacén aparte de identificadores.

Cada corrida:

1. Lee las líneas nuevas de cada archivo desde su checkpoint. Una línea a medio escribir se deja para la siguiente corrida.
2. Descarta las líneas que no respetan el formato: JSON inválido, campos faltantes o de otro tipo, `played_at` sin zona horaria.
3. Quita los duplicados.
4. Descarta los skips (`ms_played < 30000`).
5. Descarta los ids que no existen en la base, para que un productor externo con datos malos no rompa el lote por una llave foránea.
6. Convierte `played_at` a UTC para obtener el día: `2026-11-03T23:30:00-06:00` cuenta el 4 de noviembre.
7. Suma los conteos con `INSERT ... ON CONFLICT DO UPDATE SET num_rep = num_rep + ...`.

### Cada reproducción se cuenta exactamente una vez

La tabla `ingestion_checkpoint` guarda hasta qué byte de cada archivo ya se procesó (nombres y posiciones, nunca mensajes). Los conteos y el avance del checkpoint se guardan **en la misma transacción**. Si el processor falla a la mitad, PostgreSQL hace ROLLBACK de todo y la siguiente corrida reintenta las mismas líneas: nada se cuenta dos veces y nada se pierde. Con el checkpoint en un archivo aparte, un fallo justo después del COMMIT haría contar dos veces un lote.

Además, cada corrida toma un candado de PostgreSQL (`pg_try_advisory_xact_lock`). Si una tarda más de 5 minutos, la siguiente no se encima: lo anota en el log y se salta.

### Otras decisiones

- **Días y semanas en UTC.** El top semanal es la última semana completa, de lunes a domingo; la semana en curso no cuenta.
- **El producer simula casos difíciles:** skips, duplicados con un retraso aleatorio de hasta 5 minutos, reproducciones "sin conexión" con `played_at` de hasta 14 días atrás y zonas horarias de teléfono entre -07:00 y +01:00. Lee de la base qué suscriptores y canciones existen, y la duración de cada canción.
- **`sent.log` solo con lo confirmado.** Un original entra a `sent.log` cuando Kafka confirma que lo guardó, y solo entonces se programa su duplicado. Así la verificación nunca espera mensajes que no llegaron.
- **Apagado limpio.** El producer y el consumer atienden la señal de `docker compose stop`: terminan de enviar o confirmar lo pendiente y salen con código 0.
- **Imagen reproducible.** `uv sync --locked` instala exactamente lo de `uv.lock`. Las dependencias se copian antes que el código, para aprovechar la caché de capas. `.dockerignore` deja fuera `.venv/`, `.git/` y `.env`, para que la contraseña no quede en la imagen. Los repositorios de Debian se usan por `https://`, porque algunas redes alteran el HTTP sin cifrar y `apt-get` falla.
- **Fin de línea LF** forzado con `.gitattributes`: con CRLF, cron no ejecutaría el `crontab`.

## Modelo de datos

El esquema relacional de Spotify (`db/01_schema.sql`, 14 tablas) cubre planes, suscriptores con perfil y biblioteca, playlists, canciones, álbumes y artistas, a partir de un diagrama ER normalizado (`docs/diagrama_er.png`). Las cardinalidades se implementan con `NOT NULL` (mínimo 1), `UNIQUE` (relaciones 1 a 1) y `CHECK` para las reglas del negocio. No usa `ON DELETE CASCADE`: borrar un suscriptor exige eliminar antes, de forma explícita, todo lo que depende de él.

La migración `db/03_play_counts.sql` agrega la capa de conteos (diagrama en [`docs/diagrama_er_conteos.md`](docs/diagrama_er_conteos.md)):

| Tabla | Llave primaria | Responde |
|---|---|---|
| `subscriber_song_play` | `(subscriber_id, song_id)` | Las 20 canciones más escuchadas de un suscriptor, desde siempre |
| `song_daily_play` | `(song_id, play_date)` | El top 100 semanal; tiene un índice por `play_date`, porque el top filtra por fecha |
| `ingestion_checkpoint` | `file_name` | Hasta dónde leyó el processor cada archivo del crudo |

`num_rep` es `integer` con `CHECK (num_rep > 0)`: una fila solo existe si hubo al menos una reproducción válida. Eliminar a un suscriptor borra su lista personal, pero **no cambia el top semanal**: `song_daily_play` cuenta por canción y día, sin guardar quién escuchó.

## Cómo ejecutarlo

Requisitos: Docker con Docker Compose, en Linux o WSL.

```
cp .env.example .env            # y cambia la contraseña
docker compose up -d --build
docker compose ps               # los cinco servicios deben decir Up
```

`--build` construye la imagen de los programas, y hace falta cada vez que cambia el código. Los primeros segundos es normal ver errores de conexión en el producer y el consumer mientras PostgreSQL y Kafka terminan de iniciar: Docker reinicia el producer (`restart: on-failure`) y el consumer reintenta solo.

Con el volumen vacío, PostgreSQL ejecuta `db/01_schema.sql`, `02_seed.sql` y `03_play_counts.sql`, en orden. En una base que ya tenía datos, la migración se aplica a mano (es idempotente):

```
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/03_play_counts.sql
```

Para apagar sin perder datos: `docker compose down`. Para borrar todo (base, crudo, logs y `sent.log`): `docker compose down -v`.

### Configuración (`.env`)

El `.env` no se sube al repositorio.

| Variable | Qué controla | Valor de la plantilla |
|---|---|---|
| POSTGRES_USER | usuario de PostgreSQL | admin |
| POSTGRES_PASSWORD | contraseña | la que quieras |
| POSTGRES_DB | base de datos | spotify |
| KAFKA_TOPIC | tópico de las reproducciones | streams |
| INTERVAL_SECONDS | cada cuántos segundos el producer publica | 1 |
| SKIP_RATE | proporción de skips, entre 0 y 1 | 0.2 |
| DUPLICATE_RATE | proporción de mensajes duplicados, entre 0 y 1 | 0.1 |
| MAX_DUPLICATE_DELAY_SECONDS | retraso máximo de un duplicado (hasta 300) | 300 |
| MAX_PLAY_AGE_DAYS | cuántos días hacia atrás puede caer `played_at` | 14 |

El producer valida estos valores al iniciar. Si uno no tiene sentido, lo anota en su log y no arranca.

### El formato del mensaje

```json
{"event_id": "8c1e2f4a-6b3d-4e2a-9f1c-2d7b8a5e0c31", "subscriber_id": 4, "song_id": 104,
 "played_at": "2026-11-03T18:42:10-07:00", "ms_played": 187000}
```

El processor funciona con cualquier productor que respete este formato, no solo con el simulador.

## Operación y monitoreo

Cada programa escribe su log con `logging` en el volumen `logs`: `producer.log`, `consumer.log`, `processor.log` y `verify.log`.

| Qué | Comando |
|---|---|
| El producer está publicando | `docker compose logs --tail 5 producer` |
| El consumer está guardando el crudo | `docker compose logs --tail 5 consumer` |
| Los archivos del crudo | `docker compose exec processor ls -l /app/data/raw/streams` |
| El log del processor | `docker compose exec processor cat /app/logs/processor.log` |
| El horario de cron | `docker compose exec processor crontab -l` |
| Mensajes en Kafka | `docker compose exec kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic streams` |
| Retraso del consumer (LAG) | `docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:9092 --describe --group ingestion` |
| Los conteos | `docker compose exec postgres psql -U admin -d spotify -c 'SELECT sum(num_rep) FROM song_daily_play'` |

Lo que imprime un programa que ejecuta cron no aparece en `docker compose logs`, así que el processor escribe todo en `processor.log`. Cada corrida deja una línea con lo que leyó, lo que contó y lo que descartó, y por qué:

```
2026-11-11T00:30:02+0000 INFO Corrida: 334 leidos de 2026-11-11T00.log; 244 validas; descartados: 34 duplicados, 56 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 32 en subscriber_song_play, 102 en song_daily_play
```

Las líneas malformadas se copian como `WARNING`, y los errores inesperados como `ERROR`, con el traceback completo. Para no esperar a cron, el processor se puede ejecutar a mano:

```
docker compose exec processor /app/.venv/bin/python /app/ingestion/processor.py
```

## Validación

`ingestion/verify.py` compara, por canción, las reproducciones válidas de `sent.log` con la suma de `song_daily_play` y con la de `subscriber_song_play`. Muestra `OK` si las tres coinciden o la lista de diferencias, y termina con código 0 o 1. Se ejecuta en el contenedor del processor, que monta `sent.log` en solo lectura:

```
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
```

Procedimiento: `docker compose down -v` y `docker compose up -d --build`, al menos 15 minutos de tráfico, `docker compose stop producer`, esperar la siguiente corrida del processor (minuto múltiplo de 5) y ejecutar `verify.py`.

Resultado, desde un clon limpio del repositorio:

```
$ docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
sent.log: 966 mensajes originales, 774 reproducciones validas
song_daily_play: 774 | subscriber_song_play: 774
song_id    sent.log  song_daily_play  subscriber_song_play
101              93               93                    93
102             103              103                   103
103              96               96                    96
104              72               72                    72
105              92               92                    92
106             108              108                   108
107             101              101                   101
108             109              109                   109
OK
```

Las cuentas cuadran de punta a punta:

- Kafka recibió 1043 mensajes: 966 originales más 77 duplicados.
- El consumer guardó los 1043 (LAG 0).
- El processor descartó 77 duplicados y 192 skips en cinco corridas, y contó 774 reproducciones válidas, las mismas de `sent.log`.

```
2026-11-11T00:20:02+0000 INFO Corrida: 58 leidos de 2026-11-11T00.log; 52 validas; descartados: 0 duplicados, 6 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 22 en subscriber_song_play, 46 en song_daily_play
2026-11-11T00:25:02+0000 INFO Corrida: 312 leidos de 2026-11-11T00.log; 234 validas; descartados: 12 duplicados, 66 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 32 en subscriber_song_play, 99 en song_daily_play
2026-11-11T00:30:02+0000 INFO Corrida: 334 leidos de 2026-11-11T00.log; 244 validas; descartados: 34 duplicados, 56 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 32 en subscriber_song_play, 102 en song_daily_play
2026-11-11T00:35:01+0000 INFO Corrida: 329 leidos de 2026-11-11T00.log; 236 validas; descartados: 30 duplicados, 63 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 32 en subscriber_song_play, 101 en song_daily_play
2026-11-11T00:40:02+0000 INFO Corrida: 10 leidos de 2026-11-11T00.log; 8 validas; descartados: 1 duplicados, 1 skips, 0 malformados, 0 con ids inexistentes; filas actualizadas: 7 en subscriber_song_play, 7 en song_daily_play
```

## Consultas y pruebas de integridad

```
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

`tests.sql` tiene tres partes:

- **Consultas del negocio:** la canción más escuchada, el top 100 semanal, las 20 más escuchadas de un suscriptor y otras preguntas sobre el catálogo y las bibliotecas, cada una con su resultado esperado.
- **Restricciones:** al menos un intento de romper cada tipo (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK). Todos deben terminar en ERROR.
- **Transacciones:** el registro y la eliminación de un suscriptor, cada uno en un caso que funciona y otro que falla a la mitad, para mostrar que un fallo deja los datos como estaban. La eliminación comprueba que el top semanal no cambia.

El archivo se puede ejecutar varias veces: lo que agrega, lo borra al final.

## Estructura del repositorio

```
app_simulator/producer.py   simula la app: publica reproducciones en Kafka
ingestion/consumer.py       Kafka → crudo
ingestion/processor.py      crudo → conteos en PostgreSQL
ingestion/verify.py         sent.log contra los conteos
ingestion/crontab           horario del processor (*/5)
db/01_schema.sql            esquema relacional (14 tablas)
db/02_seed.sql              datos iniciales
db/03_play_counts.sql       migración: tablas de conteos y checkpoint
tests.sql                   consultas y pruebas de integridad
docs/                       diagramas conceptual y ER
Dockerfile                  imagen de los tres programas
docker-compose.yml          los cinco servicios
pyproject.toml, uv.lock, .python-version   dependencias (uv)
.env.example                plantilla de configuración
```

## Limitaciones y siguientes pasos

- Un solo broker y una sola partición: suficiente para el volumen simulado, pero sin réplicas ni paralelismo. Escalar implicaría más particiones y deduplicar por partición.
- Kafka usa `PLAINTEXT`. En producción harían falta cifrado (SSL) y autenticación (SASL).
- El crudo no se borra. Una política de retención, o moverlo a almacenamiento de objetos, evitaría que crezca sin límite.
- cron no reintenta ni alerta. Un orquestador, como Airflow, daría reintentos, historial y alertas.
