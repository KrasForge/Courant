STD     := --std=08
GHDL    := ghdl

RTL_DIR := ../src/rtl
TB_DIR  := ../src/tb

RTL_SRCS := $(wildcard $(RTL_DIR)/*.vhd)
TB_SRCS  := $(wildcard $(TB_DIR)/*.vhd)
ALL_VHDS := $(strip $(RTL_SRCS) $(TB_SRCS))
TB_TOPS  := $(patsubst $(TB_DIR)/%_tb.vhd,%_tb,$(filter %_tb.vhd,$(TB_SRCS)))

.PHONY: all clean

# Import all sources, then let `ghdl -m` analyse each testbench's dependency
# tree in the correct order and elaborate it. Using import/make (-i/-m) rather
# than a single ordered `ghdl -a` keeps the build robust to wildcard/filename
# ordering, so interdependent units (grid_mesh -> node_element -> fdtd_pkg)
# build regardless of alphabetical order.
all:
	@if [ -n "$(ALL_VHDS)" ]; then \
		echo "Importing: $(ALL_VHDS)"; \
		$(GHDL) -i $(STD) $(ALL_VHDS) || exit 1; \
	else \
		echo "No VHDL sources found - skipping."; \
	fi
	@if [ -n "$(TB_TOPS)" ]; then \
		for tb in $(TB_TOPS); do \
			echo "Building: $$tb"; \
			$(GHDL) -m $(STD) $$tb || exit 1; \
			echo "Running: $$tb"; \
			$(GHDL) -r $(STD) $$tb --wave=$$tb.ghw || exit 1; \
		done; \
	else \
		echo "No testbenches found - nothing to simulate."; \
	fi

clean:
	$(GHDL) --remove $(STD) >/dev/null 2>&1 || true
	rm -f *.ghw work-obj*.cf
