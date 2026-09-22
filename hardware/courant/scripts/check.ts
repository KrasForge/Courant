/**
 * Board-specific electrical rule checks.
 *
 * These are the rules tscircuit cannot know: they are about the XC7A35T's
 * package, its configuration straps, and this board's rail topology.
 * Generic connectivity/DRC belongs to `tsci check netlist` and `tsci build`,
 * which the `verify` script runs alongside this.
 */
import pins from "../fpga-pins.json"
import { parts, nets, io, fpgaNets, thermalVias } from "../design"

const byBall = Object.fromEntries(pins.map((p) => [p.ball, p]))
const fails: string[] = []
const warns: string[] = []
const fail = (m: string) => fails.push(m)
const warn = (m: string) => warns.push(m)

// ---------------------------------------------------------------- netlist ---
const pinsOfNet: Record<string, string[]> = {}
for (const p of parts)
  for (const [pin, net] of Object.entries(p.nets)) (pinsOfNet[net] ??= []).push(`${p.name}.${pin}`)

for (const [net, conns] of Object.entries(pinsOfNet))
  if (conns.length < 2) fail(`net ${net} has a single connection (${conns[0]}); it drives nothing`)

// Net names must stay distinct when case is ignored. tscircuit and KiCad treat
// `led0` and `LED0` as two nets; Specctra does not, so a DSN handoff silently
// merges them and the router shorts whatever sits between. This cost the four
// LED series resistors once already.
const byFold: Record<string, string[]> = {}
for (const net of nets) (byFold[net.toLowerCase()] ??= []).push(net)
for (const [fold, group] of Object.entries(byFold))
  if (group.length > 1)
    fail(`nets ${group.join(" and ")} differ only by case; Specctra folds them to "${fold}" and the router will short them together`)

const refdes = parts.map((p) => p.name)
for (const name of new Set(refdes))
  if (refdes.filter((n) => n === name).length > 1) fail(`duplicate reference designator ${name}`)

// ------------------------------------------------------------------- FPGA ---
// Every ball the design assigns must exist in AMD's package file, and no user
// signal may land on a dedicated configuration or supply ball.
for (const [ball, net] of Object.entries(fpgaNets)) {
  const p = byBall[ball]
  if (!p) { fail(`U1 ball ${ball} is not in the ftg256 package`); continue }
  if (io[ball] && !p.function.startsWith("IO_"))
    fail(`U1 ball ${ball} carries user signal ${net} but is a ${p.function} pin`)
}

// Bank voltage: every user I/O sits in a bank whose VCCO this board ties to 3.3 V.
const bankOfIo = new Set(Object.keys(io).map((b) => byBall[b]?.bank))
for (const bank of bankOfIo) {
  const vcco = pins.filter((p) => p.function === `VCCO_${bank}`)
  if (!vcco.length) { fail(`bank ${bank} is used but has no VCCO pin in the package`); continue }
  for (const p of vcco)
    if (fpgaNets[p.ball] !== "V3V3")
      fail(`bank ${bank} carries 3.3 V LVCMOS I/O but ${p.ball} (${p.function}) is on ${fpgaNets[p.ball] ?? "no net"}`)
}

// Clock *inputs* must land on clock-capable balls or they cannot drive the
// MMCM directly. The dac_*/adc_sclk clocks are FPGA outputs and may sit on any
// user I/O, so only the two oscillator inputs are checked here.
const clockInputs = ["clk100", "audio_mclk_in"]
for (const net of clockInputs) {
  const ball = Object.keys(io).find((b) => io[b] === net)
  if (!ball) { fail(`clock input ${net} is not assigned to a ball`); continue }
  if (!/[MS]RCC/.test(byBall[ball]?.function ?? ""))
    fail(`clock input ${net} is on ${ball} (${byBall[ball]?.function}), which is not clock-capable`)
}

