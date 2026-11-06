CC = i686-w64-mingw32-gcc
# 32-bit on purpose: x87sidecar only hooks i386 processes. Same source, two float ABIs.
all: x87bench387.exe x87benchsse.exe
x87bench387.exe: x87bench.c
	$(CC) -O2 -mfpmath=387 -o $@ $<
x87benchsse.exe: x87bench.c
	$(CC) -O2 -msse2 -mfpmath=sse -o $@ $<
clean:
	rm -f x87bench387.exe x87benchsse.exe
