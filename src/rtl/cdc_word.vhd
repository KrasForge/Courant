-------------------------------------------------------------------------------
-- cdc_word.vhd  -  safe multi-bit clock-domain crossing for one word per frame
--
-- Transfers a WIDTH-bit word from a source clock domain to a destination clock
-- domain, one word per transfer, with no data loss or corruption (README §3,
-- "Clock-domain crossing"). Used both ways in the resonator: the excitation
-- sample (I2S domain -> mesh domain) and the L/R pickup outputs (mesh domain ->
-- I2S domain).
--
-- Strategy (MCP / "synchronised flag + stable data"):
--   * On src_valid the source latches src_data into a holding register and
--     TOGGLES a single request bit `req`.
--   * `req` is the only signal that crosses asynchronously; it goes through a
--     two-flop synchroniser in the destination domain (metastability is
--     resolved in those two flops). A toggle edge in the synchronised `req`
--     means a new word is ready.
--   * On that edge the destination captures the holding register. The data
--     bits themselves are NOT synchronised bit-by-bit (which could tear); they
--     are read only when they are guaranteed stable, because the holding
--     register changed at least the synchroniser latency earlier and does not
--     change again until the next transfer.
--
-- This is safe and deterministic when transfers are spaced wider than the
-- destination synchroniser latency (a few dst clocks). For audio that is always
-- true: one transfer per ~48 kHz frame, both clocks in the MHz range, so the
-- word is stable for thousands of destination cycles. The src_data/holding
-- register read across the boundary is a multi-cycle path for timing closure.
--
-- Synthesisable VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

entity cdc_word is
  generic (
    WIDTH : positive := 24
  );
  port (
    src_clk   : in  std_logic;
    src_rst   : in  std_logic;
    src_data  : in  std_logic_vector(WIDTH-1 downto 0);
    src_valid : in  std_logic;                          -- pulse: send src_data
    dst_clk   : in  std_logic;
    dst_rst   : in  std_logic;
    dst_data  : out std_logic_vector(WIDTH-1 downto 0); -- registered, stable
    dst_valid : out std_logic                           -- pulse: dst_data updated
  );
end entity cdc_word;

architecture rtl of cdc_word is
  signal hold : std_logic_vector(WIDTH-1 downto 0) := (others => '0');  -- src domain
  signal req  : std_logic := '0';                                      -- src domain toggle
  -- destination two-flop synchroniser + edge-detect delay
  signal sync : std_logic_vector(2 downto 0) := (others => '0');
begin

  -- ---- Source domain: latch on valid, toggle the request ------------------
  src_proc : process (src_clk)
  begin
    if rising_edge(src_clk) then
      if src_rst = '1' then
        hold <= (others => '0');
        req  <= '0';
      elsif src_valid = '1' then
        hold <= src_data;
        req  <= not req;
      end if;
    end if;
  end process;

  -- ---- Destination domain: synchronise the flag, capture stable data ------
  dst_proc : process (dst_clk)
  begin
    if rising_edge(dst_clk) then
      if dst_rst = '1' then
        sync      <= (others => '0');
        dst_data  <= (others => '0');
        dst_valid <= '0';
      else
        sync      <= sync(1 downto 0) & req;     -- 2-flop synchroniser (+delay)
        dst_valid <= '0';
        if sync(2) /= sync(1) then                -- toggle edge => new word
          dst_data  <= hold;                      -- stable holding register
          dst_valid <= '1';
        end if;
      end if;
    end if;
  end process;

end architecture rtl;
