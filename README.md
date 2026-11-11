# Plataforma de datos de Spotify

Joel Alfonso Pérez Díaz

Empezó como la base de datos de Spotify en PostgreSQL (Tarea 3): planes, suscriptores con su perfil y su biblioteca, playlists, canciones, álbumes y artistas, con datos de ejemplo y un archivo de pruebas.

Desde la Tarea 4 también recibe las reproducciones. La app no escribe en la base de datos: cada vez que alguien reproduce una canción manda un mensaje a Kafka. Un programa guarda esos mensajes en archivos (el crudo) y otro, cada 5 minutos, quita duplicados y skips y actualiza los conteos. Con ellos se responden el top 100 semanal y las 20 canciones más escuchadas de cada suscriptor. Ningún mensaje se guarda en PostgreSQL: solo los conteos.

## Cómo funciona

```
producer ──→ Kafka (tópico streams) ──→ consumer ──→ crudo: un .log por hora
   │                                                    │ cada 5 minutos (cron)
   └─→ sent.log (para verify.py)                        ↓
                                processor: quita duplicados y skips,
                                actualiza los conteos ──→ PostgreSQL
```

| Servicio | Imagen | Qué hace |
|---|---|---|
| `postgres` | `postgres:18` | La base de datos, igual que en la Tarea 3, más las tablas de conteos |
| `kafka` | `apache/kafka:4.1.0` | El broker, en modo KRaft (sin ZooKeeper) |
| `producer` | la de este `Dockerfile` | `app_simulator/producer.py`: simula la app y publica reproducciones |
| `consumer` | la de este `Dockerfile` | `ingestion/consumer.py`: guarda cada mensaje, tal cual, en el crudo |
| `processor` | la de este `Dockerfile` | cron ejecuta `ingestion/processor.py` cada 5 minutos |

Volúmenes: `datos` (PostgreSQL), `crudo` (lo comparten consumer y processor), `logs` (los logs de los tres programas) y `enviados` (el `sent.log` del producer, que el processor solo lee para `verify.py`).

## Archivos

```
app_simulator/producer.py      simula la app de Spotify (en la vida real es de otro equipo)
ingestion/consumer.py          Kafka → crudo
ingestion/processor.py         crudo → conteos en PostgreSQL
ingestion/verify.py            compara sent.log contra los conteos
ingestion/crontab              horario del processor: */5
db/01_schema.sql               las 14 tablas de la Tarea 3
db/02_seed.sql                 los datos iniciales
db/03_play_counts.sql          migración: subscriber_song_play, song_daily_play e ingestion_checkpoint
tests.sql                      las pruebas
docs/diagrama_conceptual.png
docs/diagrama_er.png           diagrama ER de la Tarea 3
docs/diagrama_er_tarea4.md     diagrama ER de las tablas nuevas (Mermaid)
Dockerfile                     la imagen de los tres programas
docker-compose.yml             los cinco servicios
pyproject.toml, uv.lock, .python-version   dependencias de Python (uv)
.env.example                   plantilla del .env
```

## El archivo .env

El `.env` guarda la configuración y la contraseña. No se sube a GitHub. Para crearlo, copia la plantilla:

```
cp .env.example .env
```

| Variable | Qué es | Valor de la plantilla |
|---|---|---|
| POSTGRES_USER | usuario de PostgreSQL | admin |
| POSTGRES_PASSWORD | contraseña del usuario | la que quieras |
| POSTGRES_DB | nombre de la base de datos | spotify |
| KAFKA_TOPIC | tópico de las reproducciones | streams |
| INTERVAL_SECONDS | cada cuántos segundos el producer publica una reproducción | 1 |
| SKIP_RATE | proporción de skips (menos de 30 s), entre 0 y 1 | 0.2 |
| DUPLICATE_RATE | proporción de mensajes que se vuelven a enviar, entre 0 y 1 | 0.1 |
| MAX_DUPLICATE_DELAY_SECONDS | retraso máximo de un duplicado, a lo más 300 | 300 |
| MAX_PLAY_AGE_DAYS | cuántos días hacia atrás puede caer `played_at` | 14 |

El producer revisa estos valores al iniciar. Si uno no tiene sentido (por ejemplo, `SKIP_RATE=2`), lo anota en su log y no arranca.

## Cómo iniciar todo

Los comandos se corren en la terminal de Ubuntu, dentro de la carpeta del repositorio.

```
docker compose up -d --build
docker compose ps
```