// Configuration straps, per UG470. M[2:0]=001 selects master SPI.
const strap: Record<string, string> = { M9: "V3V3", M10: "GND", M11: "GND" }
for (const [ball, want] of Object.entries(strap))
  if (fpgaNets[ball] !== want)
    fail(`mode pin ${ball} (${byBall[ball]?.function}) is ${fpgaNets[ball] ?? "floating"}, expected ${want} for master SPI`)
if (fpgaNets.E7 !== "V3V3") fail("CFGBVS (E7) must be tied to V3V3 for a 3.3 V config bank")
if (fpgaNets.G8 !== "V1V8") fail("VCCADC (G8) must be on the 1.8 V rail")
for (const ball of ["J8", "H7"])
  if (fpgaNets[ball] !== "GND")
    fail(`${byBall[ball]?.function} (${ball}) must be grounded when the XADC is unused`)

// Supplies: no power ball may be left unconnected.
for (const p of pins) {
  const isSupply = p.function === "GND" || p.function.startsWith("VCC")
  if (isSupply && !fpgaNets[p.ball] && p.function !== "VCCBATT_0")
    fail(`U1 supply ball ${p.ball} (${p.function}) is not connected`)
}

// ------------------------------------------------------------------ rails ---
// Each rail needs local bulk plus high-frequency decoupling.
const decoupling: Record<string, number> = {}
for (const p of parts)
  if (p.kind === "capacitor")
    for (const net of Object.values(p.nets)) if (net !== "GND") decoupling[net] = (decoupling[net] ?? 0) + 1
for (const rail of ["V1", "V1V8", "V3V3"]) {
  const n = decoupling[rail] ?? 0
  // One per powered ball is the usual floor for a BGA of this size.
  const balls = Object.entries(fpgaNets).filter(([, net]) => net === rail).length
  if (n < balls) warn(`rail ${rail} has ${n} capacitors for ${balls} powered balls`)
}

// Every net named like a rail must actually be produced by a regulator.
for (const rail of ["V1", "V1V8", "V3V3"])
  if (!parts.some((p) => p.value.startsWith("TPS62130") && Object.values(p.nets).includes(rail)))
    fail(`rail ${rail} has no regulator output`)

// Thermal vias must land inside the exposed pad they are cooling, and must not
// touch each other's barrels. Both are geometry the netlist cannot express and
// the router will not police: the vias are placed by hand in the board file,
// and a regulator that moves without them moving leaves four holes in open
// copper.
const EXPOSED_PAD = 1.68 // TPS62130A RGT0016C, SLVSAG7F section 12
const VIA_OD = 0.6
for (const v of thermalVias) {
  const host = parts.find((p) => p.value.startsWith("TPS62130")
    && Math.abs(p.x - v.x) <= EXPOSED_PAD / 2 && Math.abs(p.y - v.y) <= EXPOSED_PAD / 2)
  if (!host) { fail(`thermal via ${v.name} is not inside any TPS62130A exposed pad`); continue }
  const reach = Math.max(Math.abs(v.x - host.x), Math.abs(v.y - host.y)) + VIA_OD / 2
  if (reach > EXPOSED_PAD / 2)
    fail(`thermal via ${v.name} overhangs ${host.name}'s exposed pad by ${(reach - EXPOSED_PAD / 2).toFixed(3)} mm`)
}
for (const [i, a] of thermalVias.entries())
  for (const b of thermalVias.slice(i + 1))
    if (Math.hypot(a.x - b.x, a.y - b.y) < VIA_OD)
      fail(`thermal vias ${a.name} and ${b.name} overlap`)

// ----------------------------------------------------------------- report ---
console.log(`${parts.length} parts, ${nets.length} nets, ${Object.keys(fpgaNets).length} FPGA balls assigned`)
for (const w of warns) console.log(`  warn  ${w}`)
for (const f of fails) console.log(`  FAIL  ${f}`)
console.log(fails.length ? `\n${fails.length} check(s) failed` : `\nall checks passed${warns.length ? ` (${warns.length} warning(s))` : ""}`)
process.exit(fails.length ? 1 : 0)
