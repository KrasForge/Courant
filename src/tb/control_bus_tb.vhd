-------------------------------------------------------------------------------
-- control_bus_tb.vhd  -  register read/write and mesh response under bus control
--
-- Drives a grid_mesh's coefficients from control_bus and checks:
--   1. every register is runtime read/writable (write distinct values, read back);
--   2. with the reference coefficients written over the bus, a centred impulse
--      on a 9x9 mesh reproduces the golden impulse response bit-for-bit
--      (src/tb/mesh_impulse_trace.txt), proving the bus distributes the
--      coefficients correctly to the mesh;
--   3. changing a coefficient over the bus (gamma2) changes the response,
--      i.e. coefficients are audibly reconfigurable at runtime.
--
-- VHDL-2008.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

library work;
use work.fdtd_pkg.all;

entity control_bus_tb is
end entity control_bus_tb;

architecture sim of control_bus_tb is

  constant CLK_PERIOD : time     := 10 ns;
  constant NX         : positive := 9;
  constant NY         : positive := 9;
  constant STEPS      : positive := 128;

  signal clk    : std_logic := '0';
  signal c_rst  : std_logic := '1';      -- control-bus reset (init only)
  signal m_rst  : std_logic := '1';      -- mesh reset (pulsed between configs)

  signal wr_en   : std_logic := '0';
  signal wr_addr : unsigned(3 downto 0) := (others => '0');
  signal wr_data : std_logic_vector(23 downto 0) := (others => '0');
  signal rd_addr : unsigned(3 downto 0) := (others => '0');
  signal rd_data : std_logic_vector(23 downto 0);

  signal coeffs  : coeffs_t;
  signal plx, ply, prx, pry : unsigned(5 downto 0);

  signal strobe : std_logic := '0';
  signal exc_in : q123_t := (others => '0');
  signal exc_en : std_logic := '0';
  signal pick_l : q123_t;
  signal pick_r : q123_t;
  signal valid  : std_logic;

  signal done : boolean := false;

  type iarr is array (0 to STEPS-1) of integer;

  -- distinct 24-bit test words for the register read/write check (regs 0..8)
  type rtbl_t is array (0 to 8) of integer;
  constant RTBL : rtbl_t :=
    (8388607, -8388608, 1234567, -1234567, 5592405, -5592406, 21, 42, 63);

begin

  clk_gen : process
  begin
    while not done loop
      clk <= '0'; wait for CLK_PERIOD/2;
      clk <= '1'; wait for CLK_PERIOD/2;
    end loop;
    wait;
  end process;

  watchdog : process
  begin
    wait for 20 ms;
    assert done report "control_bus_tb: timeout" severity failure;
    wait;
  end process;

  ctrl : entity work.control_bus
    port map (clk => clk, rst => c_rst, wr_en => wr_en, wr_addr => wr_addr,
              wr_data => wr_data, rd_addr => rd_addr, rd_data => rd_data,
              coeffs => coeffs, pick_lx => plx, pick_ly => ply,
              pick_rx => prx, pick_ry => pry);

  mesh : entity work.grid_mesh
    generic map (NX => NX, NY => NY, FREE_BOUNDARY => false)
    port map (clk => clk, rst => m_rst, strobe => strobe, coeffs => coeffs,
              exc_in => exc_in, exc_en => exc_en,
              pick_l => pick_l, pick_r => pick_r, valid => valid);

  stim : process

    procedure bus_write(a : natural; d : std_logic_vector(23 downto 0)) is
    begin
      wait until rising_edge(clk);
      wr_en <= '1'; wr_addr <= to_unsigned(a, 4); wr_data <= d;
      wait until rising_edge(clk);
      wr_en <= '0';
    end procedure;

    procedure write_ref_coeffs(g2 : real) is
    begin
      bus_write(0, std_logic_vector(to_q123(g2)));
      bus_write(1, std_logic_vector(to_q123(0.99996875)));
      bus_write(2, std_logic_vector(to_q123(0.99996875)));
      bus_write(3, std_logic_vector(to_q123(0.0)));
      bus_write(4, std_logic_vector(to_q123(0.5)));
    end procedure;

    -- reset the mesh, strike a centred impulse, capture pick_l into cap
    procedure run_impulse(variable cap : out iarr) is
      constant IMP : q123_t := to_q123(0.5);
    begin
      m_rst <= '1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      m_rst <= '0';
      wait until rising_edge(clk);
      for k in 0 to STEPS-1 loop
        wait until rising_edge(clk);
        strobe <= '1';
        if k = 0 then exc_in <= to_q123(0.5); exc_en <= '1'; end if;
        wait until rising_edge(clk);
        strobe <= '0';
        exc_en <= '0';
        wait until rising_edge(clk) and valid = '1';
        cap(k) := to_integer(pick_l);
      end loop;
    end procedure;

    file     ft   : text;
    variable st   : file_open_status;
    variable l    : line;
    variable good : boolean;
    variable gL, gR : integer;
    variable capA, capB : iarr;
    variable differs : boolean := false;
  begin
    -- release control-bus reset; mesh stays reset until run_impulse
    wait until rising_edge(clk);
    wait until rising_edge(clk);
    c_rst <= '0';

    --------------------------------------------------------------------------
    -- 1. register read/write
    --------------------------------------------------------------------------
    for i in 0 to 8 loop
      bus_write(i, std_logic_vector(to_signed(RTBL(i), 24)));
    end loop;
    for i in 0 to 8 loop
      wait until rising_edge(clk);
      rd_addr <= to_unsigned(i, 4);
      wait until rising_edge(clk);
      wait until rising_edge(clk);                 -- registered read latency
      assert to_integer(signed(rd_data)) = RTBL(i)
        report "register " & integer'image(i) & " readback = " &
               integer'image(to_integer(signed(rd_data))) & ", expected " &
               integer'image(RTBL(i))
        severity failure;
    end loop;

    --------------------------------------------------------------------------
    -- 2. reference coefficients over the bus -> bit-exact golden response
    --------------------------------------------------------------------------
    write_ref_coeffs(0.09);
    run_impulse(capA);

    file_open(st, ft, "../src/tb/mesh_impulse_trace.txt", read_mode);
    assert st = open_ok report "cannot open mesh_impulse_trace.txt" severity failure;
    for k in 0 to STEPS-1 loop
      loop
        readline(ft, l);
        read(l, gL, good);
        exit when good;
      end loop;
      read(l, gR);
      assert capA(k) = gL
        report "config A step " & integer'image(k) & ": pick_l = " &
               integer'image(capA(k)) & ", golden = " & integer'image(gL)
        severity failure;
    end loop;
    file_close(ft);

    --------------------------------------------------------------------------
    -- 3. change gamma2 over the bus -> the response must change
    --------------------------------------------------------------------------
    write_ref_coeffs(0.20);                         -- higher base stiffness
    run_impulse(capB);
    for k in 0 to STEPS-1 loop
      if capB(k) /= capA(k) then differs := true; end if;
    end loop;
    assert differs
      report "changing gamma2 over the bus did not change the mesh response"
      severity failure;

    report "control_bus_tb: all checks passed (registers read/write, bus-driven " &
           "coefficients bit-exact, reconfiguration changes response)"
      severity note;
    done <= true;
    finish;
  end process;

end architecture sim;
