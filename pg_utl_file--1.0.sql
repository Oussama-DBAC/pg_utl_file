CREATE TYPE utl_file_type AS (
    id integer
);

CREATE TABLE utl_file_directories (
    dir_name text PRIMARY KEY,
    dir_path text NOT NULL,
    created_at timestamptz DEFAULT now()
);

REVOKE ALL ON utl_file_directories FROM public;
GRANT SELECT ON utl_file_directories TO public;

CREATE FUNCTION _utl_file_fopen(filepath text, mode text) RETURNS integer
AS 'MODULE_PATHNAME', 'utl_file_fopen'
LANGUAGE C STRICT;

CREATE FUNCTION _utl_file_put_line(id integer, buffer text, autoflush boolean) RETURNS void
AS 'MODULE_PATHNAME', 'utl_file_put_line'
LANGUAGE C STRICT;

CREATE FUNCTION _utl_file_get_line(id integer) RETURNS text
AS 'MODULE_PATHNAME', 'utl_file_get_line'
LANGUAGE C STRICT;

CREATE FUNCTION _utl_file_fflush(id integer) RETURNS void
AS 'MODULE_PATHNAME', 'utl_file_fflush'
LANGUAGE C STRICT;

CREATE FUNCTION _utl_file_fclose(id integer) RETURNS void
AS 'MODULE_PATHNAME', 'utl_file_fclose'
LANGUAGE C STRICT;

CREATE FUNCTION _utl_file_is_open(id integer) RETURNS boolean
AS 'MODULE_PATHNAME', 'utl_file_is_open'
LANGUAGE C STRICT;

CREATE OR REPLACE FUNCTION utl_file_fopen(location text, filename text, open_mode text, max_linesize integer DEFAULT 1024)
RETURNS utl_file_type AS $$
DECLARE
    v_dir_path text;
    v_full_path text;
    v_res utl_file_type;
BEGIN
    SELECT dir_path INTO v_dir_path 
    FROM utl_file_directories 
    WHERE dir_name = location;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVALID_PATH: Directory "%" not found or not registered', location;
    END IF;

    IF filename LIKE '%..%' OR filename LIKE '%/%' OR filename LIKE '%\%' THEN
        RAISE EXCEPTION 'INVALID_FILENAME: Filename contains invalid characters for directory traversal';
    END IF;

    v_full_path := v_dir_path || '/' || filename;
    v_res.id := _utl_file_fopen(v_full_path, open_mode);
    
    RETURN v_res;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION utl_file_put_line(file utl_file_type, buffer text, autoflush boolean DEFAULT false)
RETURNS void AS $$
BEGIN
    PERFORM _utl_file_put_line(file.id, buffer, autoflush);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION utl_file_get_line(file utl_file_type, OUT buffer text)
RETURNS text AS $$
BEGIN
    buffer := _utl_file_get_line(file.id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION utl_file_fflush(file utl_file_type)
RETURNS void AS $$
BEGIN
    PERFORM _utl_file_fflush(file.id);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION utl_file_fclose(INOUT file utl_file_type)
AS $$
BEGIN
    PERFORM _utl_file_fclose(file.id);
    file.id := NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION utl_file_is_open(file utl_file_type)
RETURNS boolean AS $$
BEGIN
    IF file IS NULL OR file.id IS NULL THEN
        RETURN false;
    END IF;
    RETURN _utl_file_is_open(file.id);
END;
$$ LANGUAGE plpgsql;
