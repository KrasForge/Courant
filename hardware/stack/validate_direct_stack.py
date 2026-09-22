#!/usr/bin/env python3
"""Validate the physical/electrical RADIAN panel-to-mainboard direct stack.

Checks both 20-pin connectors pin-by-pin (40 contacts total), including:
- exact Samtec MPN and board side,
- manufacturer-recommended hole diameters,
- product-space XY coincidence for every physical pin,
- pin-number and net-name coincidence (no row reversal / pin swap),
- attached drawing-derived 3D reference models,
- -06/-01 mated board gap, insertion and wipe,
- through-hole tail protrusion through 1.6 mm PCBs.
"""
from pathlib import Path
import json, math
import pcbnew

ROOT = Path(__file__).resolve().parents[1]
STACK = json.loads((ROOT/'stack/panel-stack.json').read_text())
PANEL = ROOT/'panel/design/radian_panel.kicad_pcb'
MAIN = ROOT/'courant/deliverables/courant.kicad_pcb'
OUT = ROOT/'stack/direct-stack-validation.json'

EXPECTED = {
    'fully_mated_gap_mm': 19.99,
    'max_gap_mm': 20.45,
    'fully_mated_wipe_mm': 0.84,
    'min_wipe_at_max_gap_mm': 0.38,
    'main_insulation_height_mm': 15.30,
    'main_tail_mm': 2.35,
    'main_hole_mm': 1.02,
    'panel_height_mm': 8.51,
    'panel_tail_mm': 2.54,
    'panel_hole_mm': 1.04,
    'pcb_thickness_mm': 1.6,
}
MODEL_REL = {
    'main': '${KIPRJMOD}/../../stack/models/Samtec_IPT1-110-06-L-D_drawing_reference.step',
    'panel': '${KIPRJMOD}/../../stack/models/Samtec_IPS1-110-01-L-D_drawing_reference.step',
}


def mm(v):
    return pcbnew.ToMM(v)


def product_xy(kind, pos):
    x, y = mm(pos.x), mm(pos.y)
    if kind == 'panel':
        return x, 128.5 - y
    if kind == 'main':
        return x - 12.0, 164.25 - y
    raise ValueError(kind)


def fp_by_ref(board, ref):
    return next(f for f in board.GetFootprints() if f.GetReference() == ref)


def pad_map(fp):
    return {p.GetNumber(): p for p in fp.Pads()}


def model_names(fp):
    return [m.m_Filename for m in fp.Models() if m.m_Show]


def drill_mm(pad):
    d = pad.GetDrillSize()
    return round(mm(d.x), 4), round(mm(d.y), 4)


def close(a,b,tol=1e-4):
    return abs(a-b) <= tol


