CC = x86_64-w64-mingw32-gcc
CFLAGS = -municode -O2 -Wall -Wextra -static -mwindows

steamwebhelper.exe: steamwebhelper-shim.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f steamwebhelper.exe
