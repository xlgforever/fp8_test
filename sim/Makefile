VCS ?= vcs
TOP ?= tb
DUMP ?= NONE
COMP ?= COMP

DEFINES :=
ifeq ($(DUMP),DUMP)
DEFINES += +define+DUMP
endif
ifeq ($(COMP),COMP)
DEFINES += +define+COMP
endif

VERDI_PLI :=
ifneq ($(strip $(VERDI_HOME)),)
VERDI_PLI += -P $(VERDI_HOME)/share/PLI/VCS/LINUX64/novas.tab
VERDI_PLI += $(VERDI_HOME)/share/PLI/VCS/LINUX64/pli.a
endif

DBG :=
ifeq ($(DUMP),DUMP)
DBG += -debug_all
endif

.PHONY: clean com run sim verdi vectors

clean:
	rm -rf csrc simv simv.daidir ucli.key DVEfiles verdiLog *.log *.vpd *.fsdb *.h vectors_e4m3.txt vectors_e5m2.txt

vectors:
	@echo "[Makefile] generating FP8 test vectors..."
	python3 ../scripts/gen_fp8_vectors.py
	@echo "[Makefile] vector generation complete"

com: vectors
	$(VCS) -full64 -sverilog -timescale=1ns/1ps -kdb $(DBG) $(VERDI_PLI) $(DEFINES) -f tb.vc -top $(TOP) -l vcs_com.log

run:
	./simv -l vcs_sim.log

sim: clean com run

verdi:
	verdi -f tb.vc -ssf wave.fsdb &
