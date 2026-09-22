"""RADIAN Panel P1, explicit electrical graph + panel-coordinate placement.
Units mm. x right, y UP as seen from front. z=0 panel rear; PCB front=-8.
Not a fabrication release. All declared BOM selections require purchasing review.
"""
from __future__ import annotations
from pathlib import Path
import math, json, csv, uuid
ROOT=Path(__file__).resolve().parents[1]
H=128.5
STACK=json.loads((ROOT.parent/'stack'/'panel-stack.json').read_text())
NS=uuid.UUID('7cfa5422-3a38-4c31-a2d2-e3ea799ebfff')
def uid(s): return str(uuid.uuid5(NS,str(s)))
PARTS=[]
def pad(n,x,y,sx=1.8,sy=1.8,drill=1.0,kind='thru_hole',shape='circle',name=None):
 return dict(n=str(n),x=x,y=y,sx=sx,sy=sy,drill=drill,kind=kind,shape=shape,name=str(name or n))
def sm(n,x,y,sx,sy,name=None):return pad(n,x,y,sx,sy,None,'smd','roundrect',name)
def fp(pads,body,h,name):return dict(pads=pads,body=body,height=h,name=name)
def header(n,rows=1):
 if rows==1:
  return fp([pad(i+1,(i-(n-1)/2)*2.54,0,shape='rect' if i==0 else 'circle') for i in range(n)], [n*2.54,2.54],8.5,f'Header_1x{n:02d}_P2.54')
 return fp([pad(i+1,(-1.27 if i%2==0 else 1.27),((n/2-1)/2-i//2)*2.54,shape='rect' if i==0 else 'circle') for i in range(n)],[8.9,n/2*2.54+5.3],9.2,f'IDC_2x{n//2:02d}_P2.54_Shrouded')
def exact_2pin(ref):
 # Molex KK-254 22-27-2021, centered between pins. B-side transform gives
 # physical pin 1 at +1.27 mm and pin 2 at -1.27 mm, matching native routing.
 return fp([pad(1,-1.27,0,1.6,1.6,1.1,shape='rect'),pad(2,1.27,0,1.6,1.6,1.1)],[5.3,6.02],8.0,f'Molex_22-27-2021_{ref}_B')
def exact_6pin():
 return fp([pad(i+1,(i-2.5)*2.54,0,1.6,1.6,1.1,shape='rect' if i==0 else 'circle') for i in range(6)],[15.24,5.8],11.7,'Molex_22-27-2061_J202_B')
def exact_eurorack_header():
 return fp([pad(i+1,(-1.27 if i%2==0 else 1.27),((10/2-1)/2-i//2)*2.54,1.65,1.65,1.1,shape='rect' if i==0 else 'circle') for i in range(10)],[9.85,21.36],12.1,'Wurth_61201021621_Exact_B')
def exact_mod_switch():
 # Wurth 450301014042 actual pinout: pin 1 COM, pin 2 throw A, pin 3 throw B.
 # On B side: physical positions are 1=center, 2=-2.54, 3=+2.54 in product XY.
 return fp([pad(1,0,0,1.3,1.3,.8,shape='rect'),pad(2,2.54,0,1.3,1.3,.8),pad(3,-2.54,0,1.3,1.3,.8)],[10.5,3.0],6.4,'Wurth_450301014042_Exact_B')
def stack_header(panel_bottom=False):
 pitch=STACK['connector_footprint']['pitch_mm']; row=STACK['connector_footprint']['row_spacing_mm']
 spec=STACK['connector_footprint']['panel']
 hole=spec['hole_mm']; dia=STACK['connector_footprint']['pad_diameter_mm']
 pads=[]
 for i in range(20):
  x=(-row/2 if i%2==0 else row/2); y=(4.5-i//2)*pitch
  if panel_bottom:x=-x  # cancel B-side footprint mirroring in product XY
  pads.append(pad(i+1,x,y,dia,dia,hole,shape='rect' if i==0 else 'circle'))
 body=spec['body_mm']
 return fp(pads,[body['x'],body['y']],spec['body_height_mm'],'Stack_2x10_P2.54')

def chip2(name='R_0603',size='0603'):
 dims={'0603':(.825,.85,.95,1.6,.8,.6),'0805':(1.05,1.15,1.4,2.,1.25,1.0),'1206':(1.5,1.3,1.8,3.2,1.6,1.1),'1210':(1.65,1.5,2.9,3.2,2.5,2.5),'SMA':(2.25,2.0,2.4,4.6,2.6,2.4),'SMB':(2.7,2.2,2.8,5.4,3.6,2.6)}
 d,sx,sy,bx,by,h=dims[size]
 return fp([sm(1,-d,0,sx,sy),sm(2,d,0,sx,sy)],[bx,by],h,name)
def resistor(ref,val,x,y,n1,n2,angle=0,side='F',block='power',tol='1%',size='0603',mpn=''):
 return add(ref,val,x,y,chip2('R_'+size,size),{'1':n1,'2':n2},side,angle,block,mpn=mpn or 'SELECT '+val+' '+tol+' '+size,notes='Resistor '+tol)
def capacitor(ref,val,x,y,n1,n2='GND',angle=0,side='F',block='power',size='0603',rating='25V',mpn=''):
 return add(ref,val,x,y,chip2('C_'+size,size),{'1':n1,'2':n2},side,angle,block,mpn=mpn or 'SELECT '+val+' '+rating+' '+size,notes=rating+'; verify effective capacitance at DC bias')
def add(ref,value,x,y,footprint,nets,side='F',angle=0,block='controls',mpn='',maker='',notes='',dnp=False):
 ps={str(k):v for k,v in nets.items()}
 p=dict(ref=ref,value=value,x=x,y=y,fp=footprint,nets=ps,side=side,angle=angle,block=block,mpn=mpn or value,maker=maker,notes=notes,dnp=dnp,uuid=uid(ref))
 assert not any(q['ref']==ref for q in PARTS),ref
 assert set(ps)<=set(q['n'] for q in footprint['pads']),ref
 PARTS.append(p);return p

def transformed(p,pt):
 x=pt['x']*(-1 if p['side']=='B' else 1);y=pt['y'];a=math.radians(p['angle'])
 return (p['x']+x*math.cos(a)-y*math.sin(a),p['y']+x*math.sin(a)+y*math.cos(a))
def allpads():
 out=[]
 for p in PARTS:
  for q in p['fp']['pads']:
   x,y=transformed(p,q);ang=p['angle']
   out.append(dict(q,ref=p['ref'],net=p['nets'].get(q['n']),X=round(x,6),Y=round(y,6),side=p['side'],angle=ang,uuid=uid(f"pad:{p['ref']}:{q['n']}")))
 return out

# Outline includes side-column reliefs. Windows remove the DIN support and leave vent clear.
OUTLINE=[(18,10),(162.5,10),(162.5,19.5),(171.5,19.5),(171.5,10),(198.5,10),(198.5,118),(171.5,118),(171.5,109),(162.5,109),(162.5,118),(18,118)]
WINDOWS=[[(61,25),(109,25),(109,61),(61,61)],[(116.5,35.5),(149.5,35.5),(149.5,48.5),(116.5,48.5)]]
MOUNTS=[(25,73,2.7),(135,73,2.7),(25,97,2.7),(135,97,2.7),(176.5,15.5,2.7),(196.5,15.5,2.7),(176.5,112.5,2.7),(196.5,112.5,2.7),(24,14,2.7),(55,14,2.7)]

# Legacy cable map is retained only for equivalence/service-reference checks.
# J101..J116 are no longer instantiated: two direct board-to-board stack
# connectors below replace all sixteen mainboard harnesses.
MAP={
 1:['VIN5','GND'],2:['V3V3','GND','JTAG_TCK','JTAG_TDO','JTAG_TDI','JTAG_TMS'],
 3:['PROGRAM_B','GND'],4:['reset_n','GND'],5:['LINE_L','GND','LINE_R'],
 6:['VREF25','POT_PITCH_RAW','GND'],7:['VREF25','POT_DECAY_RAW','GND'],8:['VREF25','POT_TIMBRE_RAW','GND'],
 9:['ENC_A_RAW','GND','ENC_B_RAW','ENC_SW_RAW','GND'],10:['V3V3','cv_select','GND'],
 11:['GND','LED0_A','LED1_A','LED2_A','LED3_A'],12:['PITCH_IN','GND'],13:['MOD_IN','GND'],14:['GATE_IN','GND'],15:['MIDI4','MIDI5'],
 16:['VREF25','POT_DRIVE_RAW','POT_DELAY_RAW','POT_REVERB_RAW','GND']}

for con in STACK['connectors']:
 x=con['panel_xy_mm']['x']; y=con['panel_xy_mm']['y']
 add(con['panel_ref'],STACK['connector_footprint']['panel']['mpn'],x,y,stack_header(True),
     {str(i+1):net for i,net in enumerate(con['signals'])},'B',con['rotation_deg'],
     block='controls' if con['id']=='A' else 'service',
     mpn=STACK['connector_footprint']['panel']['mpn'], maker=STACK['connector_footprint']['panel']['manufacturer'],
     notes=(f"Direct mezzanine {con['id']}; Samtec IPS1 socket mates mainboard IPT1-110-06-L-D. "
            f"Fully-mated PCB gap {STACK['mating']['fully_mated_gap_mm']} mm; max {STACK['mating']['max_gap_mm']} mm. "
            f"Use ~{STACK['mating']['assembly_standoff_target_mm']} mm standoffs and bench-verify seating before production quantity."))

# Six rear-facing bushingless pots in a two-tier performance layout.
# Large-knob primary row: TENSION / DECAY / CHAOS.
# Small-knob FX row: DRIVE / DELAY / REVERB.
# Knob diameter is an enclosure/assembly choice; all six use the same PCB pot footprint.
potfp=fp([pad(1,-2.5,-7),pad(2,0,-7),pad(3,2.5,-7),pad('MP1',-5.3,0,2.8,3.2,[1.8,2.2],shape='oval'),pad('MP2',5.3,0,2.8,3.2,[1.8,2.2],shape='oval')],[11.4,11.],7.4,'Bourns_PTV09A4_RearFacing')
pots=[(38,96,'POT_PITCH_RAW','TENSION'),(76,96,'POT_DECAY_RAW','DECAY'),(114,96,'POT_TIMBRE_RAW','CHAOS'),
      (66,70,'POT_DRIVE_RAW','DRIVE'),(88,70,'POT_DELAY_RAW','DELAY'),(110,70,'POT_REVERB_RAW','REVERB')]
for i,(x,y,net,label) in enumerate(pots,1):
 add('RV'+str(i),'10k linear / '+label,x,y,potfp,{'1':'GND','2':net,'3':'VREF25','MP1':None,'MP2':None},mpn='PTV09A-4020F-B103',maker='Bourns',notes='Pin 1 CCW/GND, pin 3 CW/VREF25: verify direction on physical sample. No added wiper RC. Mount tabs soldered, electrically NC.')
encfp=fp([pad('A',-2.5,-7.5),pad('C',0,-7.5),pad('B',2.5,-7.5),pad('S1',-2.5,7),pad('S2',2.5,7),pad('MP1',-6.6,0,2.8,3.6,[1.8,2.6],shape='oval'),pad('MP2',6.6,0,2.8,3.6,[1.8,2.6],shape='oval')],[14,16],6.5,'Bourns_PEC11R4_RearFacing_Switch')
add('ENC1','24 PPR / PUSH',42,43,encfp,{'A':'ENC_A_RAW','B':'ENC_B_RAW','C':'GND','S1':'ENC_SW_RAW','S2':'GND','MP1':None,'MP2':None},mpn='PEC11R-4220F-S0024',maker='Bourns',notes='20 mm shaft / 7 mm bushing replaces proposed 15 mm shaft part to accommodate common PCB plane. Check encoder direction and nut stack.')
swfp=fp([pad(1,0,-4.7,2.8,2.8,1.85),pad(2,0,0,2.8,2.8,1.85),pad(3,0,4.7,2.8,2.8,1.85)],[6.86,12.7],8.89,'E_Switch_100SP_M2')
add('SW1','MODE / SPDT ON-ON',150.5,84.5,swfp,{'1':'GND','2':'cv_select','3':'V3V3'},mpn='100SP1T1B1M2REH',maker='E-Switch',notes='Gold contact option for low-level logic. ST110001 mechanical M2 pattern, 4.7 mm pitch. R contact selection from manufacturer configurator; purchase/stack validation required.')
ledfp=fp([pad(1,-1.27,0,1.6,1.6,.9),pad(2,1.27,0,1.6,1.6,.9)],[3.8,3.8],12.5,'LED_D3.0_P2.54')
for i,x in enumerate([124,134,144,154]):
 add('D'+str(10+i),'VOICE '+str(i+1),x,108,ledfp,{'1':'GND','2':f'LED{i}_A'},mpn='L-934GD',maker='Kingbright',notes='3 mm LED, anode pad 2, cathode pad 1. Mainboard already has series resistor. Set flange height with assembly jig; envelope is not seated LED height.')

# Five vertical PJ398SM / WQP518MA mono jacks. Under-barrel clearance hole mandatory.
jackfp=fp([pad(1,0,-6.48,2.3,2.6,[1.0,1.9],shape='oval',name='SLEEVE'),pad(2,0,-3.38,2.3,2.6,[1.0,1.9],shape='oval',name='NORMAL'),pad(3,0,4.92,2.3,2.6,[1.0,1.9],shape='oval',name='TIP'),pad('',0,0,3,3,3,'np_thru_hole','circle')],[9,10.5],9,'WQP518MA_PJ398SM_Vertical')
for ref,y,net,lab in [('J301',99,'PITCH_IN','PITCH 0-5V'),('J302',81,'MOD_RAW','MOD'),('J303',63,'GATE_IN','GATE'),('J304',45,'LINE_L','LINE L'),('J305',27,'LINE_R','LINE R')]:
 add(ref,lab,186.5,y,jackfp,{'1':'GND','2':('GND' if ref in ['J301','J302','J303'] else None),'3':net},block='io',mpn='WQP518MA (Thonkiconn/PJ398SM)',maker='QingPu / Thonk',notes='Vertical mono, grounded normal for inputs only. Sleeve=1, switched contact=2, tip=3. Imported supplier dimension drawing needs sample fit check.')
add('J306','22-27-2021',57.5,39,exact_2pin('J306'),{'1':'MIDI4','2':'MIDI5'},'B',block='io',mpn='22-27-2021',maker='Molex',notes='Exact KK-254 2-circuit friction-lock header to retained Same Sky SDS-50J MIDI DIN pins 4 and 5. No DIN 2/shield-to-GND connection.')

# Rack +12 V and desktop 12 V inputs. Never use bus -12 V or +5 V pins.
racknets={str(i):('GND' if i in range(3,9) else 'RACK_12V' if i in [9,10] else None) for i in range(1,11)}
add('J200','61201021621',174,64,exact_eurorack_header(),racknets,'B',block='power',mpn='61201021621',maker='Wurth Elektronik',notes='Exact keyed WR-BHD 2x5 2.54 mm header. Module-side 10-pin: 1/2=-12 NC, 3-8=GND, 9/10=+12. Use 16-to-10 cable to bus. Red stripe at pins 1/2; verify both cable ends. No bus +5/CV/gate connections.')
add('J201','22-27-2021',26,52,exact_2pin('J201'),{'1':'DESKTOP_12V','2':'GND'},'B',block='power',mpn='22-27-2021',maker='Molex',notes='Exact KK-254 2-circuit friction-lock header from the chassis-mounted 12 V DC inlet. NOT a 5 V inlet.')
for ref,x,y,a,b in [('F1',53,65,'RACK_12V','RACK_FUSED'),('F2',26,59,'DESKTOP_12V','DESKTOP_FUSED')]:
 add(ref,'2A FUSE / >=32V',x,y,chip2('Fuse_1206','1206'),{'1':a,'2':b},block='power',mpn='SELECT 2 A >=32 V 1206 fuse',notes='Final fuse MPN, surge rating, derating and TVS coordination are an explicit release gate.')
for ref,x,y,a in [('D1',44,65,'RACK_FUSED'),('D2',35,59,'DESKTOP_FUSED')]:
 add(ref,'SS54 / OR',x,y,chip2('D_SMB','SMB'),{'1':'VRAW','2':a},block='power',mpn='SS54-E3/57T',maker='Vishay',notes='Pad 1 cathode VRAW, pad 2 anode fused source. Diode OR, no priority, shared ground. Measure worst-case diode temperature.')
add('D3','SMBJ15A',25,46,chip2('D_SMB','SMB'),{'1':'VRAW','2':'GND'},block='power',mpn='SMBJ15A-E3/52',maker='Vishay',notes='Unidirectional input TVS. Verify source fault energy and fuse coordination before any fault test.')
# TPS54302 topology follows TI 5V/3A application. Footprint top-view pin numbering.
tpsfp=fp([sm(1,-1.1,.95,1.0,.6,'GND'),sm(2,-1.1,0,1.,.6,'SW'),sm(3,-1.1,-.95,1.,.6,'VIN'),sm(4,1.1,-.95,1.,.6,'FB'),sm(5,1.1,0,1.,.6,'EN'),sm(6,1.1,.95,1.,.6,'BOOT')],[1.6,2.9],1.1,'TI_DDC0006A_SOT23_6')
add('U1','TPS54302DDCR',34,25,tpsfp,{'1':'GND','2':'SW','3':'VRAW','4':'FB','5':'EN','6':'BOOT'},block='power',mpn='TPS54302DDCR',maker='Texas Instruments',notes='3 A IC rating is a design target, not validated system delivery. TI March 2026 datasheet 5 V reference circuit.')
indfp=fp([sm(1,-2.95,0,2.5,3.5),sm(2,2.95,0,2.5,3.5)],[7.3,6.6],5.,'Bourns_SRP7050TA')
add('L1','10uH 4A / Isat7.5A',26,25,indfp,{'1':'VIN5','2':'SW'},block='power',mpn='SRP7050TA-100M',maker='Bourns',notes='4 A Irms / 7.5 A Isat at stated datasheet conditions; temperature rise needs testing.')
capacitor('C1','10uF',31,18,'VRAW',size='1210',rating='50V X7R')
capacitor('C2','100nF',32,21.5,'VRAW',angle=270,rating='50V X7R')
capacitor('C3','100nF',34,29,'BOOT','SW',rating='16V X7R')
capacitor('C4','22uF',23,33,'VIN5',angle=90,size='1210',rating='25V X7R')
capacitor('C5','22uF',29,33,'VIN5',angle=90,size='1210',rating='25V X7R')
resistor('R1','100k',39.5,27,'FF_TOP','FB')
resistor('R2','13.3k',39,20,'FB','GND')
resistor('R3','511k',46,23,'VRAW','EN',angle=90)
resistor('R4','105k',43,19,'EN','GND')
resistor('R5','49.9',39,32,'VIN5','FF_TOP')
capacitor('C6','75pF',43,27,'FF_TOP','FB',rating='50V C0G')
capacitor('C7','10uF',43,59,'VRAW',size='1210',rating='50V X7R')

# Optional bipolar MOD: Vout = 0.5*Vin + buffered mainboard VREF25.
# Default shunt 1-2 bypasses this stage; no default firmware/voltage convention change.
add('JP1','450301014042',165.5,88,exact_mod_switch(),{'1':'MOD_IN','2':'MOD_BIPOLAR','3':'MOD_RAW'},'B',block='mod',mpn='450301014042',maker='Wurth Elektronik',notes='Actual SPDT configuration switch replaces the removable shunt. One throw selects direct unipolar MOD_RAW; the other selects MOD_BIPOLAR. NOT the front MODE switch.')
opafp=fp([sm(i,-2.7,(2.5-i)*1.27,1.55,.6,n) for i,n in enumerate(['OUTA','INA-','INA+','V-'],1)]+[sm(i,2.7,(i-6.5)*1.27,1.55,.6,n) for i,n in zip(range(5,9),['INB+','INB-','OUTB','V+'])],[3.9,4.9],1.75,'SOIC8_3.9x4.9_P1.27')
add('U2','OPA2192ID',151,67,opafp,{'1':'VREF_BUF','2':'VREF_BUF','3':'VREF25','4':'GND','5':'MOD_SUM','6':'MOD_FB','7':'MOD_BIPOLAR','8':'VIN5'},block='mod',mpn='OPA2192ID',maker='Texas Instruments',notes='A buffers VREF25. B is non-inverting gain 2. 5 V single supply, output headroom limits rail endpoints; not rail-perfect mapping.')
resistor('R20','200k',164,75,'MOD_RAW','MOD_SUM',block='mod',tol='0.1%')
resistor('R21','100k',158,75,'VREF_BUF','MOD_SUM',block='mod',tol='0.1%')
resistor('R22','200k',164,71,'MOD_SUM','GND',block='mod',tol='0.1%')
resistor('R23','10k',159.5,57,'MOD_FB','GND',block='mod',tol='0.1%')
resistor('R24','10k',163,59,'MOD_BIPOLAR','MOD_FB',block='mod',tol='0.1%')
sotfp=fp([sm(1,-1.,.95,1.0,.6),sm(2,-1.,-.95,1.,.6),sm(3,1.,0,1.,.6)],[1.4,2.9],1.1,'SOT23_BAT54S')
add('D4','BAT54S',166,65,sotfp,{'1':'GND','2':'VIN5','3':'MOD_SUM'},block='mod',mpn='BAT54S,215',maker='Nexperia',notes='Series diode pair clamp: 1=bottom anode, 2=top cathode, 3=junction. Verify powered and unpowered fault behavior.')
capacitor('C20','100nF',157,69,'VIN5',block='mod',rating='16V X7R')
capacitor('C21','1uF',149,74,'VIN5',block='mod',size='0805',rating='16V X7R')

# Internal service access. No new panel holes or user-facing service button fiction.
add('J202','22-27-2061',131,29,exact_6pin(),{str(i+1):n for i,n in enumerate(MAP[2])},'B',block='service',mpn='22-27-2061',maker='Molex',notes='Exact KK-254 6-circuit friction-lock service header; pin-for-pin to the JTAG nets already carried through J101/J18. No level conversion; validate JTAG frequency.')
buttonfp=fp([pad('1',-3.25,-2.25,1.8,1.8,1),pad('1',-3.25,2.25,1.8,1.8,1),pad('2',3.25,-2.25,1.8,1.8,1),pad('2',3.25,2.25,1.8,1.8,1)],[6,6],4.3,'SW_PUSH_6x6_P6.5x4.5')
add('SW3','PROGRAM / SERVICE',118.4,25,buttonfp,{'1':'PROGRAM_B','2':'GND'},'B',block='service',mpn='B3F-1000',maker='Omron',notes='Internal service push button, accessible after module removal.')
add('SW4','RESET / SERVICE',146,26,buttonfp,{'1':'reset_n','2':'GND'},'B',block='service',mpn='B3F-1000',maker='Omron')
# Named probe pads. 5V test point is intentionally before the direct-stack VIN5 feed to the mainboard.
for i,(x,y,net) in enumerate([(25,42,'GND'),(29,42,'VIN5'),(48,59,'VRAW'),(149,62,'VREF25'),(165,61,'MOD_BIPOLAR')],1):
 add(f'TP{i}',net,x,y,fp([sm(1,0,0,2,2)],[2,2],0,f'TestPoint_D2'),{'1':net},'B',block=('mod' if i>=4 else 'power'),mpn='PCB test pad',notes='Exposed soldermask aperture, no component.')

CONFIG={'name':'RADIAN Panel / Interface','revision':'P1','status':'ENGINEERING PROTOTYPE - NOT FABRICATION RELEASE','pcb_front_z':-8.,'pcb_thickness':1.6,'panel_size':[202.8,128.5,2.0],'mainboard_unchanged':False,'direct_stack_revision':STACK['revision'],'direct_stack_gap_mm':STACK['nominal_board_gap_mm'],'layers':['F.Cu','In1.Cu','In2.Cu','B.Cu'],'inner_layers':'GND planes (native refill and DRC required)','outline':OUTLINE,'windows':WINDOWS,'mounts':MOUNTS,'desktop_input':'12V regulated, centre positive via chassis-mounted Switchcraft 722A; short 2-wire harness to Molex J201','power_target':'5.08V nominal, up to 3A IC target, system current capability UNTESTED','default_mod_mode':'JP1 pin 1 common to pin 3 MOD_RAW = unipolar bypass','bipolar_mod':'JP1 pin 1 common to pin 2 MOD_BIPOLAR: ideal output 0.5*input+VREF25; firmware/calibration required','line_outputs':'Direct LINE_L and LINE_R from existing mainboard, not amplified Eurorack level','midi':'Same Sky SDS-50J right-angle DIN receptacle in enclosure; short 2-wire harness to Molex J306, no extra custom PCB'}

def save():
 if (ROOT/"NATIVE_BASELINE.json").exists():raise RuntimeError('Repaired native PCB is authoritative. Use hardware/refresh_outputs.py. Run legacy reconstruction only in a separate experimental copy without NATIVE_BASELINE.json.')
 ROOT.mkdir(exist_ok=True)
 (ROOT/'design'/'design.json').write_text(json.dumps({'config':CONFIG,'parts':PARTS,'pads':allpads(),'legacy_mainboard_map':MAP,'direct_stack':STACK},indent=2))
 with (ROOT/'docs'/'BOM.csv').open('w',newline='') as f:
  w=csv.writer(f);w.writerow(['Reference','Value','Manufacturer','MPN_or_selection_gate','Footprint','Side','X_panel_mm','Y_panel_mm','DNP','Notes'])
  for p in PARTS:w.writerow([p['ref'],p['value'],p['maker'],p['mpn'],p['fp']['name'],p['side'],p['x'],p['y'],p['dnp'],p['notes']])
 with (ROOT/'docs'/'mainboard_stack.csv').open('w',newline='') as f:
  w=csv.writer(f);w.writerow(['Stack','Panel_connector','Mainboard_connector','Physical_pin','Net','Panel_X_mm','Panel_Y_mm','Main_X_mm','Main_Y_mm','Note'])
  for con in STACK['connectors']:
   for i,n in enumerate(con['signals'],1):w.writerow([con['id'],con['panel_ref'],con['main_ref'],i,n,con['panel_xy_mm']['x'],con['panel_xy_mm']['y'],con['main_xy_mm']['x'],con['main_xy_mm']['y'],'Direct board-to-board mating site; no cable harness'])
 with (ROOT/'docs'/'mainboard_harness.csv').open('w',newline='') as f:
  w=csv.writer(f);w.writerow(['Status','Replacement']);w.writerow(['DEPRECATED - direct stack replaces J101..J116 cable harnesses','mainboard_stack.csv'])
 return PARTS
if __name__=='__main__':
 save();print(len(PARTS),'parts;',len(allpads()),'physical pads; mainboard pins',sum(map(len,MAP.values())))
