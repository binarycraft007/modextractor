# modextractor

`modextractor` is a zero dependency command-line utility that extracts kernel modules and firmware information required for a given device tree blob (DTB). It inspects the DTB to find necessary kernel modules and also scans the kernel modules themselves for firmware dependencies.

This is useful for creating a minimal initramfs with `mkinitcpio`.

## Building

To build `modextractor`, run the following command:

```sh
zig build
```

## Usage

The basic usage is as follows:

```sh
./modextractor <module_dir> <dtb_file1> [<dtb_file2> ...]
```

- `<module_dir>`: The directory where the kernel modules are located (e.g., `/usr/lib/modules/$(uname -r)`).
- `<dtb_file1> ...`: One or more device tree blob files to analyze.

The output is a configuration file for `mkinitcpio` that can be placed in `/etc/mkinitcpio.conf.d/`.

### Example

```sh
./modextractor /usr/lib/modules/$(uname -r) /boot/dtbs/qcom/x1e*.dtb > /etc/mkinitcpio.conf.d/modextractor.conf
```
