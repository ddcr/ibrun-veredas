RPM_SOURCEDIR := $(shell echo "`rpm --eval '%{_sourcedir}'`")

.PHONY: clean srpm

# ifeq ("$(wildcard $(RPM_SOURCEDIR)/OHPC_macros)","")
# endif
all: $(RPM_SOURCEDIR)/OHPC_macros srpm

$(RPM_SOURCEDIR)/OHPC_macros: OHPC_macros


srpm:
	rpkg srpm --target noarch --outdir $(PWD)

$(RPM_SOURCEDIR)/%:
	cp -f $< $@

clean:
	@rm *.tar.gz *.src.rpm *.spec
