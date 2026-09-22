import { parts, nets, thermalVias, type Part } from "./design"
import { lands, fpgaRows } from "./footprints"

function Component({p,index}:{p:Part;index:number}) {
  if(p.name==="U1") {
    const toPin=(ball:string)=>`pin${fpgaRows.indexOf(ball[0])*16+Number(ball.slice(1))}`
    p={...p,nets:Object.fromEntries(Object.entries(p.nets).map(([ball,net])=>[toPin(ball),net])),
      labels:Object.fromEntries(Object.keys(p.labels!).map(ball=>[toPin(ball),ball])),
      nc:p.nc!.map(toPin)}
  }
  const footprint=typeof p.footprint==="string"?p.footprint:lands(p.footprint)
  const common={name:p.name,footprint,pcbX:p.x,pcbY:p.y,layer:p.layer??"top" as const,
    pcbRotation:p.rotation??0,
    schX: (index%12)*7,schY:-Math.floor(index/12)*7}
  const connections=Object.fromEntries(Object.entries(p.nets).map(([pin,net])=>[pin,`net.${net}`]))
  if(p.kind==="resistor")return <resistor {...common} resistance={p.value} tolerance={p.tolerance} connections={connections}/>
  if(p.kind==="capacitor")return <capacitor {...common} capacitance={p.value} connections={connections}/>
  if(p.kind==="inductor")return <inductor {...common} inductance={p.value} connections={connections}/>
  if(p.kind==="diode")return <diode {...common} manufacturerPartNumber={p.value} connections={connections}/>
  const pinLabels=p.labels??Object.fromEntries([
    ...Object.keys(p.nets).map(pin=>[pin,pin]),...(p.nc??[]).map(pin=>[pin,pin]),
  ])
  // Declare supply pins from what they are actually tied to, so the netlist
  // checks can tell a rail pin from a signal pin.
  const rails:Record<string,number>={VIN5:5,V3V3:3.3,A3V3:3.3,V1V8:1.8,V1:1}
  const pinAttributes=Object.fromEntries(Object.entries(p.nets).flatMap(([pin,net]):[string,object][]=>
    net==="GND"?[[pin,{requiresGround:true}]]:
    net in rails?[[pin,{requiresPower:true,requiresVoltage:rails[net]}]]:[]))
  // Panel/rear I/O headers are connectors, and each is rotated so its pins open
  // toward the nearest board edge rather than into the board.
  if(p.kind==="connector")return <connector {...common}
    manufacturerPartNumber={p.value} pinCount={Object.keys(p.nets).length}
    pinLabels={pinLabels} pinAttributes={pinAttributes} connections={connections}/>
  return <chip {...common} manufacturerPartNumber={p.value} pinLabels={pinLabels}
    pinAttributes={pinAttributes}
    pcbPinLabels={p.name==="U1"?p.labels:undefined} noConnect={p.nc} connections={connections} schX={p.name==="U1"?-25:common.schX}
    schY={p.name==="U1"?-45:common.schY}/>
}
export default function Courant() {
  return <board width={160} height={100} layers={6} thickness={1.6}
    title="Courant standalone Rev A" solderMaskColor="black" silkscreenColor="white"
    minTraceWidth={0.15} autorouter="none">
    {/* Routing is handed off: tscircuit's capacity-autorouter does not converge
        on this board (docs/board.md section 3), so asking for it costs ~17
        minutes per build and still emits no copper. `none` keeps every build
        fast and honest; the DSN and KiCad exports carry the netlist out. */}
    <schematicsheet sheetSize="ANSI_B"/>
    {nets.map(name=><net key={name} name={name}/>)}
    {parts.map((p,index)=><Component key={p.name} p={p} index={index}/>)}
    {[[-75,45],[75,45],[-75,-45],[75,-45]].map(([x,y],i)=><hole key={i}
      name={`H${i+1}`} pcbX={x} pcbY={y} diameter={3.2}/>)}
    {/* Assembly fiducials: three, non-collinear, so pick-and-place can resolve
        rotation as well as offset for the 256-ball BGA. The third is at
        (-68,-45), not (-72,-41): that put its pad 0.27 mm from J15 pin 1, i.e.
        overlapping it, which KiCad DRC reports as a zero-clearance violation
        and a soldermask bridge. Fiducials carry no net, so no netlist check
        could ever have seen it. */}
    {[[-72,41],[72,41],[-68,-45]].map(([x,y],i)=><fiducial key={i}
      name={`FID${i+1}`} pcbX={x} pcbY={y} padDiameter={1} soldermaskPullback={1}/>)}
    {/* Thermal vias in the three switchers' exposed pads. Placed here rather
        than left to the router: they are a thermal structure, not a
        connection, and no autorouter will invent them (see design.ts). */}
    {thermalVias.map(v=><via key={v.name} name={v.name} pcbX={v.x} pcbY={v.y}
      fromLayer="top" toLayer="bottom" holeDiameter={0.3} outerDiameter={0.6}
      connectsTo="net.GND"/>)}
    {/* Six layers: signal / GND / signal / V3V3 / GND / signal. F.Cu, In2 and
        B.Cu carry signal, each with a ground plane beside it (F.Cu and In2
        against In1, B.Cu against In4), so every BGA escape and every I2S/SPI
        clock has a continuous return path directly underneath.

        In3 carries 3.3 V as a pour and stays routable. V3V3 reaches 96 pins
        and cost 634 mm of trace when routed as copper, the largest net on the
        board; as a pour each of those pins is a via straight down, and the
        signals that still need In3 simply fill around it. A slot in a power
        pour is cheap. A slot in a return path is not, which is why
        scripts/route.py reserves the two ground planes and nothing else.

        Eight layers was tried and is not needed. The board appeared to require
        them only because of a routing-handoff mistake: declaring the plane
        layers `(type power)` in the DSN does not keep signals off them, it
        makes them unavailable for connections entirely, so GND pins could not
        reach their own pours. That left 55-60 connections unrouted across
        three runs and was misread as the board being too dense. With the real
        mechanism -- a per-net-class `use_layer` clause that restricts signals
        while leaving GND the whole stackup -- six layers routes to 9 unrouted
        and eight routes to 14. Fewer layers, better result. */}
    <copperpour layer="inner1" connectsTo="net.GND" clearance="0.2mm" boardEdgeMargin="0.5mm"/>
    <copperpour layer="inner3" connectsTo="net.V3V3" clearance="0.25mm" boardEdgeMargin="1mm"/>
    <copperpour layer="inner4" connectsTo="net.GND" clearance="0.2mm" boardEdgeMargin="0.5mm"/>
    <silkscreentext text="COURANT" pcbX={0} pcbY={47} fontSize={2.2}/>
    <silkscreentext text="REV A / ARTIX-7 / STEREO SYNTH" pcbX={0} pcbY={-47} fontSize={1}/>
    <silkscreentext text="5V DC" pcbX={-70} pcbY={40} fontSize={1}/>
    <silkscreentext text="LINE L G R" pcbX={68} pcbY={17} fontSize={0.8}/>
    <silkscreentext text="MIDI IN" pcbX={-69} pcbY={-30} fontSize={0.8}/>
    <silkscreentext text="PITCH" pcbX={72} pcbY={-14} fontSize={0.8}/>
    <silkscreentext text="MOD" pcbX={72} pcbY={-27} fontSize={0.8}/>
    <silkscreentext text="GATE" pcbX={71} pcbY={-37} fontSize={0.8}/>
  </board>
}
