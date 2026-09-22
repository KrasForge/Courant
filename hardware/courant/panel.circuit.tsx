import type { ReactElement } from "react"
import design from "../panel/tscircuit-design.json"

type Pad = {
  port:string; net:string|null; x:number; y:number; sx:number; sy:number;
  drill:number|number[]|null; kind:string; shape:string
}
const Cutout:any="cutout"

type PanelPart = {
  ref:string; value:string; block:string; x:number; y:number;
  side:"top"|"bottom"; rotation:number; body:number[]; pads:Pad[]
}

function padElement(p:Pad, i:number):ReactElement {
  const key=`${p.port}-${i}`
  const hints=p.net ? [p.port] : undefined
  if(p.kind==="smd") return <smtpad key={key} portHints={hints}
    pcbX={p.x} pcbY={p.y} shape="rect" width={p.sx} height={p.sy}/>
  if(p.kind==="np_thru_hole") {
    if(Array.isArray(p.drill)) return <hole key={key} pcbX={p.x} pcbY={p.y}
      shape="oval" width={p.drill[0]} height={p.drill[1]}/>
    return <hole key={key} pcbX={p.x} pcbY={p.y} diameter={p.drill ?? p.sx}/>
  }
  if(Array.isArray(p.drill)) return <platedhole key={key} portHints={hints}
    pcbX={p.x} pcbY={p.y} shape="oval" outerWidth={p.sx} outerHeight={p.sy}
    holeWidth={p.drill[0]} holeHeight={p.drill[1]}/>
  if(p.shape==="rect") return <platedhole key={key} portHints={hints}
    pcbX={p.x} pcbY={p.y} shape="circular_hole_with_rect_pad"
    holeDiameter={p.drill ?? 1} rectPadWidth={p.sx} rectPadHeight={p.sy}/>
  return <platedhole key={key} portHints={hints} pcbX={p.x} pcbY={p.y}
    shape="circle" holeDiameter={p.drill ?? 1} outerDiameter={Math.max(p.sx,p.sy)}/>
}

function footprint(part:PanelPart):ReactElement {
  const electrical=part.pads.filter(p=>p.net)
  const xmax=Math.max(part.body[0]/2,...part.pads.map(p=>Math.abs(p.x)+p.sx/2))+.25
  const ymax=Math.max(part.body[1]/2,...part.pads.map(p=>Math.abs(p.y)+p.sy/2))+.25
  return <footprint>
    {part.pads.map(padElement)}
    <courtyardrect pcbX={0} pcbY={0} width={2*xmax} height={2*ymax}/>
  </footprint>
}
function Part({part,index}:{part:PanelPart;index:number}) {
  const electrical=part.pads.filter(p=>p.net)
  const pinLabels=Object.fromEntries(electrical.map(p=>[p.port,p.port]))
  const connections=Object.fromEntries(electrical.map(p=>[p.port,`net.${p.net}`]))
  return <chip name={part.ref} manufacturerPartNumber={part.value}
    footprint={footprint(part)} layer={part.side} pcbX={part.x} pcbY={part.y}
    pcbRotation={part.rotation} pinLabels={pinLabels} connections={connections}
    schX={(index%10)*8} schY={-Math.floor(index/10)*8}/>
}

const parts=design.parts as PanelPart[]
const nets=[...new Set(parts.flatMap(part=>part.pads.flatMap(p=>p.net?[p.net]:[])))].sort()

export default function Panel() {
  return <board outline={design.outline} layers={4} thickness={1.6}
    title="RADIAN panel / direct-stack interface" solderMaskColor="black"
    silkscreenColor="white" minTraceWidth={0.2} autorouter="none">
    <schematicsheet sheetSize="ANSI_B"/>
    {nets.map(name=><net key={name} name={name}/>)}
    {design.windows.map((points,i)=><Cutout key={`window-${i}`} name={`WINDOW${i+1}`}
      shape="polygon" points={points}/>)}
    {design.mounts.map((m,i)=><hole key={`mount-${i}`} name={`MH${i+1}`}
      pcbX={m.x} pcbY={m.y} diameter={m.diameter}/>)}
    {parts.map((part,index)=><Part key={part.ref} part={part} index={index}/>)}
    <silkscreentext text="RADIAN PANEL / DIRECT STACK P1" pcbX={0} pcbY={52} fontSize={1.2}/>
    <silkscreentext text="J100 ANALOG / J101 DIGITAL" pcbX={0} pcbY={-52} fontSize={0.9}/>
  </board>
}
