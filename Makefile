

all: fetchio

fetchio: msgio.hs fetchio.hs
	ghc -O2 -XDeriveDataTypeable -XScopedTypeVariables --make msgio.hs fetchio.hs

clean:
	-rm -f fetchio *.hi *.o


