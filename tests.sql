-- Pruebas de la BD de Spotify
-- Se ejecuta con:
--   docker compose exec postgres psql -U admin -d spotify -f /tests.sql
-- Los resultados esperados estan en los comentarios. Los intentos de romper
-- las reglas deben terminar en ERROR; psql sigue con la siguiente instruccion.
-- El archivo se puede ejecutar varias veces: lo que agrega en la parte c)
-- lo vuelve a borrar al final.


\echo '=============================================='
\echo 'a) Preguntas de Laura'
\echo '=============================================='

\echo '1. Canciones de la playlist 10, en orden, con sus artistas'
-- El artista principal va primero y despues los feat.
-- Esperado:
--  1 | Ella Baila Sola         | Eslabon Armado, Peso Pluma
--  2 | TQG                     | Karol G, Shakira
--  3 | Bzrp Music Sessions #53 | Bizarrap, Shakira
SELECT ps.position AS posicion,
       s.title     AS cancion,
       string_agg(a.name, ', ' ORDER BY sa.role = 'principal' DESC, a.name) AS artistas
FROM playlist_song ps
JOIN songs s        ON s.song_id = ps.song_id
JOIN song_artist sa ON sa.song_id = s.song_id
JOIN artists a      ON a.artist_id = sa.artist_id
WHERE ps.playlist_id = 10
GROUP BY ps.position, s.title
ORDER BY ps.position;

\echo '2. Suscriptores por suscripcion, incluidas las que no tienen ninguno'
-- Uso LEFT JOIN para que aparezcan los planes sin suscriptores.
-- COUNT(su.subscriber_id) cuenta 0 cuando no hay suscriptores.
-- Esperado: Familiar 2, Gratuita 1, Premium 1, Estudiantes 0
SELECT sc.name                  AS suscripcion,
       COUNT(su.subscriber_id)  AS suscriptores
FROM subscriptions sc
LEFT JOIN subscribers su ON su.subscription_id = sc.subscription_id
GROUP BY sc.subscription_id, sc.name
ORDER BY suscriptores DESC, sc.name;

\echo '3. Canciones que no estan en ningun album'
-- Esperado: 108 | Calor de Agosto
SELECT s.song_id, s.title AS cancion
FROM songs s
LEFT JOIN song_album sal ON sal.song_id = s.song_id
WHERE sal.song_id IS NULL
ORDER BY s.song_id;

\echo '4. Lo que tiene guardado cada suscriptor en su biblioteca'
-- Junto canciones y albumes con UNION ALL. Con el LEFT JOIN tambien sale
-- marta, que no tiene nada guardado (tipo y titulo quedan vacios).
-- Esperado:
--  ana@mail.com   | cancion | Flowers
--  ana@mail.com   | cancion | TQG
--  ana@mail.com   | album   | Un Verano Sin Ti
--  luis@mail.com  | cancion | Bzrp Music Sessions #53
--  luis@mail.com  | album   | Las Mujeres Ya No Lloran
--  luis@mail.com  | album   | SOS
--  marta@mail.com |         |
--  diego@mail.com | cancion | Calor de Agosto
--  diego@mail.com | cancion | Ella Baila Sola
SELECT su.email,
       g.tipo,
       g.titulo
FROM subscribers su
JOIN libraries l ON l.subscriber_id = su.subscriber_id
LEFT JOIN (
    SELECT ls.library_id, 'cancion' AS tipo, s.title AS titulo
    FROM library_song ls
    JOIN songs s ON s.song_id = ls.song_id
    UNION ALL
    SELECT la.library_id, 'album' AS tipo, al.title AS titulo
    FROM library_album la
    JOIN albums al ON al.album_id = la.album_id
) g ON g.library_id = l.library_id
ORDER BY su.subscriber_id, g.tipo = 'album', g.titulo;

