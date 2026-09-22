import pins from "./fpga-pins.json"
import { ftg256, soic8w208, qfn16, osc3225, inductor, stack2x10, cap0201, type LandPattern } from "./footprints"
import stack from "../stack/panel-stack.json"

export type Part = {
  name: string; value: string; block: string; x: number; y: number;
  kind: "chip" | "connector" | "resistor" | "capacitor" | "diode" | "led" | "inductor";
  rotation?: number;
  footprint: string | LandPattern; nets: Record<string,string>; tolerance?: string;
  labels?: Record<string,string>; nc?: string[]; layer?: "top" | "bottom";
}
export const parts: Part[]=[]
let block="power"
const add=(name:string,value:string,x:number,y:number,footprint:string|LandPattern,nets:Record<string,string>,labels?:Record<string,string>,nc?:string[])=>{
  parts.push({name,value,x,y,footprint,nets,labels,nc,block,kind:"chip"})
}
const passive=(kind:Part["kind"],name:string,value:string,x:number,y:number,a:string,b:string,footprint:string|LandPattern="0603",layer:"top"|"bottom"="top",tolerance?:string,rotation=0)=>{
  parts.push({kind,name,value,x,y,nets:{pin1:a,pin2:b},footprint,block,layer,tolerance,rotation})
}
const r=(name:string,value:string,x:number,y:number,a:string,b:string,tolerance?:string)=>passive("resistor",name,value,x,y,a,b,"0603","top",tolerance)
const c=(name:string,value:string,x:number,y:number,a:string,b="GND",footprint:string|LandPattern="0603",layer:"top"|"bottom"="top",rotation=0)=>passive("capacitor",name,value,x,y,a,b,footprint,layer,undefined,rotation)
const j=(name:string,value:string,x:number,y:number,nets:string[],rotation=0)=>{
  add(name,value,x,y,`pinrow${nets.length}_p2.54mm`,Object.fromEntries(nets.map((n,i)=>[`pin${i+1}`,n])))
  Object.assign(parts[parts.length-1],{kind:"connector",rotation})
}

// Regulated 5 V / 3 A input, externally fused supply. Pin 1 = +5 V.
c("C1","47uF",-62,35,"VIN5","GND","1210")
// TPS62130A's PG is actively low while disabled: cascade 1V -> 1V8 -> 3V3.
/** Grounded thermal vias dropped into the TPS62130A exposed pads. */
export const thermalVias: {name:string;x:number;y:number}[]=[]
const rails=[
  // 24.9k, not 25k: 25.0k is on no E-series grid and is not a stocked 1%
  // part. 0.8 V x (1 + 24.9/100) = 0.9992 V, which is nearer 1.000 V than the
  // 1% resistors can hold anyway.
  {id:1,y:23,out:"V1",en:"VIN5",pg:"PG1",top:"24.9k",bottom:"100k"},
  {id:2,y:0,out:"V1V8",en:"PG1",pg:"PG18",top:"124k",bottom:"100k"},
  {id:3,y:-23,out:"V3V3",en:"PG18",pg:"PROGRAM_B",top:"316k",bottom:"100k"},
]
for(const rail of rails){
  const {id,y,out,en,pg}=rail,n=10*id
  add(`U${10+id}`,"TPS62130ARGTR",-57,y,qfn16,{
    pin1:`SW${id}`,pin2:`SW${id}`,pin3:`SW${id}`,pin4:pg,pin5:`FB${id}`,
    pin6:"GND",pin7:"GND",pin8:"GND",pin9:`SS${id}`,pin10:"VIN5",pin11:"VIN5",pin12:"VIN5",
    pin13:en,pin14:out,pin15:"GND",pin16:"GND",pin17:"GND",
  })
  passive("inductor",`L${id}`,"1uH",-63,y,`SW${id}`,out,inductor)
  c(`C${n}`,"10uF",-56,y+4,"VIN5","GND","0805")
  c(`C${n+1}`,"100nF",-60,y+4,"VIN5")
  c(`C${n+2}`,"22uF",-69,y,out,"GND","0805")
  c(`C${n+3}`,"22uF",-69,y-3,out,"GND","0805")
  c(`C${n+4}`,"3.3nF",-53,y+2,`SS${id}`)
  r(`R${n}`,rail.top,-54,y-4,out,`FB${id}`,"1%")
  r(`R${n+1}`,rail.bottom,-58,y-4,`FB${id}`,"GND","1%")
  r(`R${n+2}`,"10k",-51,y-1,pg,id===3?"V3V3":"VIN5")
  // Grounded thermal vias in the exposed pad, carrying the switcher's heat into
  // the inner ground planes. TI's RGT0016C pad is 1.68 mm square (SLVSAG7F
  // section 12), which fits a 2x2 array on a 0.84 mm pitch: the outer pad edge
  // lands at 0.72 mm, inside the 0.84 mm thermal pad, and the via pads clear
  // each other by 0.24 mm. Four 0.3 mm vias rather than nine small ones is
  // deliberate -- below about four vias the barrel diameter, not the count,
  // dominates the pad-to-plane resistance.
  for(const [vx,vy] of [[-0.42,-0.42],[0.42,-0.42],[-0.42,0.42],[0.42,0.42]])
    thermalVias.push({name:`TV${id}${thermalVias.length%4+1}`,x:-57+vx,y:y+vy})
}