`--build` construye la imagen de los programas. Hay que usarlo cada vez que cambia el código, porque la imagen guarda una copia. Los cinco servicios deben decir `Up`. Al principio es normal ver errores de conexión en `docker compose logs producer` y `docker compose logs consumer`, mientras PostgreSQL y Kafka terminan de iniciar: Docker vuelve a iniciar el producer (`restart: on-failure`) y el consumer reintenta solo.

La primera vez, PostgreSQL ejecuta en orden los tres archivos de `db/`. Para comprobarlo:

```
docker compose logs postgres | grep "running /docker-entrypoint"
```

Si el volumen `datos` ya tenía la base de la Tarea 3, PostgreSQL no vuelve a ejecutar `db/`. En ese caso la migración se aplica a mano (se puede ejecutar varias veces sin error):

```
docker compose exec postgres psql -U admin -d spotify -f /docker-entrypoint-initdb.d/03_play_counts.sql
```

Para apagar todo sin perder los datos: `docker compose down`. Para borrar todo, incluidos el crudo, los logs y `sent.log`, y empezar de cero: `docker compose down -v`.

## Cómo revisar cada pieza

| Qué | Comando |
|---|---|
| El producer está publicando | `docker compose logs --tail 5 producer` |
| El consumer está guardando el crudo | `docker compose logs --tail 5 consumer` |
| Los archivos del crudo | `docker compose exec processor ls -l /app/data/raw/streams` |
| Las últimas líneas del crudo | `docker compose exec processor sh -c 'tail -3 /app/data/raw/streams/*.log'` |
| El log del processor | `docker compose exec processor cat /app/logs/processor.log` |
| El horario de cron | `docker compose exec processor crontab -l` |
| Mensajes en Kafka | `docker compose exec kafka /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server kafka:9092 --topic streams` |
| Hasta dónde leyó el consumer | `docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:9092 --describe --group ingestion` |
| Los conteos | `docker compose exec postgres psql -U admin -d spotify -c 'SELECT sum(num_rep) FROM song_daily_play'` |

`docker compose logs processor` no muestra nada y es normal: lo que imprime un programa que ejecuta cron no aparece en ningún lado. Por eso el processor escribe todo en `/app/logs/processor.log`. Cada corrida deja una línea como esta:

```
INFO Corrida: 300 leidos de 2026-11-11T00.log; 214 validas; descartados: 30 duplicados, 56 skips,
0 malformados, 0 con ids inexistentes; filas actualizadas: 32 en subscriber_song_play, 120 en song_daily_play
```

Para no esperar a cron, el processor se puede ejecutar a mano:

```
docker compose exec processor /app/.venv/bin/python /app/ingestion/processor.py
```

## Cómo ejecutar verify.py

`verify.py` se ejecuta en el contenedor del processor, porque ese contenedor ve el volumen `enviados` (donde está `sent.log`, solo lectura) y tiene las variables de PostgreSQL:

```
docker compose exec processor /app/.venv/bin/python /app/ingestion/verify.py
```

Compara, por canción, las reproducciones válidas de `sent.log` con la suma de `song_daily_play` y con la de `subscriber_song_play`. Muestra `OK` si las tres coinciden o la lista de diferencias, y termina con código 0 o 1.

Para obtener la evidencia:

1. `docker compose down -v` y `docker compose up -d --build`, y dejar correr todo al menos 15 minutos.
2. `docker compose stop producer`. Termina en un segundo, porque el producer atiende la señal de Docker: espera a que Kafka confirme lo pendiente y sale con código 0 (no 137).
3. Esperar la siguiente corrida del processor (minuto múltiplo de 5).
4. Ejecutar `verify.py`.

### Salida de verify.py

<!-- VERIFY_OUTPUT -->

## Cómo correr las pruebas

