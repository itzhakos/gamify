CC = i686-w64-mingw32-gcc
# 32-bit on purpose: the i386 dsound.dll is what 32-bit games (Source engine) load.
all: dsbench.exe
dsbench.exe: dsbench.c
	$(CC) -O1 -o $@ $< -ldsound -luser32
clean:
	rm -f dsbench.exe
