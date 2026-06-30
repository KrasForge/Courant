STD     := --std=08
GHDL    := ghdl

RTL_DIR := ../src/rtl
TB_DIR  := ../src/tb

RTL_SRCS := $(wildcard $(RTL_DIR)/*.vhd)
TB_SRCS  := $(wildcard $(TB_DIR)/*.vhd)
ALL_VHDS := $(strip $(RTL_SRCS) $(TB_SRCS))
TB_TOPS  := $(patsubst $(TB_DIR)/%_tb.vhd,%_tb,$(filter %_tb.vhd,$(TB_SRCS)))

.PHONY: all clean

all:
	@if [ -n "$(ALL_VHDS)" ]; then \
		echo "Analysing: $(ALL_VHDS)"; \
		$(GHDL) -a $(STD) $(ALL_VHDS); \
	else \
		echo "No VHDL sources found – skipping analysis."; \
	fi
	@if [ -n "$(TB_TOPS)" ]; then \
		for tb in $(TB_TOPS); do \
			echo "Elaborating: $$tb"; \
			$(GHDL) -e $(STD) $$tb; \
			echo "Running: $$tb"; \
			$(GHDL) -r $(STD) $$tb --wave=$$tb.ghw; \
		done; \
	else \
		echo "No testbenches found – nothing to simulate."; \
	fi

clean:
	rm -f *.ghw work-obj08.cf
