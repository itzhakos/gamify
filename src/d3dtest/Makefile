CC = x86_64-w64-mingw32-gcc
all: d3d11test.exe d3d12test.exe
d3d11test.exe: d3d11test.c
	$(CC) -O1 -o $@ $< -ld3d11 -ldxgi -luser32 -lgdi32
d3d12test.exe: d3d12test.c
	$(CC) -O1 -o $@ $< -ld3d12 -ldxgi -luser32 -lgdi32
clean:
	rm -f d3d11test.exe d3d12test.exe
