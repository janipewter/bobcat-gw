#!/usr/bin/env python3
"""Patch Semtech sx1302_hal (libloragw/src/loragw_hal.c) for boards without
the STTS751 I2C temperature sensor, such as the Bobcat 300.

Without the sensor, lgw_start() aborts with
"failed to open I2C for temperature sensor". After patching, a missing sensor
is reported as a warning and a fixed temperature (25 C) is used for RSSI
temperature compensation.

Usage: patch_hal_tempsensor.py <path/to/loragw_hal.c>   (idempotent)
"""
import re
import sys

MARKER = "/* bobcat-gw: no temperature sensor patch */"
FIXED_TEMP = "25.0"

path = sys.argv[1]
src = open(path).read()
if MARKER in src:
    print(f"{path}: already patched")
    sys.exit(0)

# Upstream uses printf("ERROR: ..."), the Basics Station corecell patch uses
# ERROR_PRINTF("...").
ERR = r'(?:printf\("ERROR: |ERROR_PRINTF\(")'

# 1. lgw_start(): opening the I2C device must not be fatal.
src, n1 = re.subn(
    r'(' + ERR + r'failed to open I2C for temperature sensor on port 0x%02X\\n", ts_addr\);\s*)return LGW_HAL_ERROR;',
    r'\1ts_fd = -1;\n                break;',
    src)

# 2. lgw_start(): no sensor found on any port must not be fatal.
src, n2 = re.subn(
    r'(' + ERR + r'no temperature sensor found.\\n"\);\s*)return LGW_HAL_ERROR;',
    r'\1ts_fd = -1;',
    src)

# 3. lgw_get_temperature(): return a fixed value when there is no sensor.
src, n3 = re.subn(
    r'(case LGW_COM_SPI:\s*)(err = stts751_get_temperature\(ts_fd, ts_addr, temperature\);)',
    r'\1if (ts_fd < 0) { ' + MARKER + r' *temperature = ' + FIXED_TEMP +
    r'; err = LGW_HAL_SUCCESS; } else { \2 }',
    src)

# 4. lgw_stop(): don't try to close a sensor that was never opened.
src, n4 = re.subn(
    r'(x = i2c_linuxdev_close\(ts_fd\);)',
    r'x = (ts_fd < 0) ? 0 : i2c_linuxdev_close(ts_fd);',
    src, count=1)

if not (n1 and n2 and n3):
    sys.exit(f"{path}: patch failed (open={n1} notfound={n2} get={n3} close={n4}); HAL version not recognised")

for prefix in ('"ERROR: ', '"'):
    src = src.replace(prefix + "failed to open I2C for temperature sensor",
                      prefix.replace("ERROR", "WARNING") + "no I2C temperature sensor (using fixed " + FIXED_TEMP + "C)")
    src = src.replace(prefix + 'no temperature sensor found.\\n"',
                      prefix.replace("ERROR", "WARNING") + 'no temperature sensor found, using fixed ' + FIXED_TEMP + 'C\\n"')
open(path, "w").write(src)
print(f"{path}: patched")
