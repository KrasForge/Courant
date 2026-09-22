import type { ReactElement } from "react"

/**
 * Custom land patterns, for packages @tscircuit/footprinter cannot express.
 * Everything else uses a footprinter string directly (see design.ts).
 *
 * All coordinates are top view, millimetres. Pin 1 is upper left on ICs,
 * matching footprinter's own convention for SOIC/TSSOP/QFN/SOT, so parts can
 * move between a string and a pattern here without renumbering.
 */
export type Pad = { pin: string; x: number; y: number; w?: number; h?: number; hole?: number; diameter?: number }
export type LandPattern = { width: number; height: number; pads: Pad[]; courtyard?: boolean }
export function lands(p: LandPattern): ReactElement {
  return <footprint>
    {p.pads.map(pad => pad.hole ?
      <platedhole key={pad.pin} portHints={[pad.pin]} pcbX={pad.x} pcbY={pad.y}
        shape="circle" holeDiameter={pad.hole} outerDiameter={pad.diameter ?? 1.8} /> :
      pad.diameter ? <smtpad key={pad.pin} portHints={[pad.pin]} pcbX={pad.x} pcbY={pad.y}
        shape="circle" radius={pad.diameter / 2} /> :
      <smtpad key={pad.pin} portHints={[pad.pin]} pcbX={pad.x} pcbY={pad.y}
        shape="rect" width={pad.w!} height={pad.h!} />)}
    <silkscreenpath route={[
      {x:-p.width/2,y:p.height/2}, {x:p.width/2,y:p.height/2},
      {x:p.width/2,y:-p.height/2}, {x:-p.width/2,y:-p.height/2},
      {x:-p.width/2,y:p.height/2},
    ]} strokeWidth={0.12}/>
    {p.courtyard!==false && <courtyardrect pcbX={0} pcbY={0}
      width={Math.max(p.width, ...p.pads.map(q=>2*Math.abs(q.x)+(q.w ?? q.diameter ?? 0)))+0.5}
      height={Math.max(p.height, ...p.pads.map(q=>2*Math.abs(q.y)+(q.h ?? q.diameter ?? 0)))+0.5}/>}
  </footprint>
}

/** XC7A35T-1FTG256C. 16x16 balls, 1.0 mm pitch, 17x17 mm body.
 *  Ball A1 is upper left; footprinter's bga256 numbers from the lower left, so
 *  this stays custom to keep `pin(row*16+col)` aligned with the AMD ball map. */
export const fpgaRows="ABCDEFGHJKLMNPRT"
export const ftg256: LandPattern={width:17,height:17,pads:[...fpgaRows].flatMap((row,r)=>
  Array.from({length:16},(_,c)=>({pin:`pin${r*16+c+1}`,x:c-7.5,y:7.5-r,diameter:0.5})))}


/** Exact 0201 decoupler land used under the BGA. tscircuit's generic 0201
 *  footprint emits a rotated-bottom courtyard that its current overlap checker
 *  compares in the wrong coordinate frame, producing three impossible overlap
 *  reports between parts 6-8.5 mm apart. Pads match the native KiCad footprint
 *  exactly; courtyard checking remains authoritative in native KiCad DRC. */
export const cap0201: LandPattern={width:1.12,height:0.7,courtyard:false,pads:[
  // Custom footprints are mirrored when placed on bottom; use the local signs
  // below so the final product-space pin numbering matches the native KiCad
  // 0201 footprint and tscircuit's former generic-footprinter result.
  {pin:"pin1",x:-0.33,y:0,w:0.46,h:0.40},
  {pin:"pin2",x:0.33,y:0,w:0.46,h:0.40},
]}

/** W25Q64JVSSIQ: 8-pin SOIC 208-mil (Winbond package code SS, datasheet 10.1).
 *  H 7.70/7.90/8.10 span, E1 5.23 body, e 1.27, b 0.35/0.42/0.48, L 0.50/0.65/0.80.
 *  IPC-7351 nominal gull-wing fillets (toe 0.35, heel 0.35, side 0.03):
 *  Z = 8.10+0.70 = 8.80, G = (7.70-1.60)-0.70 = 5.40, so pads are
 *  (Z-G)/2 = 1.70 long on a (Z+G)/2 = 7.10 mm centre span.
 *  footprinter's `soic8_w<n>mm_p1.27mm` silently ignores the width modifier and
 *  returns the 150-mil pattern, so this one is spelled out. */
export const soic8w208: LandPattern={width:5.23,height:5.28,pads:Array.from({length:8},(_,i)=>({
  pin:`pin${i+1}`, x:i<4 ? -3.55 : 3.55,
  y:(i<4 ? 1.5-i : i-5.5)*1.27,
  w:1.7,h:0.6,
}))}

/** ASE-xxxMHZ-LC-T, 3.2 x 2.5 mm 4-pad oscillator. Pin 1 (enable) is lower
 *  left with the package dot, 2 = GND, 3 = OUT, 4 = VDD, counterclockwise. */
export const osc3225: LandPattern={width:3.2,height:2.5,pads:[
  {pin:"pin1",x:-1.1,y:-0.8,w:1.2,h:1},{pin:"pin2",x:1.1,y:-0.8,w:1.2,h:1},
  {pin:"pin3",x:1.1,y:0.8,w:1.2,h:1},{pin:"pin4",x:-1.1,y:0.8,w:1.2,h:1},
]}

/** TPS62130ARGTR, VQFN-16 RGT0016C: body 2.9/3.1, 16 leads 0.18-0.30 wide and
 *  0.3-0.5 long reaching 1.5 mm from centre, exposed thermal pad 1.68 +/-0.07
 *  (TI datasheet SLVSAG7F section 12). Pads span 1.10-1.80 from centre, leaving
 *  a 0.25 mm gap to the thermal pad.
 *  Not `qfn16_w3_h3_p0.5mm_thermalpad`: footprinter puts the signal pads'
 *  inner edges at 0.525 against a 1.75 mm thermal pad, overlapping them by
 *  0.35 mm and shorting every pin to the pad. */
export const qfn16: LandPattern={width:3,height:3,pads:[
  ...Array.from({length:16},(_,i)=>{
    const side=Math.floor(i/4),t=(i%4-1.5)*0.5
    return {pin:`pin${i+1}`,x:side===0?-1.45:side===1?t:side===2?1.45:-t,
      y:side===0?-t:side===1?-1.45:side===2?t:1.45,
      w:side%2?0.25:0.7,h:side%2?0.7:0.25}
  }),{pin:"pin17",x:0,y:0,w:1.68,h:1.68},
]}

/** 4 x 4 mm shielded power inductor (1 uH, >= 3 A saturation). */
export const inductor: LandPattern={width:4,height:4,pads:[
  {pin:"pin1",x:-1.7,y:0,w:1.3,h:3.7},{pin:"pin2",x:1.7,y:0,w:1.3,h:3.7},
]}

/** Samtec IPT1-110-06-L-D mainboard terminal strip.
 *  2x10, 2.54 mm pitch/row spacing, .64 mm square posts. Samtec's recommended
 *  through-hole PCB layout calls for 1.02 mm drills. The body is nominally
 *  5.08 mm wide and 25.91 mm long for 10 positions per row. */
export const stack2x10: LandPattern={width:5.08,height:25.91,pads:Array.from({length:20},(_,i)=>({
  pin:`pin${i+1}`,x:i%2===0?-1.27:1.27,y:(4.5-Math.floor(i/2))*2.54,hole:1.02,diameter:1.8,
}))}