```
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

`tests.sql` tiene tres partes:

- a) Preguntas sobre los datos. Hay una consulta por pregunta y en un comentario está lo que debe salir. Desde la Tarea 4 incluye la pregunta 5 (la canción más escuchada, que ya se puede responder), el top 100 semanal y las 20 canciones más escuchadas de un suscriptor.
- b) Intentos de romper las reglas. Hay al menos uno por cada tipo de restricción (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK). Todos deben dar ERROR.
- c) Registro y eliminación de un suscriptor. Cada una va en una transacción. Hay un caso que funciona y otro que falla a la mitad. La eliminación ahora también borra los conteos del suscriptor en `subscriber_song_play`.

El archivo se puede correr varias veces y da lo mismo, porque la suscriptora que se registra en la parte c) se borra al final.

## Decisiones de la Tarea 4

### Cómo organizo el crudo

Un archivo por hora de llegada a Kafka, en UTC: `/app/data/raw/streams/2026-11-10T22.log`. Cada línea es un mensaje, tal como llegó: el consumer no interpreta ni filtra nada. Los archivos no se borran.

El único cambio que hace el consumer: si un mensaje trae saltos de línea, por ejemplo un JSON con sangría de otro productor, los guarda como espacios. En JSON un salto de línea solo puede ser espacio entre elementos, así que el mensaje significa lo mismo y ocupa una sola línea del crudo.

La hora sale del timestamp que Kafka guarda con cada mensaje, no de `played_at`. Por omisión ese timestamp lo pone el productor con su propio reloj (`CreateTime`). Por eso agregué al servicio `kafka` la variable `KAFKA_LOG_MESSAGE_TIMESTAMP_TYPE: LogAppendTime`, para que lo ponga el broker cuando recibe el mensaje: es justo la llegada a Kafka, y no depende del reloj de cada productor. Es la única variable de `kafka` que no viene en el PDF.

Elegí un archivo por hora de llegada por dos razones:

- La regla de duplicados se mide por la llegada a Kafka. Con la hora en el nombre del archivo, el processor sabe cuándo llegó cada mensaje sin que el consumer tenga que modificarlo.
- Los archivos no crecen sin fin, como pasaría con uno solo.

El consumer marca un mensaje como leído (`store_offsets`) después de escribirlo, no antes. Si muere entre las dos cosas, al volver lo escribe otra vez: un mensaje puede quedar dos veces en el crudo, pero nunca se pierde. Ese duplicado lo quita el processor como cualquier otro. Si muere a mitad de una escritura, al arrancar cierra con un salto de línea el pedazo incompleto, para que el mensaje que Kafka vuelve a entregar quede en su propia línea.

### Cómo quito los duplicados

Dos mensajes con el mismo `event_id` son la misma reproducción, y solo cuenta el primero. Un duplicado llega a Kafka a lo más 5 minutos después que el original, así que el original de un mensaje que llegó en la hora H está en el archivo de H o en el de H-1.

En cada corrida, el processor relee los `event_id` que ya procesó en esas dos horas, y después revisa los mensajes nuevos en orden de llegada. Si un `event_id` ya apareció, en esta corrida o en una anterior, el mensaje se descarta como duplicado. Así reconoce duplicados entre corridas sin guardar los `event_id` en ningún otro lado.

El orden de cada corrida:

1. Lee las líneas nuevas de cada archivo, desde la posición que dice `ingestion_checkpoint`. Si la última línea no está completa (el consumer la está escribiendo), la deja para la siguiente corrida.
2. Descarta las líneas que no respetan el formato: JSON inválido, un campo faltante o de otro tipo, o un `played_at` sin zona horaria.
3. Quita los duplicados.
4. Descarta los skips (`ms_played < 30000`).
5. Descarta los mensajes con un `subscriber_id` o `song_id` que no existe en la base. Así un productor con ids malos no rompe todo el lote por la llave foránea.
6. Convierte `played_at` a UTC para sacar el día: `2026-11-03T23:30:00-06:00` cuenta el 4 de noviembre.
7. Suma los conteos con `INSERT ... ON CONFLICT DO UPDATE SET num_rep = num_rep + ...`.

El log anota cuántos mensajes leyó y cuántos descartó por cada razón.

### El checkpoint del processor

La migración `03_play_counts.sql` también crea `ingestion_checkpoint`, con el byte hasta el que ya se procesó cada archivo del crudo. No guarda mensajes, solo nombres de archivo y posiciones, así que respeta la regla de la tarea.

Los conteos y el avance del checkpoint se guardan en la misma transacción. Si el processor falla a la mitad, PostgreSQL hace ROLLBACK de todo, y la siguiente corrida vuelve a procesar las mismas líneas: nada se cuenta dos veces y nada se pierde. Con el checkpoint en un archivo, un fallo justo entre el COMMIT y la escritura del archivo haría contar dos veces un lote.

La corrida toma un candado de PostgreSQL (`pg_try_advisory_xact_lock`). Si una corrida tarda más de 5 minutos, la siguiente no se encima: lo anota y se salta.

### Otras decisiones

- `play_date` es de tipo `date`. `num_rep` es `integer` con `CHECK (num_rep > 0)`: una fila solo existe si hubo al menos una reproducción válida. Las llaves foráneas van a `subscribers` y `songs`, sin `ON DELETE CASCADE`.
- `song_daily_play` tiene un índice por `play_date`, porque el top semanal filtra por fecha y su llave primaria empieza por `song_id`.
- El producer lee de la base las canciones con su duración, y las reproducciones válidas duran entre 30 s y lo que dura la canción. `played_at` lleva la zona horaria del teléfono (entre -07:00 y +01:00), para probar la conversión a UTC.
- Un original solo entra a `sent.log` cuando Kafka confirma que lo guardó. Así `verify.py` no espera mensajes que nunca llegaron. Su duplicado se programa hasta ese momento: si Kafka no guarda el original, tampoco se manda el duplicado.
- El `Dockerfile` cambia los repositorios de Debian a `https://` antes de instalar cron. En mi red, algo altera el HTTP sin cifrar y `apt-get` fallaba con `Bad header line`.
- `.dockerignore` deja fuera de la imagen `.venv/`, `.git/` y `.env`, para que la contraseña no quede guardada en la imagen.
- `.gitattributes` obliga a guardar los archivos con fin de línea LF. Con CRLF (Windows), cron no ejecutaría el `crontab`.

