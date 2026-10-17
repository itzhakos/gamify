CC = x86_64-w64-mingw32-gcc
# Vulkan headers: the ones MoltenVK's fetchDependencies cloned (scripts/build-winecx-full-deps.sh)
VK_INC ?= ../../build/x86_64-full/moltenvk/External/Vulkan-Headers/include
vktest.exe: vktest.c
	$(CC) -O1 -I$(VK_INC) -o $@ $<
clean:
	rm -f vktest.exe
