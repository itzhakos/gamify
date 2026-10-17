CC = x86_64-w64-mingw32-gcc
all: mftest.exe dshowtest.exe
mftest.exe: mftest.c
	$(CC) -O1 -municode -o $@ $< -lmfplat -lmfreadwrite -lmfuuid -lole32 -luuid
dshowtest.exe: dshowtest.c
	$(CC) -O1 -municode -o $@ $< -lstrmiids -lole32 -luuid
clean:
	rm -f mftest.exe dshowtest.exe
