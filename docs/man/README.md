<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: docs/man/README.md
     Description: Man page sources and build instructions
     License: MIT
     ============================================================================== -->

# Man Page Sources

This directory contains Markdown sources for the project man pages. They can be
rendered to troff with [Pandoc](https://pandoc.org):

```bash
pandoc docs/man/lxc-to-vm.1.md -s -t man -o man1/lxc-to-vm.1
```

Or viewed directly as Markdown in any standard Markdown viewer.

## Available Pages

| Page | Description |
|------|-------------|
| `lxc-to-vm.1.md` | Convert LXC containers to KVM VMs |
| `vm-to-lxc.1.md` | Convert KVM VMs to LXC containers |
| `shrink-lxc.1.md` | Shrink LXC root disk |
| `expand-lxc.1.md` | Expand LXC root disk |
| `shrink-vm.1.md` | Shrink VM disk |
| `expand-vm.1.md` | Expand VM disk |
| `clone-replace-disk.1.md` | Clone and replace VM/LXC disks |
