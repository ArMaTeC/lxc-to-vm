<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: add-file-headers.md
     Description: Documentation for the file header automation tool
     License: MIT
     ============================================================================== -->

# add-file-headers.sh

Automatically adds, detects, and replaces file headers across the project.

## Overview

This script ensures every file in the project has a consistent, descriptive header explaining its purpose. It can:

- **Add headers** to files that don't have one
- **Replace outdated headers** with the current project standard
- **Skip files** that already have the correct header
- **Preview changes** without modifying anything
- **Check for needed updates** in CI/CD pipelines

## Usage

```bash
# Apply headers to all files
./add-file-headers.sh

# Preview changes without modifying files
./add-file-headers.sh --dry-run

# Check if any files need updates (CI-friendly)
./add-file-headers.sh --check

# Show help
./add-file-headers.sh --help
```

## Options

| Option | Description |
| ------ | ----------- |
| `--dry-run` | Preview changes without writing to disk |
| `--check` | Report files needing updates; exits 1 if any found |
| `--help` | Show help message |

## Exit Codes

| Code | Meaning |
| ---- | ------- |
| 0 | Success (or `--check`: all files up-to-date) |
| 1 | General error or `--check` found outdated headers |
| 2 | Invalid argument |

## Supported File Types

- Shell scripts (`.sh`, `.bash`)
- Markdown (`.md`)
- YAML (`.yml`, `.yaml`)
- PowerShell (`.ps1`)
- Text/config (`.txt`, `.cfg`, `.conf`)
- Special files: `.gitignore`, `Makefile`, `Dockerfile`

Binary files are automatically skipped.

## Header Format

### Shell / YAML / Config Files

```bash
# ==============================================================================
# ### lxc-to-vm file header ###
# File: example.sh
# Description: Brief description of what this file does
# License: MIT
# ==============================================================================
```

### Markdown Files

```markdown
<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: README.md
     Description: Project documentation and usage guide
     License: MIT
     ============================================================================== -->
```

## How It Works

1. **Scans** all files in the project directory and subdirectories
2. **Skips** binary files and unsupported file types
3. **Preserves** shebang lines (`#!/bin/bash`) and shellcheck directives at the top
4. **Detects** if a file already has the project header (by looking for `### lxc-to-vm file header ###`)
5. **Replaces** any existing header that doesn't contain the marker
6. **Prepends** a new header to files without one

## CI/CD Integration

Add this to your GitHub Actions workflow to ensure all files have headers:

```yaml
- name: Check file headers
  run: ./add-file-headers.sh --check
```

The `--check` flag returns exit code 1 if any files need updates, failing the build.

## Safety

- The script uses temporary files and atomic `mv` operations — your original files are never partially overwritten
- `--dry-run` lets you review all changes before applying them
- Files with the current standard header are never modified
