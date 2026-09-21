/* SQLite public-domain C API: declaration-only subset for interruption.
 * SQLite authors disclaim copyright. No SQLite implementation is vendored.
 */
#ifndef CSV_SQLITE_INTERRUPT_H
#define CSV_SQLITE_INTERRUPT_H
typedef struct sqlite3 sqlite3;
void sqlite3_interrupt(sqlite3 *db);
#endif
