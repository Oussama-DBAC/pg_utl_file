# PostgreSQL Equivalent of Oracle UTL_FILE

This repository contains a production-grade, secure, and performant implementation of Oracle's `UTL_FILE` package for PostgreSQL (compatible with PG 12+).

It leverages a custom C extension to provide safe filesystem I/O directly tied to the database session, mimicking how Oracle natively handles `UTL_FILE` without relying on bloated compatibility extensions.

## 1. Architecture Explanation

Native PostgreSQL (PL/pgSQL) cannot safely read/write arbitrary files line-by-line during a transaction block. Functions like `COPY` can write large batches to files, but `COPY` is statement-based (not session-level stream based), appends implicitly to each row, and overwrites the whole file inherently.

To create a true equivalent to Oracle's `UTL_FILE` robust enough for production:
1. **C Extension (`pg_utl_file.c`)**: Manages real `FILE *` streams allocated via PostgreSQL `AllocateFile` APIs. This guarantees that file descriptors are safely tracked, closed on transaction aborts, and protected from leaking. Fast line-by-line reading logic is built directly in C.
2. **PostgreSQL Types and wrappers (`pg_utl_file--1.0.sql`)**: A virtual `utl_file_type` encapsulates an integer `id` referencing the C session pointer. 
3. **Security with Directory Whitelisting (`utl_file_directories`)**: In Oracle, `CREATE DIRECTORY` defines logical folders a DBA allows DB instances to read or write. In this extension, we recreate this securely with a configuration table. SQL functions enforce that the filename being accessed falls precisely inside an approved Oracle-style `location`.
4. **Directory Traversal Protection**: Any path navigation payloads (e.g. `../`) are rejected to secure the host Operating System.

## 2. Linux Configuration & Installation

### Prerequisites
- PostgreSQL development libraries (e.g., `postgresql-17-devel` for RedHat/OEL, or `postgresql-server-dev-12` for Ubuntu).
- GCC / Clang
- Make

### Building the Extension (RedHat / Oracle Enterprise Linux / CentOS)
If you are on an Enterprise Linux system, PostgreSQL is often installed in a versioned directory (like `/usr/pgsql-17/`). Therefore, your standard `make` will fail because it cannot find `pg_config`. You must specify the path explicitly:

```bash
cd pg_utl_file

# Compile the extension by pointing to the correct pg_config
sudo make PG_CONFIG=/usr/pgsql-17/bin/pg_config

# Install the binaries to the PostgreSQL library directory
sudo make install PG_CONFIG=/usr/pgsql-17/bin/pg_config
```
*(Adjust the path `-17` according to your PostgreSQL version).*

### Loading the Extension in your Database
Log into your target database via `psql` as a superuser (`postgres`):
```sql
CREATE EXTENSION pg_utl_file;
```

## 3. Usage Examples 

### A. Initial DBA Configuration (Security)
First, a Database Administrator must set up an approved directory. This replaces Oracle's `CREATE DIRECTORY`.
```sql
-- Superuser only
INSERT INTO utl_file_directories (dir_name, dir_path) 
VALUES ('MY_DIR', '/tmp/exports');

-- Optionally give usage rights to a standard developer
GRANT SELECT ON utl_file_directories TO dev_user;
```

### B. Standard Writing & Reading Example
Developers can use it in their stored procedures exactly like Oracle:

```sql
DO $$ 
DECLARE 
    v_file utl_file_type;
    v_line text;
BEGIN
    v_file := utl_file_fopen('MY_DIR', 'test_file.txt', 'w');
    PERFORM utl_file_put_line(v_file, 'Hello World From PostgreSQL!');
    v_file := utl_file_fclose(v_file);

    v_file := utl_file_fopen('MY_DIR', 'test_file.txt', 'r');
    
    LOOP
        -- Postgres trap NO_DATA_FOUND natively, just like Oracle!
        BEGIN
            v_line := utl_file_get_line(v_file);
        EXCEPTION
            WHEN no_data_found THEN
                EXIT; -- Reached EOF, breaking loop
        END;
        RAISE NOTICE 'Read: %', v_line;
    END LOOP;

    v_file := utl_file_fclose(v_file);
END $$;
```

### C. Advanced: Exporting a Table to a CSV File
```sql
DO $$
DECLARE
    v_file utl_file_type;
    v_record record;
    v_csv_line text;
BEGIN
    v_file := utl_file_fopen('MY_DIR', 'employees.csv', 'w');
    
    PERFORM utl_file_put_line(v_file, 'ID;NAME;DEPARTMENT;SALARY');
    
    FOR v_record IN SELECT * FROM my_employees_table LOOP
        v_csv_line := v_record.id || ';' || v_record.name || ';' || v_record.department || ';' || v_record.salary;
        PERFORM utl_file_put_line(v_file, v_csv_line);
    END LOOP;
    
    v_file := utl_file_fclose(v_file);
    RAISE NOTICE 'CSV Export Complete!';
END $$;
```

### D. Advanced: Reading a File and Inserting to DB (Import)
```sql
DO $$
DECLARE
    v_file utl_file_type;
    v_line text;
    v_eof boolean := false;
BEGIN
    v_file := utl_file_fopen('MY_DIR', 'external_logs.txt', 'r');
    
    LOOP
        BEGIN
            v_line := utl_file_get_line(v_file);
        EXCEPTION
            WHEN no_data_found THEN
                v_eof := true;
        END;
        
        EXIT WHEN v_eof;
        
        -- Insert the read line into a table
        INSERT INTO log_table (log_content) VALUES (v_line);
    END LOOP;
    
    v_file := utl_file_fclose(v_file);
END $$;
```


## 4. Alternative Approaches (No C Extension required)
If you cannot install C extensions (e.g., managed Cloud DBs like AWS RDS / Google CloudSQL) and don't care about memory efficiency:
1. Use `COPY (SELECT * FROM tmp_data) TO 'filename'` for text file exporting.
2. For reading: Load the file into a temporary `UNLOGGED` or `TEMP` table using `COPY temp_table FROM 'file'`, and then loop over the temporary table rows inside your procedure block.
**Tradeoffs:** Very high memory overhead for large files (no streaming), no exception safety, and `COPY` exclusively overwrites entirely unless hacks are employed.

## 5. Security Best Practices
- **Never grant INSERT/UPDATE/DELETE on `utl_file_directories` to public**. Only DB administrators should be able to dictate what paths on the OS the `postgres` user can traverse. 
- Files created by this extension are owned by the `postgres` OS user default group. To allow other system users to overwrite them, either change standard Postgres umask configurations or enforce external cron scripts fixing OS permissions.

## 6. Performance Considerations
- **Memory/FD limits:** We impose a `MAX_OPEN_FILES` sequence array internally to limit malicious sessions from starving OS file descriptors.
- **Buffering:** Native C `fgets`/`fputs` allows high-speed string chunk IO buffers perfectly bounded within `work_mem` constraints. Large files (several GBs) will read steadily with exact typical disk speed with zero excessive memory ballooning.

## 7. Limitations & Improvements
- Oracle `UTL_FILE` allows handles to remain open outside the transaction barrier inside the same logical session. This extension correctly and strictly closes handles gracefully when a `COMMIT` or `ROLLBACK` signal hits using standard pg transaction callbacks. This fundamentally aligns with PostgreSQL ACID best practices but limits holding file pointers open dynamically spanning across massive transaction boundaries.