block="fpga"
export const io: Record<string,string>={
  D4:"clk100", E3:"audio_mclk_in", // both clock-capable; second oscillator below
  A3:"adc_sclk", B4:"adc_mosi", A4:"adc_miso", A5:"adc_cs_n",
  A7:"enc_a", B7:"enc_b", A8:"enc_btn_n", A9:"cv_select",
  A10:"gate", B9:"midi_rx", B10:"reset_n",
  A12:"led0", B12:"led1", A13:"led2", A14:"led3",
  T7:"dac_mclk", T8:"dac_bclk", T9:"dac_lrclk", T10:"dac_data", T12:"dac_unmute",
}
const fixed:Record<string,string>={
  H10:"DONE", E8:"FLASH_CLK_RAW", J13:"FLASH_MOSI",J14:"FLASH_MISO",L12:"FLASH_CS",
  K15:"FLASH_WP",K16:"FLASH_HOLD",L15:"PUDC_B",
  L7:"JTAG_TCK",N7:"JTAG_TDI",N8:"JTAG_TDO",M7:"JTAG_TMS",
  M9:"V3V3",M10:"GND",M11:"GND",K10:"INIT_B",L9:"PROGRAM_B",E7:"V3V3",
  G7:"GND",G8:"V1V8",J8:"GND",J7:"GND",F8:"GND",H7:"GND",H8:"GND",
}
export const fpgaNets:Record<string,string>={}
for(const p of pins){
  const supply=p.function==="GND"?"GND":p.function==="VCCINT"||p.function==="VCCBRAM"?"V1":
    p.function==="VCCAUX"?"V1V8":p.function.startsWith("VCCO_")?"V3V3":undefined
  if(supply||fixed[p.ball]||io[p.ball]) fpgaNets[p.ball]=supply||fixed[p.ball]||io[p.ball]
}
add("U1","XC7A50T-1FTG256I",0,5,ftg256,fpgaNets,
  Object.fromEntries(pins.map(p=>[p.ball,`${p.ball}_${p.function}`])),pins.filter(p=>!fpgaNets[p.ball]).map(p=>p.ball))
