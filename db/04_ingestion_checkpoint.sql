-- Migracion 04: checkpoint del processor (Tarea 4)
-- Guarda hasta que byte de cada archivo del crudo ya se proceso.
-- No guarda mensajes: solo el nombre del archivo y una posicion.
-- El processor la actualiza en la MISMA transaccion que los conteos, asi que
-- si falla a la mitad no se aplica ni el conteo ni el avance: nada se cuenta
-- dos veces y nada se pierde.
-- Se puede ejecutar varias veces sin error (IF NOT EXISTS).

CREATE TABLE IF NOT EXISTS ingestion_checkpoint (
    file_name   varchar(100) PRIMARY KEY,                       -- p. ej. 2026-11-10T22.log
    byte_offset bigint       NOT NULL CHECK (byte_offset >= 0), -- bytes ya procesados
    updated_at  timestamptz  NOT NULL DEFAULT now()             -- ultima corrida que lo avanzo
);
