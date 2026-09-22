#!/usr/bin/env python3
"""Attach drawing-derived Samtec stack models to both native KiCad boards/libraries."""
from pathlib import Path
import pcbnew

ROOT = Path(__file__).resolve().parents[1]
MODEL_BASE = '${KIPRJMOD}/../../stack/models/'
IPT_MODEL = MODEL_BASE + 'Samtec_IPT1-110-06-L-D_drawing_reference.step'
IPS_MODEL = MODEL_BASE + 'Samtec_IPS1-110-01-L-D_drawing_reference.step'

PANEL_BOARD = ROOT/'panel/design/radian_panel.kicad_pcb'
MAIN_BOARD = ROOT/'courant/deliverables/courant.kicad_pcb'
PANEL_LIB = ROOT/'panel/library/RadianPanel.pretty'
MAIN_LIB = ROOT/'courant/deliverables/RadianMain.pretty'
FP_NAME = 'Stack_2x10_P2.54'


def set_single_model(fp, filename):
    models = fp.Models()
    models.clear()
    m = pcbnew.FP_3DMODEL()
    m.m_Filename = filename
    m.m_Show = True
    m.m_Opacity = 1.0
    m.m_Scale.x = m.m_Scale.y = m.m_Scale.z = 1.0
    m.m_Offset.x = m.m_Offset.y = m.m_Offset.z = 0.0
    m.m_Rotation.x = m.m_Rotation.y = m.m_Rotation.z = 0.0
    models.append(m)


def update_board(path, refs, filename, expected_value):
    b = pcbnew.LoadBoard(str(path))
    by_ref = {f.GetReference():f for f in b.GetFootprints()}
    for ref in refs:
        fp = by_ref[ref]
        if fp.GetValue() != expected_value:
            raise RuntimeError(f'{path}: {ref} value {fp.GetValue()} != {expected_value}')
        set_single_model(fp, filename)
    pcbnew.SaveBoard(str(path), b, True)


def update_library(lib, filename, expected_value):
    fp = pcbnew.FootprintLoad(str(lib), FP_NAME)
    if fp is None:
        raise RuntimeError(f'cannot load {lib}:{FP_NAME}')
    fp.SetValue(expected_value)
    set_single_model(fp, filename)
    pcbnew.FootprintSave(str(lib), fp)


def main():
    update_board(PANEL_BOARD, ['J100','J101'], IPS_MODEL, 'IPS1-110-01-L-D')
    update_board(MAIN_BOARD, ['J17','J18'], IPT_MODEL, 'IPT1-110-06-L-D')
    update_library(PANEL_LIB, IPS_MODEL, 'IPS1-110-01-L-D')
    update_library(MAIN_LIB, IPT_MODEL, 'IPT1-110-06-L-D')
    print('attached stack reference models:')
    print(' panel J100/J101 ->', IPS_MODEL)
    print(' main  J17/J18   ->', IPT_MODEL)


if __name__ == '__main__':
    main()
