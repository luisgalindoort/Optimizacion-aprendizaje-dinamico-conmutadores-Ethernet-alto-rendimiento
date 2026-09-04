# FPGA settings
FPGA_PART = xczu9eg-ffvb1156-2-e
FPGA_TOP = fpga
FPGA_ARCH = zynquplus
PROJECT ?= $(FPGA_TOP)

LIB_ROOT = ./../lib

# Top sources
SYN_FILES = ./../rtl/fpga.v
SYN_FILES += ./../rtl/cache_core.v
SYN_FILES += ./../rtl/sync_signal.v

# Support libraries from the reference project
SYN_FILES += $(LIB_ROOT)/axis/rtl/sync_reset.v

SYN_FILES += $(LIB_ROOT)/uart/rtl/uart.v
SYN_FILES += $(LIB_ROOT)/uart/rtl/uart_rx.v
SYN_FILES += $(LIB_ROOT)/uart/rtl/uart_tx.v

SYN_FILES += $(LIB_ROOT)/xfcp/rtl/xfcp_interface_uart.v
SYN_FILES += $(LIB_ROOT)/xfcp/rtl/xfcp_mod_axil.v

SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_register_rd.v
SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_register_wr.v
SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_register.v
SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_reg_if_rd.v
SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_reg_if_wr.v
SYN_FILES += $(LIB_ROOT)/axi/rtl/axil_reg_if.v

SYN_FILES += $(LIB_ROOT)/axis/rtl/axis_cobs_encode.v
SYN_FILES += $(LIB_ROOT)/axis/rtl/axis_cobs_decode.v
SYN_FILES += $(LIB_ROOT)/axis/rtl/axis_fifo.v

# TFG cache model
SYN_FILES += ./../rtl/modulo_hdl_cache.v
SYN_FILES += ./../rtl/hash_table.v
SYN_FILES += ./../rtl/lfsr.v
SYN_FILES += ./../rtl/priority_encoder.v
SYN_FILES += ./../rtl/switch_simple_fifo.v

# XDC files
XDC_FILES = ./fpga.xdc
XDC_FILES += $(LIB_ROOT)/axis/syn/vivado/sync_reset.tcl

# Configuration
CONFIG_TCL_FILES = ./config.tcl

.DEFAULT_GOAL := all

XILINX_VIVADO ?= /opt/Xilinx/Vivado/2023.2
XILINX_VITIS ?= /opt/Xilinx/Vitis/2023.2
VIVADO ?= $(shell if command -v vivado >/dev/null 2>&1; then command -v vivado; elif [ -x "$(XILINX_VIVADO)/bin/vivado" ]; then echo "$(XILINX_VIVADO)/bin/vivado"; else echo vivado; fi)
HW_SERVER ?= $(shell if command -v hw_server >/dev/null 2>&1; then command -v hw_server; elif [ -x "$(XILINX_VITIS)/bin/hw_server" ]; then echo "$(XILINX_VITIS)/bin/hw_server"; else echo hw_server; fi)
PYTHON ?= python3
HW_SERVER_URL ?= TCP:localhost:3121
HW_DEVICE ?= xczu9_0
BIT_FILE ?= $(PROJECT).bit
UART_PORT ?= /dev/serial/by-id/usb-Silicon_Labs_CP2108_Quad_USB_to_UART_Bridge_Controller_75829DA762C2448711E8F4804973CBF-if02-port0
TRACE ?= ../trazas_macs_posibles_metricas_hdl/trace_alpha_0p7_macspace_10000_frames_30000.csv
TRACE_DIR ?= ../trazas_macs_posibles_metricas_hdl
TRACE_PATTERN ?= trace_alpha_*.csv
OUTPUT_CSV ?= ../resultados_fpga_macs_posibles.csv
N_FRAMES ?= 30000
FRAME_GAP_CYCLES ?= 0
LIMIT ?= 0

.PHONY: program
program: $(PROJECT).bit
	@if ! pgrep -x hw_server >/dev/null 2>&1; then \
		echo "Starting hw_server..."; \
		$(HW_SERVER) >/tmp/tfg_hw_server.log 2>&1 & \
		sleep 2; \
	fi
	$(VIVADO) -nojournal -nolog -mode batch -source program_hw.tcl \
		-tclargs "$(HW_SERVER_URL)" "$(HW_DEVICE)" "$(BIT_FILE)"

.PHONY: program-only
program-only:
	@if [ ! -f "$(BIT_FILE)" ]; then \
		echo "No existe $(BIT_FILE). Copia primero un bitstream generado."; \
		exit 1; \
	fi
	@if ! pgrep -x hw_server >/dev/null 2>&1; then \
		echo "Starting hw_server..."; \
		$(HW_SERVER) >/tmp/tfg_hw_server.log 2>&1 & \
		sleep 2; \
	fi
	$(VIVADO) -nojournal -nolog -mode batch -source program_hw.tcl \
		-tclargs "$(HW_SERVER_URL)" "$(HW_DEVICE)" "$(BIT_FILE)"

.PHONY: run
run:
	$(PYTHON) ../scripts/load_trace_and_run.py \
		--uart-port "$(UART_PORT)" \
		--trace-in "$(TRACE)" \
		--n-frames "$(N_FRAMES)" \
		--frame-gap-cycles "$(FRAME_GAP_CYCLES)"

.PHONY: sweep
sweep:
	$(PYTHON) ../scripts/run_fpga_sweep.py \
		--uart-port "$(UART_PORT)" \
		--trace-dir "$(TRACE_DIR)" \
		--pattern "$(TRACE_PATTERN)" \
		--output-csv "$(OUTPUT_CSV)" \
		--n-frames "$(N_FRAMES)" \
		--frame-gap-cycles "$(FRAME_GAP_CYCLES)" \
		--limit "$(LIMIT)"

include ../common/vivado.mk
