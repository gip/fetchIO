

all: fetchio

fetchio: msgio.hs fetchio.hs
	ghc -O2 --make msgio.hs fetchio.hs

clean:
	-rm -f fetchio *.hi *.o


