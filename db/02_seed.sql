-- Datos iniciales de la BD de Spotify
-- Son los datos de las tablas A, B, C y D de Laura, ya normalizados en la
-- Tarea 2. Conservo sus ids (song_id, album_id, artist_id, playlist_id).
-- Los ids de subscriptions, subscribers, profiles y libraries no venian en
-- los datos; los numere yo en el orden en que aparecen.

-- Planes
-- El plan 4 (Estudiantes) lo agregue yo: es la suscripcion sin suscriptores.
INSERT INTO subscriptions (subscription_id, name, price, has_ads) VALUES
    (1, 'Premium',     129.00, false),
    (2, 'Gratuita',      0.00, true),
    (3, 'Familiar',    199.00, false),
    (4, 'Estudiantes',  69.00, false);

-- Paises
INSERT INTO countries (country_code, name) VALUES
    ('AR', 'Argentina'),
    ('CO', 'Colombia'),
    ('MX', 'México'),
    ('PR', 'Puerto Rico'),
    ('US', 'Estados Unidos');

-- Suscriptores (tabla D)
INSERT INTO subscribers (subscriber_id, email, registered_at, subscription_id) VALUES
    (1, 'ana@mail.com',   '2025-11-02', 1),
    (2, 'luis@mail.com',  '2026-01-15', 2),
    (3, 'marta@mail.com', '2026-05-20', 3),
    (4, 'diego@mail.com', '2026-09-01', 3);

-- Perfiles (tabla D). marta no tiene foto, por eso va NULL.
INSERT INTO profiles (profile_id, subscriber_id, display_name, photo, country_code) VALUES
    (1, 1, 'anaruiz', 'a1.jpg', 'MX'),
    (2, 2, 'luis.s',  'l2.jpg', 'MX'),
    (3, 3, 'marta_g', NULL,     'AR'),
    (4, 4, 'diegol',  'd4.jpg', 'MX');

-- Bibliotecas: una por suscriptor, con el mismo numero que su suscriptor
INSERT INTO libraries (library_id, subscriber_id) VALUES
    (1, 1),
    (2, 2),
    (3, 3),
    (4, 4);

-- Artistas (tabla B)
-- A11 lo agregue yo: es el artista sin canciones ni albumes.
INSERT INTO artists (artist_id, name, country_code) VALUES
    ('A1',  'Karol G',          'CO'),
    ('A2',  'Shakira',          'CO'),
    ('A3',  'Miley Cyrus',      'US'),
    ('A4',  'SZA',              'US'),
    ('A5',  'Bizarrap',         'AR'),
    ('A6',  'Eslabon Armado',   'US'),
    ('A7',  'Peso Pluma',       'MX'),
    ('A8',  'Bad Bunny',        'PR'),
    ('A9',  'Chencho Corleone', 'PR'),
    ('A10', 'Los del Pitic',    'MX'),
    ('A11', 'Natanael Cano',    'MX');

-- Canciones (tabla B). La duracion va como hh:mm:ss.
-- La cancion sin album ya venia en los datos: 108 Calor de Agosto.
INSERT INTO songs (song_id, title, duration, genre) VALUES
    (101, 'Ella Baila Sola',         '00:02:45', 'Regional mexicano'),
    (102, 'TQG',                     '00:03:17', 'Reguetón'),
    (103, 'Bzrp Music Sessions #53', '00:03:33', 'Pop latino'),
    (104, 'Flowers',                 '00:03:20', 'Pop'),
    (105, 'Kill Bill',               '00:02:33', 'R&B'),
    (106, 'Tití Me Preguntó',        '00:04:03', 'Reguetón'),
    (107, 'Me Porto Bonito',         '00:02:58', 'Reguetón'),
    (108, 'Calor de Agosto',         '00:03:05', 'Regional mexicano');

-- Albumes (tabla C)
INSERT INTO albums (album_id, title, release_year, cover, artist_id) VALUES
    (201, 'Desvelado',                2023, 'desvelado.jpg', 'A6'),
    (202, 'Mañana Será Bonito',       2023, 'msb.jpg',       'A1'),
    (203, 'Endless Summer Vacation',  2023, 'esv.jpg',       'A3'),
    (204, 'SOS',                      2022, 'sos.jpg',       'A4'),
    (205, 'Un Verano Sin Ti',         2022, 'uvst.jpg',      'A8'),
    (206, 'Las Mujeres Ya No Lloran', 2024, 'lmynl.jpg',     'A2');

-- Playlists (tabla A)
-- La playlist vacia ya venia en los datos: 13 Viaje.
INSERT INTO playlists (playlist_id, name, created_at, subscriber_id) VALUES
    (10, 'Gym',           '2026-03-01', 1),
    (11, 'Para estudiar', '2026-04-10', 1),
    (12, 'Gym',           '2026-05-02', 2),
    (13, 'Viaje',         '2026-06-15', 3),
    (14, 'Favoritas',     '2026-06-20', 2);

-- Canciones de cada playlist (tabla A)
INSERT INTO playlist_song (playlist_id, song_id, added_at, position) VALUES
    (10, 101, '2026-03-01', 1),
    (10, 102, '2026-03-01', 2),
    (10, 103, '2026-03-04', 3),
    (11, 104, '2026-04-10', 1),
    (11, 101, '2026-04-12', 2),
    (12, 102, '2026-05-02', 1),
    (12, 105, '2026-05-02', 2),
    (14, 103, '2026-06-20', 1),
    (14, 104, '2026-06-21', 2),
    (14, 102, '2026-06-22', 3);

-- Creditos de cada cancion (tabla B)
INSERT INTO song_artist (song_id, artist_id, role) VALUES
    (101, 'A6',  'principal'),
    (101, 'A7',  'feat.'),
    (102, 'A1',  'principal'),
    (102, 'A2',  'feat.'),
    (103, 'A5',  'principal'),
    (103, 'A2',  'feat.'),
    (104, 'A3',  'principal'),
    (105, 'A4',  'principal'),
    (106, 'A8',  'principal'),
    (107, 'A8',  'principal'),
    (107, 'A9',  'feat.'),
    (108, 'A10', 'principal');

-- Canciones de cada album (tabla C)
INSERT INTO song_album (song_id, album_id, track_number) VALUES
    (101, 201, 6),
    (102, 202, 6),
    (104, 203, 1),
    (105, 204, 2),
    (107, 205, 3),
    (106, 205, 4),
    (103, 206, 11),
    (102, 206, 12);

-- Canciones guardadas en cada biblioteca (tabla D)
INSERT INTO library_song (library_id, song_id) VALUES
    (1, 102),
    (1, 104),
    (2, 103),
    (4, 101),
    (4, 108);

-- Albumes guardados en cada biblioteca (tabla D)
INSERT INTO library_album (library_id, album_id) VALUES
    (1, 205),
    (2, 204),
    (2, 206);
