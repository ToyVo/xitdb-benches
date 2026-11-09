# vendor/

`sqlite/` holds the SQLite amalgamation (sqlite3.c + sqlite3.h),
fetched by `install.sh` (pinned `SQLITE_VERSION`) and compiled into the
binary — no system SQLite needed. This twin carries no xitdb code.
