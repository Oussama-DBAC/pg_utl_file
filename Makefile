EXTENSION = pg_utl_file
DATA = pg_utl_file--1.0.sql
MODULES = pg_utl_file

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
