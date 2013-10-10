

SRCFILES= msgio.hs http.hs fetchio.hs

all: fetchio

fetchio: $(SRCFILES)
	ghc -O2 -XDeriveDataTypeable -XScopedTypeVariables --make $(SRCFILES)

clean:
	-rm -f fetchio *.hi *.o


