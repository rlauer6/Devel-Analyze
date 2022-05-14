
MODULE = Devel::Analyze

PERL_MODULES = \
    lib/Devel/Analyze.pm

PERL_SCRIPTS = \
    bin/analyze.pl

UNIT_TESTS =

TARBALL = Devel-Analyze.tar.gz

all: README.md $(TARBALL)

$(TARBALL): $(PERL_MODULES) $(PERL_SCRIPTS) requires
	 make-cpan-dist \
	   -e bin \
	   -l lib \
	   -m $(MODULE) \
	   -a 'Rob Lauer <rlauer6@comcast.net>' \
	   -d 'analyze a set of Perl scripts and modules' \
	   -c \
	   -r requires \
	cp $$(ls -1rt *.tar.gz | tail -1) $@

README.md: $(PERL_MODULES)
	pod2markdown $< > $@ || rm -f $@

.PHONY: check

check: $(PERL_MODULES)
	PERL5LIB=$(builddir)/lib perl -wc $(PERL_MODULES)
	perlcritic -1 $(PERL_MODULES)
	$(MAKE) test

test: $(TESTS)
	prove -v t/

install: $(TARBALL)
	cpanm -v $<

clean:
	rm -f $(TARBALL)
