-- Esquema de la BD de Spotify
-- Sale del diagrama ER de la Tarea 2 (docs/diagrama_er.png).
-- Las tablas van en orden: primero las que no dependen de nadie y
-- despues las que tienen llaves foraneas hacia ellas.
-- No uso ON DELETE CASCADE: si una fila tiene dependientes, PostgreSQL
-- no deja borrarla (es el comportamiento por defecto, NO ACTION).

-- Planes de suscripcion (Premium, Gratuita, Familiar...)
CREATE TABLE subscriptions (
    subscription_id integer      PRIMARY KEY,
    name            varchar(30)  NOT NULL UNIQUE,
    price           decimal(6,2) NOT NULL CHECK (price >= 0),
    has_ads         boolean      NOT NULL
);

-- Paises, la entidad nueva que salio al normalizar (codigo -> nombre)
CREATE TABLE countries (
    country_code char(2)     PRIMARY KEY,
    name         varchar(60) NOT NULL UNIQUE
);

-- subscriptions 1..1 a subscribers 0..N:
-- todo suscriptor tiene un plan (NOT NULL) y un plan puede no tener suscriptores.
CREATE TABLE subscribers (
    subscriber_id   integer      PRIMARY KEY,
    email           varchar(100) NOT NULL UNIQUE,
    registered_at   date         NOT NULL,
    subscription_id integer      NOT NULL REFERENCES subscriptions (subscription_id)
);

-- subscribers 1..1 a profiles 1..1:
-- UNIQUE en subscriber_id hace que cada suscriptor tenga como maximo un perfil.
-- El minimo de 1 (que todo suscriptor tenga perfil) no se puede poner con
-- una restriccion sencilla; lo cuida la transaccion de registro de tests.sql.
CREATE TABLE profiles (
    profile_id    integer      PRIMARY KEY,
    subscriber_id integer      NOT NULL UNIQUE REFERENCES subscribers (subscriber_id),
    display_name  varchar(50)  NOT NULL,
    photo         varchar(255),                  -- puede ir vacia (marta no tiene foto)
    country_code  char(2)      NOT NULL REFERENCES countries (country_code)
);

-- subscribers 1..1 a libraries 1..1, igual que profiles.
CREATE TABLE libraries (
    library_id    integer PRIMARY KEY,
    subscriber_id integer NOT NULL UNIQUE REFERENCES subscribers (subscriber_id)
);

-- subscribers 1..1 a playlists 0..N: toda playlist tiene dueno.
CREATE TABLE playlists (
    playlist_id   integer      PRIMARY KEY,
    name          varchar(100) NOT NULL,
    created_at    date         NOT NULL,
    subscriber_id integer      NOT NULL REFERENCES subscribers (subscriber_id)
);

-- countries 1..1 a artists 0..N: todo artista es de un pais.
CREATE TABLE artists (
    artist_id    varchar(10)  PRIMARY KEY,
    name         varchar(100) NOT NULL,
    country_code char(2)      NOT NULL REFERENCES countries (country_code)
);

CREATE TABLE songs (
    song_id  integer      PRIMARY KEY,
    title    varchar(150) NOT NULL,
    duration time         NOT NULL CHECK (duration > '00:00:00'),
    genre    varchar(50)  NOT NULL
);

-- artists 1..1 a albums 0..N: todo album tiene un artista.
CREATE TABLE albums (
    album_id     integer      PRIMARY KEY,
    title        varchar(150) NOT NULL,
    release_year integer      NOT NULL CHECK (release_year BETWEEN 1900 AND 2100),
    cover        varchar(255) NOT NULL,
    artist_id    varchar(10)  NOT NULL REFERENCES artists (artist_id)
);

-- Tablas de union

-- playlists 1..1 a playlist_song 0..N (puede haber playlists vacias)
-- songs 1..1 a playlist_song 0..N
-- UNIQUE (playlist_id, position): dos canciones no pueden ocupar el mismo
-- lugar dentro de una playlist.
CREATE TABLE playlist_song (
    playlist_id integer NOT NULL REFERENCES playlists (playlist_id),
    song_id     integer NOT NULL REFERENCES songs (song_id),
    added_at    date    NOT NULL,
    position    integer NOT NULL CHECK (position > 0),
    PRIMARY KEY (playlist_id, song_id),
    UNIQUE (playlist_id, position)
);

-- songs 1..1 a song_artist 1..N y artists 1..1 a song_artist 0..N.
-- El minimo de 1 del lado de la cancion (toda cancion tiene al menos un
-- artista) no se puede forzar con una restriccion sencilla.
CREATE TABLE song_artist (
    song_id   integer     NOT NULL REFERENCES songs (song_id),
    artist_id varchar(10) NOT NULL REFERENCES artists (artist_id),
    role      varchar(20) NOT NULL CHECK (role IN ('principal', 'feat.')),
    PRIMARY KEY (song_id, artist_id)
);

-- songs 1..1 a song_album 0..N (puede haber canciones sin album)
-- albums 1..1 a song_album 1..N (el minimo de 1 tampoco se puede forzar aqui)
-- UNIQUE (album_id, track_number): no se repite el numero de pista en un album.
CREATE TABLE song_album (
    song_id      integer NOT NULL REFERENCES songs (song_id),
    album_id     integer NOT NULL REFERENCES albums (album_id),
    track_number integer NOT NULL CHECK (track_number > 0),
    PRIMARY KEY (song_id, album_id),
    UNIQUE (album_id, track_number)
);

-- libraries 1..1 a library_song 0..N y songs 1..1 a library_song 0..N
CREATE TABLE library_song (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    song_id    integer NOT NULL REFERENCES songs (song_id),
    PRIMARY KEY (library_id, song_id)
);

-- libraries 1..1 a library_album 0..N y albums 1..1 a library_album 0..N
CREATE TABLE library_album (
    library_id integer NOT NULL REFERENCES libraries (library_id),
    album_id   integer NOT NULL REFERENCES albums (album_id),
    PRIMARY KEY (library_id, album_id)
);