// Decouplers on the back, under the BGA. Each is a separate, physical capacitor.
//
// The 0201 land, the half-pitch diagonal offset and the 45 degree rotation are
// one constraint, not three choices. A dog-bone escape via needs 0.275 mm of
// barrel plus 0.15 mm of clearance, and the diagonal slot it sits in is only
// 0.707 mm from four balls of 0.25 mm radius -- 0.032 mm of slack before
// anything else is placed at all. A capacitor centred on a ball aims both of
// its lands at that ball's four slots and blocks every one of them: the 0402
// array this replaces blocked ten of the twenty slots the last five
// connections needed, which is why no router could finish them. Centred on a
// *slot* and turned 45 degrees, each capacitor consumes exactly one slot and
// leaves its neighbours 0.528 mm clear against the 0.425 mm requirement.
const pdn=[...Array(9).fill("V1"),...Array(5).fill("V1V8"),...Array(24).fill("V3V3")]
pdn.forEach((net,i)=>c(`C${100+i}`,"100nF",-7+(i%6)*3,12-Math.floor(i/6)*3,net,"GND",cap0201,"bottom",45))
for(const [i,net] of ["V1","V1V8","V3V3"].entries()){
  c(`C${140+i}`,"47uF",-17+i*6,-8,net,"GND","1210")
  c(`C${143+i}`,"4.7uF",-17+i*6,-12,net,"GND","0805")
}
r("R100","4.7k",12,-9,"INIT_B","V3V3")
r("R101","4.7k",12,-12,"DONE","V3V3")
r("R102","4.7k",12,-15,"PUDC_B","V3V3")
r("R103","10k",4,-30,"JTAG_TMS","V3V3")
r("R104","10k",8,-30,"JTAG_TDI","V3V3")
r("R105","10k",12,-30,"JTAG_TCK","GND")
r("R106","10k",-12,-32,"reset_n","V3V3")
c("C146","100nF",-16,-32,"reset_n")

block="configuration"
add("U2","W25Q64JVSSIQ",23,-22,soic8w208,{
  pin1:"FLASH_CS",pin2:"FLASH_MISO",pin3:"FLASH_WP",pin4:"GND",
  pin5:"FLASH_MOSI",pin6:"FLASH_CLK",pin7:"FLASH_HOLD",pin8:"V3V3",
})
c("C150","100nF",23,-15,"V3V3")
// At (11,-2.5), not (14,-22): this is series damping for the configuration
// clock, and damping works at the source. CCLK leaves the FPGA on ball E8, so
// the resistor sits 16 mm from the driver and lets the long run to U2 be the
// damped side. It was the other way round -- 9 mm from the flash, 32 mm from
// the FPGA -- which puts the resistor at the far end of the line it is meant
// to damp.
r("R110","33",11,-2.5,"FLASH_CLK_RAW","FLASH_CLK")
for(const [i,net] of ["FLASH_CS","FLASH_WP","FLASH_HOLD"].entries())r(`R${111+i}`,"4.7k",18+i*4,-30,net,"V3V3")
// Separate 100 MHz system / 12.288 MHz audio sources avoid fractional MMCM audio error.
add("Y1","ASE-100.000MHZ-LC-T",-20,19,osc3225,{pin1:"V3V3",pin2:"GND",pin3:"CLK100_RAW",pin4:"V3V3"})
r("R114","33",-15,19,"CLK100_RAW","clk100")
c("C151","100nF",-24,19,"V3V3")
add("Y2","ASE-12.288MHZ-LC-T",-20,26,osc3225,{pin1:"V3V3",pin2:"GND",pin3:"MCLK_RAW",pin4:"V3V3"})
r("R115","33",-15,26,"MCLK_RAW","audio_mclk_in")
c("C152","100nF",-24,26,"V3V3")

block="audio"
add("U3","PCM5102APWR",49,13,"tssop20_p0.65mm",{
  pin1:"A3V3",pin2:"DAC_CAPP",pin3:"GND",pin4:"DAC_CAPM",pin5:"DAC_VNEG",
  pin6:"DAC_L",pin7:"DAC_R",pin8:"A3V3",pin9:"GND",pin10:"GND",pin11:"GND",
  pin12:"I2S_MCLK",pin13:"I2S_BCLK",pin14:"I2S_DATA",pin15:"I2S_LRCLK",pin16:"GND",
  pin17:"dac_unmute",pin18:"DAC_LDO",pin19:"GND",pin20:"V3V3",
})
// 3.3 V analog power: passive RC isolation, not an LDO that would lose headroom.
r("R120","1",39,23,"V3V3","A3V3")
c("C160","10uF",44,23,"A3V3","GND","0805")
c("C161","100nF",48,23,"A3V3")
c("C162","100nF",44,18,"A3V3")
c("C163","2.2uF",42,14,"DAC_CAPP","DAC_CAPM")
c("C164","2.2uF",42,9,"DAC_VNEG")
c("C165","1uF",55,18,"DAC_LDO")
c("C166","100nF",55,23,"V3V3")
r("R121","10k",55,8,"dac_unmute","GND")
for(const [i,pair] of [["dac_mclk","I2S_MCLK"],["dac_bclk","I2S_BCLK"],["dac_lrclk","I2S_LRCLK"],["dac_data","I2S_DATA"]].entries())r(`R${122+i}`,"33",13,9-i*3,pair[0],pair[1])
r("R126","470",59,12,"DAC_L","LINE_L")
r("R127","470",59,4,"DAC_R","LINE_R")
c("C167","2.2nF",64,12,"LINE_L")
c("C168","2.2nF",64,4,"LINE_R")