\echo '5. La cancion mas escuchada'
-- Esta pregunta no se puede responder con mi base.
-- Ninguna tabla de Laura guarda reproducciones: solo sabemos que canciones
-- estan en playlists y en bibliotecas, y eso no dice cuantas veces se
-- escucharon. Guardar una cancion no es lo mismo que escucharla.
-- Para responderla faltaria una tabla de reproducciones, por ejemplo:
--   plays (play_id PK, subscriber_id FK, song_id FK, played_at timestamp)
-- con una fila cada vez que alguien escucha una cancion. Con ella la
-- consulta seria:
--   SELECT s.title, COUNT(*) AS reproducciones
--   FROM plays p JOIN songs s ON s.song_id = p.song_id
--   GROUP BY s.song_id, s.title
--   ORDER BY reproducciones DESC
--   LIMIT 1;


\echo '=============================================='
\echo 'b) Intentos de romper las reglas (todos deben dar ERROR)'
\echo '=============================================='

-- PRIMARY KEY
\echo 'PK: repetir el song_id 101'
-- Regla: cada cancion se identifica con un id que no se repite.
-- Esperado: ERROR duplicate key value violates unique constraint "songs_pkey"
INSERT INTO songs (song_id, title, duration, genre)
VALUES (101, 'Otra cancion', '00:03:00', 'Pop');

\echo 'PK: agregar dos veces la misma cancion a la playlist 10'
-- Regla (supuesto de la Tarea 2): una cancion no se repite dentro de una playlist.
-- Esperado: ERROR duplicate key value violates unique constraint "playlist_song_pkey"
INSERT INTO playlist_song (playlist_id, song_id, added_at, position)
VALUES (10, 101, '2026-11-01', 4);

-- FOREIGN KEY
\echo 'FK: agregar a una playlist una cancion que no existe'
-- Regla: solo se pueden agregar canciones del catalogo.
-- Esperado: ERROR insert or update on table "playlist_song" violates foreign key constraint
INSERT INTO playlist_song (playlist_id, song_id, added_at, position)
VALUES (10, 999, '2026-11-01', 4);

\echo 'FK: cambiar a un suscriptor a un plan que no existe'
-- Regla: todo suscriptor tiene uno de los planes que ofrece Spotify.
-- Esperado: ERROR insert or update on table "subscribers" violates foreign key constraint
UPDATE subscribers SET subscription_id = 99 WHERE subscriber_id = 1;

\echo 'FK: borrar a Bad Bunny, que tiene canciones y un album'
-- Regla: no se puede borrar un artista mientras tenga canciones o albumes,
-- porque se quedarian sin artista.
-- Esperado: ERROR update or delete on table "artists" violates foreign key constraint
DELETE FROM artists WHERE artist_id = 'A8';

-- NOT NULL
\echo 'NOT NULL: crear una playlist sin dueno'
-- Regla: toda playlist la crea un suscriptor (minimo 1 en la relacion create).
-- Esperado: ERROR null value in column "subscriber_id" ... violates not-null constraint
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (20, 'Sin dueno', '2026-11-01', NULL);

\echo 'NOT NULL: registrar un suscriptor sin plan'
-- Regla: todo suscriptor tiene un plan, aunque sea el gratuito.
-- Esperado: ERROR null value in column "subscription_id" ... violates not-null constraint
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (20, 'nuevo@mail.com', '2026-11-01', NULL);

-- UNIQUE
\echo 'UNIQUE: registrar otro suscriptor con el email de ana'
-- Regla: el email identifica al suscriptor, no puede haber dos iguales.
-- Esperado: ERROR duplicate key value violates unique constraint "subscribers_email_key"
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (20, 'ana@mail.com', '2026-11-01', 2);

\echo 'UNIQUE: darle un segundo perfil a ana'
-- Regla: cada suscriptor tiene un solo perfil (maximo 1 en la relacion 1 a 1).
-- Esperado: ERROR duplicate key value violates unique constraint "profiles_subscriber_id_key"
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (20, 1, 'ana2', NULL, 'MX');

\echo 'UNIQUE: darle una segunda biblioteca a luis'
-- Regla: cada suscriptor tiene una sola biblioteca.
-- Esperado: ERROR duplicate key value violates unique constraint "libraries_subscriber_id_key"
INSERT INTO libraries (library_id, subscriber_id) VALUES (20, 2);

