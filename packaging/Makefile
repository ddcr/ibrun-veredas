RPM_SOURCEDIR := $(shell echo "`rpm --eval '%{_sourcedir}'`")
RPM_SRCRPMDIR := $(shell echo "`rpm --eval '%{_srcrpmdir}'`")

.PHONY: clean srpm

# ifeq ("$(wildcard $(RPM_SOURCEDIR)/OHPC_macros)","")
# endif
all: $(RPM_SOURCEDIR)/OHPC_macros srpm

$(RPM_SOURCEDIR)/OHPC_macros: OHPC_macros


srpm:
	rpkg srpm --target noarch --outdir=$(RPM_SRCRPMDIR)

$(RPM_SOURCEDIR)/%:
	cp -f $< $@

clean:
	@rm $(RPM_SRCRPMDIR)/ibrun*
