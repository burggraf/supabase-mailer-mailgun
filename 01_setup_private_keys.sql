CREATE SCHEMA IF NOT EXISTS private;
CREATE TABLE IF NOT EXISTS private.keys (
    key text primary key not null,
    value text
);
REVOKE ALL ON TABLE private.keys FROM PUBLIC;
GRANT ALL ON SCHEMA private to postgres;
