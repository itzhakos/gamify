# Direct3D 9 smoke test, 32-bit (most DX9 games) and 64-bit.
all: d3d9test.exe d3d9test64.exe
d3d9test.exe: d3d9test.c
	i686-w64-mingw32-gcc -O1 -o $@ $< -ld3d9 -luser32 -lgdi32
d3d9test64.exe: d3d9test.c
	x86_64-w64-mingw32-gcc -O1 -o $@ $< -ld3d9 -luser32 -lgdi32
clean:
	rm -f d3d9test.exe d3d9test64.exe