def main():
    pb = pcbnew.LoadBoard(str(PANEL))
    mb = pcbnew.LoadBoard(str(MAIN))
    report = {
        'status':'PASS',
        'sources': {
            'stack_contract': str((ROOT/'stack/panel-stack.json').relative_to(ROOT)),
            'panel_board': str(PANEL.relative_to(ROOT)),
            'main_board': str(MAIN.relative_to(ROOT)),
            'manufacturer_drawings': [
                'Samtec IPT1-1XX-XX-XX-D-XX Rev AA',
                'Samtec IPS1-1XX-XX-XX-D-XX Rev S',
                'Samtec IPX1 MATED DOCUMENT Rev C',
                'Samtec IPT1 and IPS1 recommended through-hole PCB layouts',
            ],
        },
        'pairs': [],
        'mechanical': {},
        'errors': [],
    }

    main_spec = STACK['connector_footprint']['main']
    panel_spec = STACK['connector_footprint']['panel']

    # Contract-vs-drawing constants.
    mechanical = report['mechanical']
    mechanical['fully_mated_gap_mm'] = STACK['mating']['fully_mated_gap_mm']
    mechanical['max_gap_mm'] = STACK['mating']['max_gap_mm']
    mechanical['fully_mated_wipe_mm'] = STACK['mating']['fully_mated_wipe_mm']
    mechanical['min_wipe_at_max_gap_mm'] = STACK['mating']['min_wipe_at_max_gap_mm']
    mechanical['main_insulation_height_mm'] = main_spec['insulation_height_mm']
    mechanical['panel_height_mm'] = panel_spec['body_height_mm']
    mechanical['nominal_geometric_insertion_mm'] = round(
        main_spec['insulation_height_mm'] + panel_spec['body_height_mm'] -
        STACK['mating']['fully_mated_gap_mm'], 3)
    mechanical['geometric_insertion_at_max_gap_mm'] = round(
        main_spec['insulation_height_mm'] + panel_spec['body_height_mm'] -
        STACK['mating']['max_gap_mm'], 3)
    mechanical['panel_tail_protrusion_past_opposite_face_mm'] = round(
        panel_spec['post_tail_mm'] - EXPECTED['pcb_thickness_mm'], 3)
    mechanical['main_tail_protrusion_past_opposite_face_mm'] = round(
        main_spec['post_tail_mm'] - EXPECTED['pcb_thickness_mm'], 3)
    # Panel F surface is 8 mm behind the faceplate rear in the active CAD.
    mechanical['panel_tail_to_faceplate_rear_clearance_mm'] = round(
        8.0 - mechanical['panel_tail_protrusion_past_opposite_face_mm'], 3)

    checks = [
        ('fully_mated_gap_mm', EXPECTED['fully_mated_gap_mm']),
        ('max_gap_mm', EXPECTED['max_gap_mm']),
        ('fully_mated_wipe_mm', EXPECTED['fully_mated_wipe_mm']),
        ('min_wipe_at_max_gap_mm', EXPECTED['min_wipe_at_max_gap_mm']),
        ('main_insulation_height_mm', EXPECTED['main_insulation_height_mm']),
        ('panel_height_mm', EXPECTED['panel_height_mm']),
    ]
    for key, expected in checks:
        if not close(mechanical[key], expected):
            report['errors'].append(f'{key}: {mechanical[key]} != manufacturer {expected}')

    for con in STACK['connectors']:
        mf = fp_by_ref(mb, con['main_ref'])
        pf = fp_by_ref(pb, con['panel_ref'])
        pair = {
            'id': con['id'],
            'main_ref': con['main_ref'],
            'panel_ref': con['panel_ref'],
            'main_value': mf.GetValue(),
            'panel_value': pf.GetValue(),
            'main_side': 'B' if mf.GetLayer()==pcbnew.B_Cu else 'F',
            'panel_side': 'B' if pf.GetLayer()==pcbnew.B_Cu else 'F',
            'main_models': model_names(mf),
            'panel_models': model_names(pf),
            'pins': [],
        }

        if mf.GetValue() != main_spec['mpn']:
            report['errors'].append(f"{con['main_ref']} MPN {mf.GetValue()} != {main_spec['mpn']}")
        if pf.GetValue() != panel_spec['mpn']:
            report['errors'].append(f"{con['panel_ref']} MPN {pf.GetValue()} != {panel_spec['mpn']}")
        if pair['main_side'] != 'F':
            report['errors'].append(f"{con['main_ref']} must be on mainboard F side")
        if pair['panel_side'] != 'B':
            report['errors'].append(f"{con['panel_ref']} must be on panel B side")
        if MODEL_REL['main'] not in pair['main_models']:
            report['errors'].append(f"{con['main_ref']} exact stack reference model missing")
        if MODEL_REL['panel'] not in pair['panel_models']:
            report['errors'].append(f"{con['panel_ref']} exact stack reference model missing")

        main_center = product_xy('main', mf.GetPosition())
        panel_center = product_xy('panel', pf.GetPosition())
        contract_main_center = (
            STACK['mainboard_product_offset_mm']['x'] + con['main_xy_mm']['x'],
            STACK['mainboard_product_offset_mm']['y'] + con['main_xy_mm']['y'])
        contract_panel_center = (con['panel_xy_mm']['x'], con['panel_xy_mm']['y'])
        pair['main_center_product_mm'] = [round(x,4) for x in main_center]
        pair['panel_center_product_mm'] = [round(x,4) for x in panel_center]
        pair['contract_center_product_mm'] = [round(x,4) for x in contract_panel_center]

        for a,b,label in [
            (main_center, panel_center, 'native board connector centers'),
            (main_center, contract_main_center, 'main native vs stack contract'),
            (panel_center, contract_panel_center, 'panel native vs stack contract'),
            (contract_main_center, contract_panel_center, 'stack contract main vs panel')]:
            if math.dist(a,b) > 1e-4:
                report['errors'].append(f"{con['id']} {label} mismatch: {a} vs {b}")

        mp = pad_map(mf); pp = pad_map(pf)
        if set(mp) != {str(i) for i in range(1,21)}:
            report['errors'].append(f"{con['main_ref']} does not contain pins 1..20 exactly")
        if set(pp) != {str(i) for i in range(1,21)}:
            report['errors'].append(f"{con['panel_ref']} does not contain pins 1..20 exactly")

        for n in range(1,21):
            key=str(n); m=mp[key]; p=pp[key]
            mxy=product_xy('main',m.GetPosition())
            pxy=product_xy('panel',p.GetPosition())
            mn=m.GetNetname(); pn=p.GetNetname()
            md=drill_mm(m); pd=drill_mm(p)
            rec={
                'pin':n,
                'net':mn,
                'main_product_xy_mm':[round(v,4) for v in mxy],
                'panel_product_xy_mm':[round(v,4) for v in pxy],
                'xy_error_mm':round(math.dist(mxy,pxy),6),
                'main_drill_mm':md,
                'panel_drill_mm':pd,
                'net_match':mn==pn,
            }
            pair['pins'].append(rec)
            if math.dist(mxy,pxy)>1e-4:
                report['errors'].append(f"{con['id']} pin {n} physical XY mismatch {mxy} vs {pxy}")
            if mn != pn:
                report['errors'].append(f"{con['id']} pin {n} net mismatch {mn} vs {pn}")
            if not (close(md[0],EXPECTED['main_hole_mm']) and close(md[1],EXPECTED['main_hole_mm'])):
                report['errors'].append(f"{con['main_ref']} pin {n} drill {md} != 1.02 mm")
            if not (close(pd[0],EXPECTED['panel_hole_mm']) and close(pd[1],EXPECTED['panel_hole_mm'])):
                report['errors'].append(f"{con['panel_ref']} pin {n} drill {pd} != 1.04 mm")

        pair['matched_pins'] = sum(1 for p in pair['pins'] if p['xy_error_mm']==0 and p['net_match'])
        report['pairs'].append(pair)

    # Ensure model files themselves exist.
    for rel in [
        ROOT/'stack/models/Samtec_IPT1-110-06-L-D_drawing_reference.step',
        ROOT/'stack/models/Samtec_IPS1-110-01-L-D_drawing_reference.step']:
        if not rel.exists() or rel.stat().st_size < 1000:
            report['errors'].append(f'missing/empty reference model: {rel}')

    report['total_contacts_checked'] = sum(len(p['pins']) for p in report['pairs'])
    report['total_contacts_matched'] = sum(p['matched_pins'] for p in report['pairs'])
    if report['errors']:
        report['status']='FAIL'

    OUT.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({
        'status':report['status'],
        'contacts':f"{report['total_contacts_matched']}/{report['total_contacts_checked']}",
        'nominal_insertion_mm':mechanical['nominal_geometric_insertion_mm'],
        'max_gap_insertion_mm':mechanical['geometric_insertion_at_max_gap_mm'],
        'panel_tail_faceplate_clearance_mm':mechanical['panel_tail_to_faceplate_rear_clearance_mm'],
        'errors':report['errors'],
        'report':str(OUT),
    },indent=2))
    if report['errors']:
        raise SystemExit(1)


if __name__=='__main__':
    main()
