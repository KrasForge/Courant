# Panel controller

Wires the physical front panel to the engine (issues #78 and #85): six macro
pots edit live parameters, while the existing MODE switch and bottom-left push
encoder provide a PLAY/EDIT page model through the `preset_bank` register /
preset interface. RTL: [`src/rtl/panel_ctrl.vhd`](../src/rtl/panel_ctrl.vhd).

## Control map

No pot, ADC channel, connector, or PCB signal was added. The existing two-state
MODE switch is now semantic rather than a direct two-layer selector:

- **PLAY (`sw0=0`)**: the six knobs are the immediate performance controls and
  the encoder selects presets.
- **EDIT (`sw0=1`)**: the encoder selects an edit page and the same six knobs
  edit that page. The four panel LEDs become a one-hot page indicator.

EDIT page 0 is **SURFACE**, preserving the previous Membrane-layer mapping:

| Physical pot | PLAY | EDIT / SURFACE (page 0) |
| --- | --- | --- |
| TENSION | TENSION | ANISO (-8..+7, center = isotropic) |
| DECAY | DECAY | RIM compliance (fixed -> compliant/free) |
| CHAOS | CHAOS | STRIKE SIZE (point -> broad membrane contact) |
| DRIVE | DRIVE | STRIKE X |
| DELAY | DELAY | STRIKE Y |
| REVERB | REVERB | CHARACTER (Auto / Point / Mallet / Pluck / Rim / Scrape) |

`N_EDIT_PAGES` is a synthesis-time panel-controller generic in the range 1..4.
Only page 0 is populated by issue #85. Higher pages are intentionally inert
until their backing parameter sets land; selecting a reserved page cannot alias
SURFACE registers. The production wrapper currently defaults to one edit page.

## Encoder and LEDs

In **PLAY**, encoder behavior is unchanged: turn selects `preset_index`, short
press recalls, and long press saves. In **EDIT**, encoder A/B instead changes
`edit_page` by one page per detent, wrapping at either end. The preset index is
not touched. The selected page is remembered when returning to PLAY.

Button gestures are disabled in EDIT. A press begun in EDIT stays blocked until
the button is physically released after returning to PLAY, so it cannot become
an accidental preset recall or save.

The four LEDs show the active-voice mask in PLAY. In EDIT they show the page
one-hot: page 0 = `0001`, page 1 = `0010`, page 2 = `0100`, page 3 =
`1000`.

## Soft takeover

A unified scanner reads the currently stored register value before considering
each pot. On reset, preset recall, PLAY/EDIT transition, or EDIT-page change,
all six pots disarm. A pot produces no write until its mapped value crosses the
stored parameter (or lands inside its dead-band), then tracks normally.

That rule also applies when returning to a previously edited page: page
selection alone cannot move any physical parameter. DECAY continues to write
both `sigk1` and `a0`.

## Inputs

Pot ADC samples are assumed synchronous to `clk`. Encoder A/B and its push
button are asynchronous and pass through two-flop synchronisers in
`panel_ctrl`. `arty_synth` connects the physical MODE switch to `edit_mode`;
MIDI/CV source claiming remains automatic in `synth_top`.

## Verification

[`src/tb/panel_ctrl_tb.vhd`](../src/tb/panel_ctrl_tb.vhd) wires `panel_ctrl`
into a real `preset_bank`. It instantiates three edit pages to verify the page
infrastructure even though only SURFACE is populated: contextual encoder
routing, forward/reverse page wrap, remembered page state, one-hot LED state,
inert reserved pages, blocked EDIT button gestures, and soft takeover across
PLAY/EDIT/page transitions. It also regression-checks all PLAY controls,
SURFACE controls, and PLAY preset recall/save.
