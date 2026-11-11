-- Migracion 03: conteos de reproducciones (Tarea 4)
-- Se aplica sobre una base que ya tiene 01_schema.sql y 02_seed.sql.
-- Se puede ejecutar varias veces sin error (IF NOT EXISTS).
-- Una vez aplicada, no se edita: cualquier correccion va en una migracion nueva.
-- Regla de la tarea: aqui solo se guardan conteos, nunca los mensajes de Kafka.
-- Sin ON DELETE CASCADE, igual que el resto del esquema.

-- Cuantas reproducciones validas hizo cada suscriptor de cada cancion, desde siempre.
-- Responde: las 20 canciones mas escuchadas de un suscriptor.
CREATE TABLE IF NOT EXISTS subscriber_song_play (
    subscriber_id integer NOT NULL REFERENCES subscribers (subscriber_id),
    song_id       integer NOT NULL REFERENCES songs (song_id),
    num_rep       integer NOT NULL CHECK (num_rep > 0),
    PRIMARY KEY (subscriber_id, song_id)
);

-- Cuantas reproducciones validas tuvo cada cancion cada dia (UTC).
-- Responde: el top 100 semanal.
CREATE TABLE IF NOT EXISTS song_daily_play (
    song_id   integer NOT NULL REFERENCES songs (song_id),
    play_date date    NOT NULL,
    num_rep   integer NOT NULL CHECK (num_rep > 0),
    PRIMARY KEY (song_id, play_date)
);

-- El top semanal filtra por fecha; la PK empieza por song_id y no ayuda a ese filtro.
CREATE INDEX IF NOT EXISTS song_daily_play_play_date_idx ON song_daily_play (play_date);

-- Checkpoint del processor: hasta que byte de cada archivo del crudo ya se proceso.
-- No guarda mensajes, solo el nombre del archivo y una posicion. El processor la
-- actualiza en la MISMA transaccion que los conteos: si falla a la mitad no se aplica
-- ni el conteo ni el avance, asi que nada se cuenta dos veces y nada se pierde.
CREATE TABLE IF NOT EXISTS ingestion_checkpoint (
    file_name   varchar(100) PRIMARY KEY,                       -- p. ej. 2026-11-10T22.log
    byte_offset bigint       NOT NULL CHECK (byte_offset >= 0), -- bytes ya procesados
    updated_at  timestamptz  NOT NULL DEFAULT now()             -- ultima corrida que lo avanzo
);
