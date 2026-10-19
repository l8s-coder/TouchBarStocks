#include <stdbool.h>
typedef struct { double temperature, actual, minimum, maximum, target; int mode, fanCount; } ThermalReading;
bool ThermalRead(ThermalReading *reading);
bool ThermalSetTarget(double rpm);
bool ThermalRestoreAuto(void);
const char *ThermalLastError(void);
