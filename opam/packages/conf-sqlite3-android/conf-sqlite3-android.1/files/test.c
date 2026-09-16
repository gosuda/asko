#include <sqlite3.h>
int main(void) {
  sqlite3 *database = 0;
  int result = sqlite3_open(":memory:", &database);
  sqlite3_close(database);
  return result;
}