block="controls"
// The ADC and its reference live in the analog corner, next to the CV front
// end, not beside the switchers. They were 26 mm (U5) and 40 mm (U4) from L1-L3
// switching at 2.5 MHz, while their signals came 45-64 mm across the board from
// the CV conditioning and the panel; that is backwards. A 12-bit conversion
// against 2.5 V has a 610 uV LSB, so the analog side is the side to keep short.
// U4 is rotated 270 so its analog inputs (pins 1-5) face the CV block above it
// and its SPI (pins 10-13) faces away, down and back toward the FPGA: the long
// run is now the digital one, which is the run that can afford to be long.
add("U4","MCP3208-CI/SL",35,-39,"soic16_p1.27mm",{
  pin1:"POT_PITCH",pin2:"POT_DECAY",pin3:"POT_TIMBRE",pin4:"PITCH_ADC",pin5:"MOD_ADC",
  pin6:"POT_DRIVE",pin7:"POT_DELAY",pin8:"POT_REVERB",pin9:"GND",pin10:"adc_cs_n",pin11:"adc_mosi",
  pin12:"adc_miso",pin13:"adc_sclk",pin14:"GND",pin15:"VREF25",pin16:"V3V3",
})
Object.assign(parts[parts.length-1],{rotation:270})
// Supply and reference decoupling on U4's other side, by pins 15 and 16.
c("C170","100nF",39,-44,"V3V3")
c("C171","1uF",35.5,-44,"VREF25")
r("R130","10k",32,-44,"adc_cs_n","V3V3")
// REF3125: VIN=1, OUT=2, GND=3, per TI SOT23 DBZ pinout.
add("U5","REF3125AIDBZR",33.5,-23,"sot23",{pin1:"V3V3",pin2:"VREF25",pin3:"GND"})
c("C172","100nF",33.5,-26,"V3V3")
c("C173","1uF",30,-26,"VREF25")
// The 1k stays at the panel header and the 10nF goes to the ADC pin, so the
// long wiper run sits *inside* the RC instead of downstream of it: whatever the
// trace picks up crossing the board is shunted at U4's input rather than
// arriving at its sampling capacitor. Same reasoning for the CV pair below.
const potFilter=[[43.5,-34.5],[40,-34.5],[36.5,-34.5]]
for(const [i,net] of ["POT_PITCH","POT_DECAY","POT_TIMBRE"].entries()){
  r(`R${131+i}`,"1k",-36+i*18,34,`${net}_RAW`,net)
  c(`C${174+i}`,"10nF",potFilter[i][0],potFilter[i][1],net)
}
// Three dedicated effect-pot channels enter through direct-stack connector A and each gets its own ADC RC filter.
for(const [i,net] of ["POT_DRIVE","POT_DELAY","POT_REVERB"].entries()){
  r(`R${190+i}`,"1kΩ",64,-4-i*3,`${net}_RAW`,net)
  c(`C${201+i}`,"10nF",30-i*3,-34.5,net,"GND","0603","bottom")
}
for(const [i,pair] of [["ENC_A_RAW","enc_a"],["ENC_B_RAW","enc_b"],["ENC_SW_RAW","enc_btn_n"]].entries()){
  r(`R${140+i}`,"1k",17+i*5,31,pair[0],pair[1])
  r(`R${143+i}`,"10k",17+i*5,27,pair[1],"V3V3")
  c(`C${180+i}`,"10nF",17+i*5,23,pair[1])
}
r("R146","10k",42,32,"cv_select","GND")
// The panel-side nets are `_A` (the LED anode beyond the series resistor), not
// `LED0`: `led0` and `LED0` are distinct nets here and in KiCad, but Specctra
// folds net names to one case, so the DSN handoff merged each pair and the
// router shorted straight across R147-R150. Nothing may differ by case alone;
// scripts/check.ts enforces it.
for(let i=0;i<4;i++)r(`R${147+i}`,"1k",59+i*4,32,`led${i}`,`LED${i}_A`)

