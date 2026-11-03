# BD de Spotify

Joel Alfonso Pérez Díaz

Este repositorio tiene la base de datos transaccional de Spotify en PostgreSQL. La hice a partir del diagrama ER de la Tarea 2, la cargué con los datos que nos mandó Laura (tablas A, B, C y D) y escribí pruebas para revisar que se cumplen sus reglas de negocio.

## Contenido

```
db/01_schema.sql           crea las 14 tablas
db/02_seed.sql             inserta los datos de Laura
tests.sql                  preguntas de Laura, intentos de romper las reglas y transacciones
docs/diagrama_conceptual.png
docs/diagrama_er.png
docker-compose.yml
.env.example               plantilla del .env
```

## Variables del .env

El `.env` no se sube al repositorio. Se crea a partir de la plantilla:

```
cp .env.example .env
```

| Variable | Para qué sirve | Valor |
|---|---|---|
| POSTGRES_USER | usuario de PostgreSQL | admin |
| POSTGRES_PASSWORD | contraseña de ese usuario | la que tú elijas |
| POSTGRES_DB | base de datos que se crea | spotify |

## Cómo iniciar PostgreSQL

Desde la carpeta del repositorio, en la terminal de Ubuntu:

```
docker compose up -d
```

La primera vez se crean la base de datos `spotify`, las tablas (`db/01_schema.sql`) y los datos (`db/02_seed.sql`). Para revisar que no hubo errores:

```
docker compose logs postgres | grep ERROR
```

Si no sale nada, todo se creó bien.

## Cómo ejecutar las pruebas

```
docker compose exec postgres psql -U admin -d spotify -f /tests.sql
```

`tests.sql` tiene tres partes:

- **a) Preguntas de Laura.** Una consulta por pregunta, con el resultado esperado en un comentario.
- **b) Intentos de romper las reglas.** Al menos un intento por cada tipo de restricción (PRIMARY KEY, FOREIGN KEY, NOT NULL, UNIQUE y CHECK). Todos deben terminar en ERROR.
- **c) Registro y eliminación de un suscriptor.** Cada operación es una transacción, con un caso que funciona y uno que falla a medio camino. Antes y después hay una consulta para comprobar que, cuando falla, todo quedó como estaba.

El archivo se puede ejecutar varias veces y da el mismo resultado, porque la suscriptora que registra en la parte c) la vuelve a borrar al final.

Para detener PostgreSQL sin perder los datos se usa `docker compose down`. Para borrar todo y empezar desde cero, `docker compose down -v`.

## Del diagrama ER al esquema

Las tablas, columnas, tipos, llaves primarias y llaves foráneas son las del diagrama ER de la Tarea 2. Las cardinalidades quedaron así:

- **Mínimo 1 del lado del padre** (por ejemplo, toda playlist tiene dueño): la llave foránea es `NOT NULL`.
- **Relaciones 1 a 1** (suscriptor con perfil y suscriptor con biblioteca): `subscriber_id` es `UNIQUE` en `profiles` y en `libraries`, para que un suscriptor no tenga dos.
- **Mínimo 0** (playlist vacía, canción sin álbum, plan sin suscriptores): no lleva restricción extra.

Agregué algunas restricciones que no se ven en el diagrama, pero que salen de las reglas del negocio:

- `email` en `subscribers` y `name` en `subscriptions` y `countries` son `UNIQUE`.
- En `playlist_song`, `(playlist_id, position)` es `UNIQUE`, para que dos canciones no ocupen el mismo lugar en la playlist. En `song_album` pasa lo mismo con `(album_id, track_number)`.
- `CHECK` para que el precio no sea negativo, la duración sea mayor a cero, la posición y la pista empiecen en 1, el año sea razonable y el rol solo pueda ser `principal` o `feat.`.

Hay tres mínimos de 1 que una restricción sencilla no puede asegurar, porque obligan a que exista una fila en *otra* tabla:

- Todo suscriptor tiene perfil y biblioteca. Lo cuida la transacción de registro de `tests.sql`, que crea las tres cosas o ninguna.
- Toda canción tiene al menos un artista (`song_artist`).
- Todo álbum tiene al menos una canción (`song_album`).

No cambié ninguna tabla ni columna respecto al diagrama ER de la Tarea 2. El diagrama conceptual sí lo actualicé, para que tenga lo que salió al normalizar: la entidad nueva `countries` y las tablas de unión del ER.

## Supuestos

- Los ids de `subscriptions`, `subscribers`, `profiles` y `libraries` no venían en los datos. Los numeré del 1 en adelante en el orden en que aparecen en las tablas de Laura. Cada biblioteca tiene el mismo número que su suscriptor.
- La duración de las canciones la guardo como `TIME` (`00:02:45`), como dice el diagrama ER.
- `photo` puede quedar vacía, porque marta no tiene foto. `photo` y `cover` guardan solo el nombre del archivo.
- Los datos de Laura ya traían dos de los casos que pide la tarea: la playlist vacía (13, Viaje) y la canción sin álbum (108, Calor de Agosto). Agregué los otros dos:
  - la suscripción **Estudiantes** (69 MXN, sin anuncios), que no tiene suscriptores;
  - el artista **A11 Natanael Cano** (MX), que no tiene canciones ni álbumes.
- No uso `ON DELETE CASCADE`. Para borrar un suscriptor hay que borrar primero, uno por uno, lo que depende de él. Las canciones, los álbumes y los artistas del catálogo nunca se borran.
- La pregunta 5 de Laura (la canción más escuchada) no se puede responder: ninguna tabla guarda reproducciones. En `tests.sql` explico qué tabla faltaría.
