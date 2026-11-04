# BD de Spotify

Joel Alfonso Pérez Díaz

Esta es la base de datos de Spotify hecha en PostgreSQL. Guarda los planes, los suscriptores con su perfil y su biblioteca, las playlists, las canciones, los álbumes y los artistas. Ya viene con datos de ejemplo. También tiene un archivo de pruebas para revisar que la base cumple las reglas del negocio.

## Archivos

```
db/01_schema.sql           crea las 14 tablas
db/02_seed.sql             mete los datos iniciales
tests.sql                  las pruebas
docs/diagrama_conceptual.png
docs/diagrama_er.png
docker-compose.yml         configuración del contenedor de PostgreSQL
.env.example               plantilla del .env
```

## El archivo .env

El `.env` guarda el usuario y la contraseña de la base. No se sube a GitHub. Para crearlo, copia la plantilla:

```
cp .env.example .env
```

| Variable | Qué es | Valor |
|---|---|---|
| POSTGRES_USER | usuario de PostgreSQL | admin |
| POSTGRES_PASSWORD | contraseña del usuario | la que quieras |
| POSTGRES_DB | nombre de la base de datos | spotify |

## Cómo iniciar PostgreSQL

Los comandos se corren en la terminal de Ubuntu, dentro de la carpeta del repositorio.

```
docker compose up -d
```

La primera vez, PostgreSQL crea la base `spotify`, después las tablas con `db/01_schema.sql` y al final mete los datos con `db/02_seed.sql`. Espera unos segundos y revisa que no haya errores:

```
docker compose logs postgres | grep ERROR
```

Si no sale nada, todo se creó bien.

## Cómo correr las pruebas

```
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

`tests.sql` tiene tres partes:

- a) Preguntas sobre los datos. Hay una consulta por pregunta y en un comentario está lo que debe salir.
- b) Intentos de romper las reglas. Hay al menos uno por cada tipo de restricción (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK). Todos deben dar ERROR.
- c) Registro y eliminación de un suscriptor. Cada una va en una transacción. Hay un caso que funciona y otro que falla a la mitad. Con una consulta antes y otra después se ve que, cuando falla, los datos quedan igual que al principio.

El archivo se puede correr varias veces y da lo mismo, porque la suscriptora que se registra en la parte c) se borra al final.

Para apagar PostgreSQL sin perder los datos:

```
docker compose down
```

Para borrar todo y empezar de cero:

```
docker compose down -v
```

## Cómo pasé el diagrama ER a las tablas

Las tablas, columnas, tipos de dato, llaves primarias y llaves foráneas son las mismas de `docs/diagrama_er.png`.

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
- La pregunta 5 (la canción más escuchada) no se puede responder porque ninguna tabla guarda las reproducciones. En `tests.sql` explico qué tabla haría falta.
