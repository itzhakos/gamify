# 32-bit build of src/d3dtest/d3d11test.c (DXVK's i386 d3d11/dxgi, WoW64).
CC = i686-w64-mingw32-gcc
all: d3d11test32.exe
d3d11test32.exe: ../d3dtest/d3d11test.c
	$(CC) -O1 -o $@ $< -ld3d11 -ldxgi -luser32 -lgdi32
clean:
	rm -f d3d11test32.exe
