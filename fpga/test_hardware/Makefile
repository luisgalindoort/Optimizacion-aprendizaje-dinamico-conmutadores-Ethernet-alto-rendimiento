# Top-level wrapper, matching the structure of the reference project.

SUBDIRS = fpga
SUBDIRS_CLEAN = $(patsubst %,%.clean,$(SUBDIRS))

.PHONY: all
all: $(SUBDIRS)

.PHONY: $(SUBDIRS)
$(SUBDIRS):
	cd $@ && $(MAKE)

.PHONY: program
program:
	cd fpga && $(MAKE) program

.PHONY: program-only
program-only:
	cd fpga && $(MAKE) program-only

.PHONY: run
run:
	cd fpga && $(MAKE) run

.PHONY: sweep
sweep:
	cd fpga && $(MAKE) sweep

.PHONY: $(SUBDIRS_CLEAN)
$(SUBDIRS_CLEAN):
	cd $(@:.clean=) && $(MAKE) clean

.PHONY: clean
clean: $(SUBDIRS_CLEAN)
