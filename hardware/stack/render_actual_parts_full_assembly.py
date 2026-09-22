#!/usr/bin/env python3
"""Compatibility entry point for the final actual-part assembly views.

The old implementation rebuilt the full assembly from stale *-raw.step groups,
which could reintroduce old U8 geometry and default-white compound colors.
The canonical CAD is now built by render_actual_part_cad.py and this entry point
renders that color-persistent STEP directly.
"""
from pathlib import Path
import runpy
HERE=Path(__file__).resolve().parent
runpy.run_path(str(HERE/'render_final_actual_assembly_views.py'),run_name='__main__')
