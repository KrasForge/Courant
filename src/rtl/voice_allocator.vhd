-------------------------------------------------------------------------------
-- voice_allocator.vhd  -  polyphonic voice allocation with stealing (issue #29)
--
-- Maps note-on / note-off events onto a fixed pool of NVOICES voices (milestone
-- M8). On a note-on it picks a voice and emits a strike to it; on a note-off it
-- frees the voice(s) playing that note so they can be reused (the mesh keeps
-- ringing and decays naturally, so freeing is just "available for reallocation",
-- not silencing).
--
-- Allocation policy, in priority order:
--   1. RETRIGGER  - a voice already playing this exact note is reused (so a
--      repeated key does not consume a second voice);
--   2. FREE       - the lowest-indexed idle voice;
--   3. STEAL      - if all voices are busy, steal the oldest by a round-robin
--      pointer (bounded, deterministic, never divergent).
--
-- One combined event per cycle (note_on and note_off are mutually exclusive per
-- MIDI message). The chosen voice and a one-cycle `strike` pulse are emitted so
-- the voice pool can latch that note's coefficients/excitation and fire it.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity voice_allocator is
  generic (
    NVOICES : positive := 4
  );
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;
    note_on      : in  std_logic;                    -- 1-cycle: note started
    note_off     : in  std_logic;                    -- 1-cycle: note released
    note         : in  std_logic_vector(6 downto 0); -- note number for the event
    strike_voice : out integer range 0 to NVOICES-1; -- voice to (re)strike
    strike       : out std_logic;                    -- 1-cycle: fire strike_voice
    active       : out std_logic_vector(NVOICES-1 downto 0) -- allocated mask
  );
end entity voice_allocator;

architecture rtl of voice_allocator is
  type note_arr is array (0 to NVOICES-1) of unsigned(6 downto 0);
  signal v_note   : note_arr := (others => (others => '0'));
  signal v_active : std_logic_vector(NVOICES-1 downto 0) := (others => '0');
  signal rr_ptr   : integer range 0 to NVOICES-1 := 0;
begin

  active <= v_active;

  process (clk)
    variable target : integer range 0 to NVOICES-1;
    variable found  : boolean;
    variable n      : unsigned(6 downto 0);
  begin
    if rising_edge(clk) then
      if rst = '1' then
        v_note       <= (others => (others => '0'));
        v_active     <= (others => '0');
        rr_ptr       <= 0;
        strike_voice <= 0;
        strike       <= '0';
      else
        strike <= '0';
        n      := unsigned(note);

        if note_on = '1' then
          target := 0;
          found  := false;

          -- 1. retrigger a voice already playing this note
          for i in 0 to NVOICES-1 loop
            if (not found) and v_active(i) = '1' and v_note(i) = n then
              target := i; found := true;
            end if;
          end loop;

          -- 2. otherwise the lowest-indexed free voice
          if not found then
            for i in 0 to NVOICES-1 loop
              if (not found) and v_active(i) = '0' then
                target := i; found := true;
              end if;
            end loop;
          end if;

          -- 3. otherwise steal the round-robin voice
          if not found then
            target := rr_ptr;
            if rr_ptr = NVOICES-1 then rr_ptr <= 0; else rr_ptr <= rr_ptr + 1; end if;
          end if;

          v_note(target)   <= n;
          v_active(target) <= '1';
          strike_voice     <= target;
          strike           <= '1';

        elsif note_off = '1' then
          -- free every voice playing this note (natural decay continues)
          for i in 0 to NVOICES-1 loop
            if v_active(i) = '1' and v_note(i) = n then
              v_active(i) <= '0';
            end if;
          end loop;
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