### ¿Cambia el top semanal cuando se elimina a un suscriptor?

No. El top sale de `song_daily_play`, que cuenta por canción y día sin guardar quién escuchó. Las reproducciones de ese suscriptor ocurrieron y siguen contando en el top y en la canción más escuchada. Solo desaparece su lista personal, en `subscriber_song_play`. Después de eliminar a un suscriptor con conteos, las sumas de las dos tablas dejan de ser iguales, así que `verify.py` se ejecuta antes de borrar a nadie.

## Cómo pasé el diagrama ER a las tablas

Las tablas, columnas, tipos de dato, llaves primarias y llaves foráneas son las mismas de `docs/diagrama_er.png`. Las tablas de la Tarea 4 están en `docs/diagrama_er_tarea4.md`.

Las cardinalidades del diagrama las puse así en el SQL:

- Cuando el mínimo es 1 del lado del padre, la llave foránea lleva `NOT NULL`. Por ejemplo, toda playlist tiene dueño.
- En las relaciones 1 a 1 (suscriptor con perfil y suscriptor con biblioteca), `subscriber_id` es `UNIQUE` en `profiles` y en `libraries`. Así un suscriptor no puede tener dos perfiles ni dos bibliotecas.
- Cuando el mínimo es 0 no hace falta nada más. Por ejemplo, una playlist puede estar vacía.

También agregué estas restricciones por las reglas del negocio:

- `email` en `subscribers` no se puede repetir. Tampoco `name` en `subscriptions` ni en `countries`.
- En `playlist_song`, `(playlist_id, position)` no se puede repetir, para que dos canciones no estén en el mismo lugar de la playlist. En `song_album` pasa lo mismo con `(album_id, track_number)`.
- Con `CHECK` reviso que el precio no sea negativo, que la duración sea mayor a cero, que la posición y la pista empiecen en 1, que el año esté entre 1900 y 2100, y que el rol solo sea `principal` o `feat.`.

Hay tres reglas que no se pueden poner con una restricción sencilla, porque piden que exista una fila en otra tabla:

- Todo suscriptor tiene perfil y biblioteca. Esto lo cuida la transacción de registro de `tests.sql`, que crea las tres cosas juntas o no crea ninguna.
- Toda canción tiene al menos un artista en `song_artist`.
- Todo álbum tiene al menos una canción en `song_album`.

## Supuestos

- Los datos no traían ids para `subscriptions`, `subscribers`, `profiles` y `libraries`. Los numeré del 1 en adelante, en el orden en que salen en los datos originales. Cada biblioteca tiene el mismo número que su suscriptor.
- La duración de las canciones se guarda como `TIME`, por ejemplo `00:02:45`.
- `photo` puede quedar vacía porque marta no tiene foto. `photo` y `cover` guardan solo el nombre del archivo.
- La tarea pedía cuatro casos. Dos ya estaban en los datos originales: la playlist vacía (13, Viaje) y la canción sin álbum (108, Calor de Agosto). Los otros dos los agregué yo:
  - el plan Estudiantes (69 MXN, sin anuncios), que no tiene suscriptores;
  - el artista A11 Natanael Cano (MX), que no tiene canciones ni álbumes.
- No uso `ON DELETE CASCADE`. Para borrar un suscriptor primero borro, una por una, las cosas que dependen de él. Las canciones, los álbumes y los artistas no se borran.
- Tarea 4: hay una sola partición, así que con `LogAppendTime` los timestamps de Kafka avanzan en el orden de llegada, sin importar quién publique.
- Tarea 4: la tabla `ingestion_checkpoint` va en `03_play_counts.sql`, junto con las tablas de conteos, porque la tarea pide que las tablas nuevas vayan en ese archivo.
