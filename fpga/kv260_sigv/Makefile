PROJECT_NAME := kv260_sigv
BUILD_DIR := build
PROJECT_DIR := $(BUILD_DIR)/vivado
HW_DIR := $(BUILD_DIR)/hw
VIVADO ?= vivado

.PHONY: project bitstream reports xsa clean

project:
	mkdir -p $(PROJECT_DIR) $(HW_DIR)
	$(VIVADO) -mode batch -source tcl/create_project.tcl -tclargs $(PROJECT_DIR) $(PROJECT_NAME) $(HW_DIR)

bitstream: project
	$(VIVADO) -mode batch -source tcl/build_bitstream.tcl -tclargs $(PROJECT_DIR) $(PROJECT_NAME) $(HW_DIR)

reports: bitstream

xsa: bitstream

clean:
	rm -rf $(BUILD_DIR)
