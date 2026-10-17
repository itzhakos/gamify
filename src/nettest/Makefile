all: nettest.exe conntest.exe
nettest.exe: nettest.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $< -lwinhttp -lws2_32
conntest.exe: conntest.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $< -lws2_32
