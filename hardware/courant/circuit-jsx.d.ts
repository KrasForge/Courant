import type { Attributes } from "react"
import type { BoardProps, ChipProps, ConnectorProps, FiducialProps, CopperPourProps, CourtyardRectProps, SchematicSheetProps, ResistorProps, CapacitorProps, InductorProps, DiodeProps, NetProps, HoleProps, FootprintProps, SmtPadProps, PlatedHoleProps, SilkscreenPathProps, SilkscreenTextProps, ViaProps } from "@tscircuit/props"
declare module "react" {
  namespace JSX {
    interface IntrinsicElements {
      board: BoardProps & Attributes; chip: ChipProps & Attributes;
      resistor: ResistorProps & Attributes; capacitor: CapacitorProps & Attributes;
      inductor: InductorProps & Attributes; diode: DiodeProps & Attributes;
      net: NetProps & Attributes; hole: HoleProps & Attributes;
      connector: ConnectorProps & Attributes; fiducial: FiducialProps & Attributes;
      copperpour: CopperPourProps & Attributes; courtyardrect: CourtyardRectProps & Attributes;
      schematicsheet: SchematicSheetProps & Attributes;
      footprint: FootprintProps & Attributes; smtpad: SmtPadProps & Attributes;
      platedhole: PlatedHoleProps & Attributes; via: ViaProps & Attributes;
      silkscreenpath: SilkscreenPathProps & Attributes;
      silkscreentext: SilkscreenTextProps & Attributes;
    }
  }
}
