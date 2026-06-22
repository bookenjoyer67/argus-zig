#!/usr/bin/env python3
"""Patch sdkconfig to enable NimBLE BLE scanning.

ESP-IDF v5.4 Kconfig choice dependency resolution prevents
CONFIG_BT_NIMBLE_ENABLED from being set via sdkconfig.defaults
when Bluedroid is the default choice. This script directly
injects the required BT/NimBLE configs.

Run after `idf.py set-target esp32s3` and whenever sdkconfig is regenerated.
"""

import os
import sys

# Paths
PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SDKCONFIG = os.path.join(PROJECT_DIR, "sdkconfig")
CTS_REF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nimble_ref_sdkconfig.txt")

def main():
    if not os.path.exists(SDKCONFIG):
        print(f"Error: {SDKCONFIG} not found. Run 'idf.py set-target esp32s3' first.")
        sys.exit(1)

    # Read reference NimBLE configs from the bundled file
    if not os.path.exists(CTS_REF):
        print(f"Error: {CTS_REF} not found.")
        sys.exit(1)

    with open(CTS_REF) as f:
        ref_configs = {}
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, val = line.split('=', 1)
                if key.startswith('CONFIG_BT_') or key.startswith('CONFIG_NIMBLE'):
                    ref_configs[key] = val

    # Read current sdkconfig
    with open(SDKCONFIG) as f:
        lines = f.readlines()

    # Replace/add BT and NIMBLE configs
    new_lines = []
    seen = set()
    for line in lines:
        line_s = line.strip()
        replaced = False
        if line_s and not line_s.startswith('#'):
            if '=' in line_s:
                key = line_s.split('=', 1)[0]
                if key in ref_configs:
                    new_lines.append(f'{key}={ref_configs[key]}\n')
                    seen.add(key)
                    replaced = True
        if not replaced:
            new_lines.append(line)

    # Append any remaining configs not already in file
    for key, val in sorted(ref_configs.items()):
        if key not in seen:
            new_lines.append(f'{key}={val}\n')

    with open(SDKCONFIG, 'w') as f:
        f.writelines(new_lines)

    # Verify
    bt_enabled = any('CONFIG_BT_ENABLED=y' in l for l in new_lines)
    nimble_enabled = any('CONFIG_BT_NIMBLE_ENABLED=y' in l for l in new_lines)
    if bt_enabled and nimble_enabled:
        print("sdkconfig patched: NimBLE BLE scanning enabled")
    else:
        print("Warning: NimBLE may not be properly enabled in sdkconfig")

if __name__ == '__main__':
    main()
