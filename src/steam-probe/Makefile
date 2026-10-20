CC = x86_64-w64-mingw32-gcc
CFLAGS = -O2 -Wall -Wextra -static

steam-probe.exe: steam-probe.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f steam-probe.exe
