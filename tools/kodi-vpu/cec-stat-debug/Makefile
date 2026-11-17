# Debug build of dw-hdmi-cec with raw status in the ftrace buffer.
obj-m := dw-hdmi-cec.o
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