block="cv"
// 0..5 V unipolar CV -> 0..2.5 V. 0.1% matched 20k dividers, input rail clamps.
add("U6","MCP6002-I/SN",43,-21,"soic8_p1.27mm",{
  pin1:"PITCH_BUF",pin2:"PITCH_BUF",pin3:"PITCH_DIV",pin4:"GND",
  pin5:"MOD_DIV",pin6:"MOD_BUF",pin7:"MOD_BUF",pin8:"V3V3",
})
c("C190","100nF",43,-14,"V3V3")
for(const [i,net] of ["PITCH","MOD"].entries()){
  const y=-18-i*13
  r(`R${160+i*3}`,"20k",64,y,`${net}_IN`,`${net}_DIV`,"0.1%")
  r(`R${161+i*3}`,"20k",59,y-4,`${net}_DIV`,"GND","0.1%")
  add(`D${10+i}`,"BAT54S",54,y,"sot23",{pin1:"GND",pin2:"V3V3",pin3:`${net}_DIV`})
  c(`C${191+i}`,"1nF",59,y,`${net}_DIV`)
  // Series resistor at the buffer, filter capacitor at the ADC (see above).
  r(`R${162+i*3}`,"100",35,y,`${net}_BUF`,`${net}_ADC`)
  c(`C${193+i}`,"10nF",[33,29.5][i],-34.5,`${net}_ADC`)
}
// Comparator with built-in hysteresis; rising threshold approx 2.02 V at jack.
r("R166","100k",61,-40,"GATE_IN","GATE_DIV","1%")
r("R167","33k",56,-43,"GATE_DIV","GND","1%")
add("D12","BAT54S",55,-38,"sot23",{pin1:"GND",pin2:"V3V3",pin3:"GATE_DIV"})
r("R168","40.2k",43,-39,"VREF25","GATE_REF","1%")
r("R169","10k",43,-43,"GATE_REF","GND","1%")
add("U7","MCP6561T-E/OT",49,-39,"sot23_5",{pin1:"gate",pin2:"GND",pin3:"GATE_DIV",pin4:"GATE_REF",pin5:"V3V3"})
c("C195","100nF",49,-44,"V3V3")
c("C196","1nF",61,-44,"GATE_DIV")

block="midi"
// Isolated DIN input harness: pin 4 -> 220R -> anode; pin 5 -> cathode.
// No connection from DIN pin 2/shield to board ground.
r("R180","220",-66,-35,"MIDI4","MIDI_A")
add("U8","H11L1M",-52,-39,"dip6",{pin1:"MIDI_A",pin2:"MIDI5",pin4:"midi_rx",pin5:"GND",pin6:"V3V3"},undefined,["pin3"])
passive("diode","D20","1N4148W",-64,-40,"MIDI5","MIDI_A","sod123")
r("R181","2.2k",-45,-33,"midi_rx","V3V3")
c("C200","100nF",-45,-37,"V3V3")


// Direct panel/mainboard mezzanine interface. Both boards consume the same
// hardware/stack/panel-stack.json contract; the panel mirrors footprint X on
// its bottom side so equal logical pin numbers occupy equal product-space XY.
for(const con of stack.connectors){
  const signals=con.signals as string[]
  add(con.main_ref,stack.connector_footprint.main.mpn,con.main_xy_mm.x,con.main_xy_mm.y,stack2x10,
    Object.fromEntries(signals.map((n,i)=>[`pin${i+1}`,n])))
  Object.assign(parts[parts.length-1],{kind:"connector",rotation:con.rotation_deg})
}

export const nets=[...new Set(parts.flatMap(p=>Object.values(p.nets)))].sort()
