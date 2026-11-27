XU ?= $(if $(wildcard ../xu-dev/bin/xu),../xu-dev/bin/xu,xu)
ifneq ($(wildcard ../xu-dev/src/core/elf/mod.xu),)
export XU_STDLIB_ROOT := $(abspath ../xu-dev/src)
endif
CROSS_AS ?= x86_64-elf-as
CROSS_LD ?= x86_64-elf-ld
CROSS_OBJCOPY ?= x86_64-elf-objcopy
QEMU ?= qemu-system-x86_64
PYTHON ?= python3

XU_SRCS := main.xu serial.xu idt.xu pmm.xu vmm.xu heap.xu sched.xu user.xu blk.xu fs.xu font.xu fb.xu input.xu gui.xu shell.xu substrate.xu smp.xu kmeta/mod.xu
DESKTOP_SRCS := userprog/desktop/main.xu userprog/desktop/xdf_sw.xu userprog/desktop/xu.xun

.PHONY: all qemu gui verify clean check debug

all: build/os.elf build/disk.img

debug: build/os64_dbg.elf

build/kernel_xu_dbg.o: $(XU_SRCS) xu.xun | build
	$(XU) build --profile=freestanding --target=x64-none --no-sse -g --emit-obj . -o build/kernel_xu_dbg.o

build/os64_dbg.elf: build/boot.o build/kernel_xu_dbg.o arch/x86_64/linker.ld
	$(CROSS_LD) -T arch/x86_64/linker.ld -z max-page-size=0x1000 -nostdlib build/boot.o build/kernel_xu_dbg.o -o build/os64_dbg.elf

build:
	mkdir -p build

build/kernel_xu.o: $(XU_SRCS) xu.xun | build
	XU_SYMMAP=build/kernel_xu.symmap $(XU) build --profile=freestanding --target=x64-none --chip=x86-64-generic --no-sse --emit-obj . -o build/kernel_xu.o

build/user_hello.o: userprog/hello.xu | build
	$(XU) build --profile=freestanding --target=x64-none --chip=x86-64-generic --emit-obj userprog/hello.xu -o build/user_hello.o

build/hello.elf: build/user_hello.o userprog/linker.ld
	$(CROSS_LD) -T userprog/linker.ld -z max-page-size=0x1000 -nostdlib build/user_hello.o -o build/hello.elf

build/user_fault.o: userprog/fault.xu | build
	$(XU) build --profile=freestanding --target=x64-none --chip=x86-64-generic --emit-obj userprog/fault.xu -o build/user_fault.o

build/fault.elf: build/user_fault.o userprog/linker.ld
	$(CROSS_LD) -T userprog/linker.ld -z max-page-size=0x1000 -nostdlib build/user_fault.o -o build/fault.elf

build/linux_app: userprog/guest_cli.xu | build
	$(XU) build --target=linux-x64 userprog/guest_cli.xu -o build/linux_app

build/macos_app: userprog/guest_cli.xu | build
	$(XU) build --target=macos-x64 userprog/guest_cli.xu -o build/macos_app

build/desktop_linux: $(DESKTOP_SRCS) | build
	$(XU) build --target=linux-x64 userprog/desktop -o build/desktop_linux

build/desktop_macos: $(DESKTOP_SRCS) | build
	$(XU) build --target=macos-x64 userprog/desktop -o build/desktop_macos

build/boot.o: arch/x86_64/boot.S | build
	$(CROSS_AS) --64 arch/x86_64/boot.S -o build/boot.o

build/os64.elf: build/boot.o build/kernel_xu.o arch/x86_64/linker.ld
	$(CROSS_LD) -T arch/x86_64/linker.ld -z max-page-size=0x1000 -nostdlib build/boot.o build/kernel_xu.o -o build/os64.elf

build/os.elf: build/os64.elf
	$(CROSS_OBJCOPY) -O elf32-i386 build/os64.elf build/os.elf

build/disk.img: build/hello.elf build/fault.elf build/linux_app build/macos_app build/desktop_linux build/desktop_macos assets/font.ttf scripts/mkdisk.py | build
	$(PYTHON) scripts/mkdisk.py build/disk.img \
		/bin/hello.elf=build/hello.elf \
		/bin/fault.elf=build/fault.elf \
		/bin/linux_app=build/linux_app \
		/bin/macos_app=build/macos_app \
		/bin/desktop_linux=build/desktop_linux \
		/bin/desktop_macos=build/desktop_macos \
		/etc/font.ttf=assets/font.ttf

check:
	$(XU) check --target=x64-none .
	$(XU) check userprog/desktop

qemu: build/os.elf build/disk.img
	$(QEMU) -m 128M -cpu qemu64 -smp 2 -kernel build/os.elf -drive file=build/disk.img,if=none,format=raw,id=hd0 -device virtio-blk-pci,drive=hd0,disable-modern=on -serial stdio -display none -no-reboot

gui: build/os.elf build/disk.img
	$(QEMU) -M pc,vmport=on -m 128M -cpu qemu64 -smp 2 -vga std -display cocoa -kernel build/os.elf -append ui -drive file=build/disk.img,if=none,format=raw,id=hd0 -device virtio-blk-pci,drive=hd0,disable-modern=on -serial stdio -no-reboot

verify: build/os.elf build/disk.img
	$(PYTHON) scripts/verify_qemu.py

clean:
	rm -rf build
