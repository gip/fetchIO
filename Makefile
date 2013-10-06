

all: fetchio

fetchio: msgio.hs fetchio.hs
	ghc -O2 -XScopedTypeVariables --make msgio.hs fetchio.hs

clean:
	-rm -f fetchio *.hi *.o


