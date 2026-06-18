# Out-of-tree build of the Cirrus CS8409 HDA codec with Apple iMac18,3 support.
# Private HDA headers are bundled under common/ and codecs/ so the only build
# dependency is the matching linux-headers package.
ccflags-y += -I$(src)/common

snd-hda-codec-cs8409-y := codecs/cirrus/cs8409.o codecs/cirrus/cs8409-tables.o
obj-m += snd-hda-codec-cs8409.o
