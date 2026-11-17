#!/usr/bin/env python3
#  Copyright (C) 2026 Leonardo Rossi
#  SPDX-License-Identifier: GPL-3.0-or-later
import os
import glob
import plistlib
from pathlib import Path

# 1. Percorsi standard dove Xcode e macOS salvano i profili dei simulatori
SEARCH_PATHS = [
    "/Library/Developer/CoreSimulator/Profiles/DeviceTypes/*.simdevicetype",
    "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Library/CoreSimulator/Profiles/DeviceTypes/*.simdevicetype",
    os.path.expanduser("~/Library/Developer/CoreSimulator/Profiles/DeviceTypes/*.simdevicetype")
]

# 2. Percorso di output: parte dalla cartella principale del progetto (dove si trova questo script)
PROJECT_ROOT = Path(__file__).resolve().parent
OUTPUT_SWIFT_FILE = PROJECT_ROOT / "Sources" / "CustomSheet" / "Utilities" / "DeviceCornerRadii.swift"

devices_data = {} # { model_id: (radius, displays, device_name) }

def extract_displays(capabilities, fallback_radius):
    integrated = [
        d for d in capabilities.get("displays", [])
        if d.get("displayType") == "integrated"
    ]
    if not integrated:
        r = float(fallback_radius)
        return [(r, r, r, r, r)]

    result = []
    for idx, d in enumerate(integrated):
        tl = float(d.get("cornerRadiusUL", fallback_radius))
        tr = float(d.get("cornerRadiusUR", fallback_radius))
        bl = float(d.get("cornerRadiusLL", fallback_radius))
        br = float(d.get("cornerRadiusLR", fallback_radius))
        if idx == 0 and "DeviceCornerRadius" in capabilities:
            main = float(capabilities["DeviceCornerRadius"])
        else:
            main = max(tl, tr, bl, br)
        result.append((main, tl, tr, bl, br))
    return result

for pattern in SEARCH_PATHS:
    for bundle_path in glob.glob(pattern):
        device_name = Path(bundle_path).stem
        
        # Filtra solo iPhone, iPad e iPod touch
        if not (device_name.startswith("iPhone") or device_name.startswith("iPad") or device_name.startswith("iPod")):
            continue

        cap_plist_path = os.path.join(bundle_path, "Contents", "Resources", "capabilities.plist")
        prof_plist_path = os.path.join(bundle_path, "Contents", "Resources", "profile.plist")

        if not os.path.exists(cap_plist_path):
            continue

        try:
            with open(cap_plist_path, "rb") as f:
                cap_data = plistlib.load(f)
            
            capabilities = cap_data.get("capabilities", {})
            radius = capabilities.get("DeviceCornerRadius", 0.0)
            displays = extract_displays(capabilities, radius)
            primary_id = capabilities.get("modelIdentifier")

            model_ids = set()
            if primary_id:
                model_ids.add(primary_id)

            if os.path.exists(prof_plist_path):
                with open(prof_plist_path, "rb") as pf:
                    prof_data = plistlib.load(pf)
                    if "modelIdentifier" in prof_data:
                        model_ids.add(prof_data["modelIdentifier"])
                    for rep_id in prof_data.get("representedModelIdentifiers", []):
                        model_ids.add(rep_id)

            for m_id in model_ids:
                devices_data[m_id] = (float(radius), displays, device_name)

        except Exception as e:
            print(f"Errore lettura {device_name}: {e}")

# 3. Creazione della cartella Utilities (se non esiste) e scrittura del file Swift
OUTPUT_SWIFT_FILE.parent.mkdir(parents=True, exist_ok=True)

with open(OUTPUT_SWIFT_FILE, "w", encoding="utf-8") as out:
    out.write("// File generato automaticamente da generate_radii.py\n")
    out.write("// Non modificare manualmente.\n\n")
    out.write("//  Copyright (C) 2026 Leonardo Rossi\n")
    out.write("//  SPDX-License-Identifier: GPL-3.0-or-later\n\n")
    out.write("import CoreGraphics\n\n")
    out.write("enum DeviceCornerRadii {\n")
    out.write("    static let all: [String: CGFloat] = [\n")
    
    for model_id in sorted(devices_data.keys()):
        radius, _, name = devices_data[model_id]
        out.write(f'        "{model_id}": {radius}, // {name}\n')
        
    out.write("    ]\n\n")
    out.write("    static let displays: [String: [DeviceDisplayCornerRadii]] = [\n")

    for model_id in sorted(devices_data.keys()):
        _, displays, name = devices_data[model_id]
        entries = ", ".join(
            f"DeviceDisplayCornerRadii(main: {main}, tl: {tl}, tr: {tr}, bl: {bl}, br: {br})"
            for main, tl, tr, bl, br in displays
        )
        out.write(f'        "{model_id}": [{entries}], // {name}\n')

    out.write("    ]\n")
    out.write("}\n")

print(f"✅ Generati {len(devices_data)} modelli in: {OUTPUT_SWIFT_FILE.relative_to(PROJECT_ROOT)}")