\echo 'UNIQUE: poner dos canciones en la posicion 1 de la playlist 10'
-- Regla: cada lugar de la playlist lo ocupa una sola cancion.
-- Esperado: ERROR duplicate key value violates unique constraint "playlist_song_playlist_id_position_key"
INSERT INTO playlist_song (playlist_id, song_id, added_at, position)
VALUES (10, 104, '2026-11-01', 1);

-- CHECK
\echo 'CHECK: plan con precio negativo'
-- Regla: un plan cuesta 0 (gratuito) o mas, nunca menos.
-- Esperado: ERROR new row for relation "subscriptions" violates check constraint "subscriptions_price_check"
UPDATE subscriptions SET price = -10 WHERE subscription_id = 1;

\echo 'CHECK: rol que no es principal ni feat.'
-- Regla: en los creditos un artista solo puede ser principal o feat.
-- Esperado: ERROR new row for relation "song_artist" violates check constraint "song_artist_role_check"
INSERT INTO song_artist (song_id, artist_id, role) VALUES (104, 'A2', 'productor');

\echo 'CHECK: numero de pista 0'
-- Regla: las pistas de un album empiezan en 1.
-- Esperado: ERROR new row for relation "song_album" violates check constraint "song_album_track_number_check"
INSERT INTO song_album (song_id, album_id, track_number) VALUES (108, 201, 0);


\echo '=============================================='
\echo 'c) Registro y eliminacion de un suscriptor'
\echo '=============================================='
-- Cada operacion va en una transaccion (BEGIN ... COMMIT). Si una
-- instruccion falla dentro de la transaccion, PostgreSQL ignora las
-- siguientes y el COMMIT final se convierte en ROLLBACK: no se guarda nada.

\echo 'Registro exitoso: sofia'
BEGIN;
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (5, 'sofia@mail.com', '2026-11-03', 1);
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (5, 5, 'sofi.m', 's5.jpg', 'MX');
INSERT INTO libraries (library_id, subscriber_id)
VALUES (5, 5);
COMMIT;

-- Esperado: 5 | sofia@mail.com | sofi.m | 5 (sofia tiene perfil y biblioteca)
SELECT su.subscriber_id, su.email, p.display_name, l.library_id
FROM subscribers su
JOIN profiles p  ON p.subscriber_id = su.subscriber_id
JOIN libraries l ON l.subscriber_id = su.subscriber_id
WHERE su.subscriber_id = 5;

\echo 'Registro que falla a medio camino: pedro, con un pais que no existe'
-- Antes: 5 suscriptores, 5 perfiles, 5 bibliotecas
SELECT (SELECT COUNT(*) FROM subscribers) AS suscriptores,
       (SELECT COUNT(*) FROM profiles)    AS perfiles,
       (SELECT COUNT(*) FROM libraries)   AS bibliotecas;

BEGIN;
-- Este INSERT si funciona...
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id)
VALUES (6, 'pedro@mail.com', '2026-11-03', 2);
-- ...pero este falla porque el pais XX no existe (ERROR de llave foranea)
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code)
VALUES (6, 6, 'pedro_r', NULL, 'XX');
-- Este ya no se ejecuta: ERROR current transaction is aborted
INSERT INTO libraries (library_id, subscriber_id)
VALUES (6, 6);
-- PostgreSQL responde ROLLBACK en lugar de COMMIT
COMMIT;

-- Despues: siguen 5, 5 y 5. pedro no quedo registrado aunque su primer
-- INSERT si habia funcionado, asi que no hay un suscriptor sin perfil.
SELECT (SELECT COUNT(*) FROM subscribers) AS suscriptores,
       (SELECT COUNT(*) FROM profiles)    AS perfiles,
       (SELECT COUNT(*) FROM libraries)   AS bibliotecas;
-- Esperado: 0 filas
SELECT * FROM subscribers WHERE email = 'pedro@mail.com';

\echo 'Preparo datos de sofia para probar la eliminacion'
-- Le doy a sofia una playlist con canciones y cosas guardadas en su
-- biblioteca, para que la eliminacion tenga algo que borrar.
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id)
VALUES (15, 'Para correr', '2026-11-03', 5);
INSERT INTO playlist_song (playlist_id, song_id, added_at, position) VALUES
    (15, 104, '2026-11-03', 1),
    (15, 105, '2026-11-03', 2);
