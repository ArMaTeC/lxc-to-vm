<!-- ==============================================================================
     ### lxc-to-vm file header ###
     File: AGENTS.md
     Description: AGENTS
     License: MIT
     ============================================================================== -->
# Agent Notes

## Commits

- Do NOT add `Generated with [Devin]` footers or `Co-Authored-By` AI trailers to
  commits in this repository. Commit plainly under the configured git identity.

## Verification

- `bash -n <script>.sh` — syntax check after editing shell scripts
- CI runs ShellCheck (`.github/workflows/shellcheck.yml`) at `severity: error`
- `bash --posix -n` is not required; scripts use bash-isms intentionally
