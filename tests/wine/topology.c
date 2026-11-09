// Display topology as games read it (patch_wine_topology.py): QueryDisplayConfig with
// QDC_DATABASE_CURRENT must say EXTEND with 2+ active monitors and INTERNAL with one.
// Stock Wine always says INTERNAL. Prints "info: ..." and "result: ok|bad"; exit 0 on ok.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
  int monitors = GetSystemMetrics(SM_CMONITORS);
  UINT32 np = 0, nm = 0;
  LONG r = GetDisplayConfigBufferSizes(QDC_DATABASE_CURRENT, &np, &nm);
  if (r) {
    printf("GetDisplayConfigBufferSizes: %ld\nresult: bad\n", r);
    return 1;
  }
  DISPLAYCONFIG_PATH_INFO *p = calloc(np + 1, sizeof *p);
  DISPLAYCONFIG_MODE_INFO *m = calloc(nm + 1, sizeof *m);
  DISPLAYCONFIG_TOPOLOGY_ID t = 0;
  r = QueryDisplayConfig(QDC_DATABASE_CURRENT, &np, p, &nm, m, &t);
  DISPLAYCONFIG_TOPOLOGY_ID want =
      monitors > 1 ? DISPLAYCONFIG_TOPOLOGY_EXTEND : DISPLAYCONFIG_TOPOLOGY_INTERNAL;
  const char *name = t == DISPLAYCONFIG_TOPOLOGY_INTERNAL ? "INTERNAL"
                     : t == DISPLAYCONFIG_TOPOLOGY_CLONE  ? "CLONE"
                     : t == DISPLAYCONFIG_TOPOLOGY_EXTEND ? "EXTEND"
                     : t == DISPLAYCONFIG_TOPOLOGY_EXTERNAL ? "EXTERNAL" : "?";
  int ok = r == 0 && t == want && (int)np == monitors;
  printf("info: %d monitor(s), %u path(s), topology %s\nresult: %s\n", monitors, np, name,
         ok ? "ok" : "bad");
  return ok ? 0 : 1;
}
