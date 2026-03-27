#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"
#include "storage/fd.h"
#include "access/xact.h"

PG_MODULE_MAGIC;

#define MAX_OPEN_FILES 100

typedef struct {
    int id;
    FILE *fp;
    bool in_use;
} UTLFileHandle;

static UTLFileHandle file_handles[MAX_OPEN_FILES];
static bool xact_callback_registered = false;
static int current_id_seq = 1;

static void utl_file_xact_callback(XactEvent event, void *arg) {
    int i;
    if (event == XACT_EVENT_ABORT || event == XACT_EVENT_COMMIT) {
        for (i = 0; i < MAX_OPEN_FILES; i++) {
            file_handles[i].in_use = false;
            file_handles[i].fp = NULL;
        }
    }
}

Datum utl_file_fopen(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_fopen);

Datum utl_file_fopen(PG_FUNCTION_ARGS) {
    text *filepath_txt = PG_GETARG_TEXT_PP(0);
    text *mode_txt = PG_GETARG_TEXT_PP(1);
    char *fullpath = text_to_cstring(filepath_txt);
    char *mode = text_to_cstring(mode_txt);
    char c_mode[3] = {0};
    int slot = -1;
    int i;
    FILE *fp;
    
    if (strstr(fullpath, "..") != NULL) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_NAME),
                        errmsg("UTL_FILE invalid path: directory traversal is not allowed")));
    }

    c_mode[0] = tolower((unsigned char)mode[0]);
    if (c_mode[0] != 'r' && c_mode[0] != 'w' && c_mode[0] != 'a') {
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                        errmsg("UTL_FILE invalid file open mode. Use 'r', 'w', or 'a'")));
    }

    if (!xact_callback_registered) {
        RegisterXactCallback(utl_file_xact_callback, NULL);
        xact_callback_registered = true;
    }

    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (!file_handles[i].in_use) {
            slot = i;
            break;
        }
    }
    
    if (slot == -1) {
        ereport(ERROR, (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                        errmsg("Too many open files in UTL_FILE session (max %d)", MAX_OPEN_FILES)));
    }

    fp = AllocateFile(fullpath, c_mode);
    if (!fp) {
        ereport(ERROR, (errcode_for_file_access(),
                        errmsg("UTL_FILE could not open file \"%s\": %m", fullpath)));
    }

    file_handles[slot].id = current_id_seq++;
    file_handles[slot].fp = fp;
    file_handles[slot].in_use = true;

    PG_RETURN_INT32(file_handles[slot].id);
}

Datum utl_file_put_line(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_put_line);

Datum utl_file_put_line(PG_FUNCTION_ARGS) {
    int id = PG_GETARG_INT32(0);
    text *txt = PG_GETARG_TEXT_PP(1);
    bool autoflush = PG_GETARG_BOOL(2);
    FILE *fp = NULL;
    char *str;
    int i;

    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (file_handles[i].in_use && file_handles[i].id == id) {
            fp = file_handles[i].fp;
            break;
        }
    }
    
    if (!fp) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("Invalid UTL_FILE handle. File might be closed or opened in a previous transaction.")));
    }

    str = text_to_cstring(txt);
    if (fputs(str, fp) == EOF || fputs("\n", fp) == EOF) {
        ereport(ERROR, (errcode_for_file_access(), errmsg("UTL_FILE could not write to file: %m")));
    }
    
    if (autoflush) {
        fflush(fp);
    }

    PG_RETURN_VOID();
}

Datum utl_file_get_line(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_get_line);

Datum utl_file_get_line(PG_FUNCTION_ARGS) {
    int id = PG_GETARG_INT32(0);
    FILE *fp = NULL;
    StringInfoData buf;
    char tmp[1024];
    int i;
    
    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (file_handles[i].in_use && file_handles[i].id == id) {
            fp = file_handles[i].fp;
            break;
        }
    }
    
    if (!fp) {
        ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("Invalid UTL_FILE handle")));
    }

    initStringInfo(&buf);
    
    while (fgets(tmp, sizeof(tmp), fp) != NULL) {
        appendStringInfoString(&buf, tmp);
        if (buf.len > 0 && buf.data[buf.len - 1] == '\n') {
            buf.data[buf.len - 1] = '\0';
            buf.len--;
            if (buf.len > 0 && buf.data[buf.len - 1] == '\r') {
                buf.data[buf.len - 1] = '\0';
                buf.len--;
            }
            break;
        }
    }
    
    if (buf.len == 0 && feof(fp)) {
        ereport(ERROR, (errcode(ERRCODE_NO_DATA_FOUND), errmsg("UTL_FILE read error: end of file reached")));
    }
    
    PG_RETURN_TEXT_P(cstring_to_text(buf.data));
}

Datum utl_file_fflush(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_fflush);

Datum utl_file_fflush(PG_FUNCTION_ARGS) {
    int id = PG_GETARG_INT32(0);
    int i;
    
    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (file_handles[i].in_use && file_handles[i].id == id) {
            fflush(file_handles[i].fp);
            PG_RETURN_VOID();
        }
    }
    
    ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("Invalid UTL_FILE handle")));
    PG_RETURN_VOID();
}

Datum utl_file_fclose(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_fclose);

Datum utl_file_fclose(PG_FUNCTION_ARGS) {
    int id = PG_GETARG_INT32(0);
    int i;
    
    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (file_handles[i].in_use && file_handles[i].id == id) {
            FreeFile(file_handles[i].fp);
            file_handles[i].in_use = false;
            file_handles[i].fp = NULL;
            PG_RETURN_VOID();
        }
    }
    
    PG_RETURN_VOID();
}

Datum utl_file_is_open(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(utl_file_is_open);

Datum utl_file_is_open(PG_FUNCTION_ARGS) {
    int id = PG_GETARG_INT32(0);
    int i;
    
    for (i = 0; i < MAX_OPEN_FILES; i++) {
        if (file_handles[i].in_use && file_handles[i].id == id) {
            PG_RETURN_BOOL(true);
        }
    }
    
    PG_RETURN_BOOL(false);
}
