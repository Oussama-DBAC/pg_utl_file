-- Smoke test for pg_utl_file.
--
-- Run as the extension owner (e.g. a superuser), against a database where the
-- extension is installed:
--
--     psql -d <db> -v ON_ERROR_STOP=1 -f test/smoke.sql
--
-- The script is self-checking: every assertion RAISEs on failure, so a clean
-- run (exit code 0) means all checks passed. It uses /tmp as the approved
-- directory and cleans up after itself.

\set ON_ERROR_STOP on

INSERT INTO utl_file_directories (dir_name, dir_path)
VALUES ('UTLF_SMOKE_DIR', '/tmp')
ON CONFLICT (dir_name) DO UPDATE SET dir_path = EXCLUDED.dir_path;

-- 1. Write/read round-trip + EOF via NO_DATA_FOUND.
DO $$
DECLARE f utl_file_type; line text;
BEGIN
    f := utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_smoke.txt', 'w');
    PERFORM utl_file_put_line(f, 'hello');
    PERFORM utl_file_put_line(f, 'world');
    f := utl_file_fclose(f);

    f := utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_smoke.txt', 'r');
    line := utl_file_get_line(f);
    ASSERT line = 'hello', format('expected "hello", got %L', line);
    line := utl_file_get_line(f);
    ASSERT line = 'world', format('expected "world", got %L', line);
    BEGIN
        line := utl_file_get_line(f);
        RAISE EXCEPTION 'expected NO_DATA_FOUND at end of file, got %L', line;
    EXCEPTION WHEN no_data_found THEN
        NULL;  -- expected
    END;
    f := utl_file_fclose(f);
    RAISE NOTICE 'PASS: write/read round-trip + EOF';
END $$;

-- 2. Directory traversal is rejected.
DO $$
BEGIN
    PERFORM utl_file_fopen('UTLF_SMOKE_DIR', '../etc/passwd', 'r');
    RAISE EXCEPTION 'FAIL: directory traversal was not rejected';
EXCEPTION WHEN others THEN
    ASSERT SQLERRM LIKE '%INVALID_FILENAME%', format('unexpected error: %s', SQLERRM);
    RAISE NOTICE 'PASS: directory traversal rejected';
END $$;

-- 3. Invalid open mode is rejected.
DO $$
BEGIN
    PERFORM utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_smoke.txt', 'x');
    RAISE EXCEPTION 'FAIL: invalid open mode was not rejected';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'PASS: invalid open mode rejected';
END $$;

-- 4. Unregistered directory is rejected.
DO $$
BEGIN
    PERFORM utl_file_fopen('NO_SUCH_DIR', 'x.txt', 'r');
    RAISE EXCEPTION 'FAIL: unregistered directory was not rejected';
EXCEPTION WHEN others THEN
    ASSERT SQLERRM LIKE '%INVALID_PATH%', format('unexpected error: %s', SQLERRM);
    RAISE NOTICE 'PASS: unregistered directory rejected';
END $$;

-- 5. max_linesize bounds get_line: a 5000-char physical line opened with
--    max_linesize = 1000 must come back in 1000-byte chunks.
DO $$
DECLARE f utl_file_type; line text;
BEGIN
    f := utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_long.txt', 'w');
    PERFORM utl_file_put_line(f, repeat('x', 5000));
    f := utl_file_fclose(f);

    f := utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_long.txt', 'r', 1000);
    line := utl_file_get_line(f);
    ASSERT length(line) = 1000, format('expected a 1000-byte chunk, got %s bytes', length(line));
    f := utl_file_fclose(f);
    RAISE NOTICE 'PASS: max_linesize bounds get_line';
END $$;

-- 6. max_linesize out of range is rejected.
DO $$
BEGIN
    PERFORM utl_file_fopen('UTLF_SMOKE_DIR', 'pg_utl_file_smoke.txt', 'r', 0);
    RAISE EXCEPTION 'FAIL: max_linesize = 0 was not rejected';
EXCEPTION WHEN invalid_parameter_value THEN
    RAISE NOTICE 'PASS: max_linesize out of range rejected';
END $$;

DELETE FROM utl_file_directories WHERE dir_name = 'UTLF_SMOKE_DIR';

\echo 'pg_utl_file smoke test: ALL CHECKS PASSED'