INSERT INTO library_song (library_id, song_id) VALUES (5, 106);
INSERT INTO library_album (library_id, album_id) VALUES (5, 203);

\echo 'Eliminacion exitosa: sofia'
-- Catalogo antes: 8 canciones, 6 albumes, 11 artistas
SELECT (SELECT COUNT(*) FROM songs)   AS canciones,
       (SELECT COUNT(*) FROM albums)  AS albumes,
       (SELECT COUNT(*) FROM artists) AS artistas;

-- Borro de abajo hacia arriba: primero lo que depende del suscriptor y al
-- final el suscriptor. Solo borro filas de sofia; las canciones y el album
-- que tenia guardados siguen en el catalogo.
BEGIN;
DELETE FROM playlist_song
WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 5);
DELETE FROM playlists     WHERE subscriber_id = 5;
DELETE FROM library_song
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 5);
DELETE FROM library_album
WHERE library_id IN (SELECT library_id FROM libraries WHERE subscriber_id = 5);
DELETE FROM libraries     WHERE subscriber_id = 5;
DELETE FROM profiles      WHERE subscriber_id = 5;
DELETE FROM subscribers   WHERE subscriber_id = 5;
COMMIT;

-- Esperado: 0 filas (sofia y su playlist ya no existen)
SELECT * FROM subscribers WHERE subscriber_id = 5;
SELECT * FROM playlists   WHERE playlist_id = 15;
-- Catalogo despues: siguen 8 canciones, 6 albumes y 11 artistas
SELECT (SELECT COUNT(*) FROM songs)   AS canciones,
       (SELECT COUNT(*) FROM albums)  AS albumes,
       (SELECT COUNT(*) FROM artists) AS artistas;

\echo 'Eliminacion que falla a medio camino: luis'
-- Antes: luis tiene 2 playlists con 5 canciones en total, 1 cancion y
-- 2 albumes guardados, su perfil y su biblioteca.
SELECT (SELECT COUNT(*) FROM playlists WHERE subscriber_id = 2) AS playlists,
       (SELECT COUNT(*) FROM playlist_song ps
          JOIN playlists p ON p.playlist_id = ps.playlist_id
         WHERE p.subscriber_id = 2)                             AS canciones_en_playlists,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 2) AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 2) AS albumes_guardados,
       (SELECT COUNT(*) FROM profiles  WHERE subscriber_id = 2)  AS perfil,
       (SELECT COUNT(*) FROM libraries WHERE subscriber_id = 2)  AS biblioteca;

BEGIN;
-- Estos cuatro DELETE si funcionan...
DELETE FROM playlist_song
WHERE playlist_id IN (SELECT playlist_id FROM playlists WHERE subscriber_id = 2);
DELETE FROM playlists     WHERE subscriber_id = 2;
DELETE FROM library_song  WHERE library_id = 2;
DELETE FROM library_album WHERE library_id = 2;
-- ...pero aqui intento borrar al suscriptor sin haber borrado antes su
-- biblioteca ni su perfil. La llave foranea lo impide (ERROR) y la
-- transaccion se cancela.
DELETE FROM subscribers   WHERE subscriber_id = 2;
-- PostgreSQL responde ROLLBACK en lugar de COMMIT
COMMIT;

-- Despues: los mismos numeros que antes (2, 5, 1, 2, 1, 1).
-- Los DELETE que si habian funcionado tambien se deshicieron.
SELECT (SELECT COUNT(*) FROM playlists WHERE subscriber_id = 2) AS playlists,
       (SELECT COUNT(*) FROM playlist_song ps
          JOIN playlists p ON p.playlist_id = ps.playlist_id
         WHERE p.subscriber_id = 2)                             AS canciones_en_playlists,
       (SELECT COUNT(*) FROM library_song  WHERE library_id = 2) AS canciones_guardadas,
       (SELECT COUNT(*) FROM library_album WHERE library_id = 2) AS albumes_guardados,
       (SELECT COUNT(*) FROM profiles  WHERE subscriber_id = 2)  AS perfil,
       (SELECT COUNT(*) FROM libraries WHERE subscriber_id = 2)  AS biblioteca;
