# Contributing to Deadlock RPC (Ruby Edition)

## How to Contribute

### Reporting Bugs

Check [existing issues](https://github.com/buntatoes/deadlock-rpc-ruby/issues) before opening a new one. A good bug report includes:
- Steps to reproduce
- Expected vs actual behavior
- OS (Windows `.exe` installer or Linux), Ruby version, and Deadlock RPC version

### Suggesting Features

Open an issue describing the problem you are trying to solve and your proposed solution.

### Submitting Code

Look for issues labeled `good first issue` or `help wanted` as a starting point.

## Development Setup

**Requirements:** [Ruby 3.2+](https://www.ruby-lang.org/) (tested on Ruby 3.4). Zero external gems required.

```bash
git clone https://github.com/buntatoes/deadlock-rpc-ruby.git
cd deadlock-rpc-ruby

# Create a branch
git checkout -b feature/your-feature-name

# Syntax check
ruby -c bin/deadlock-rpc lib/deadlock_rpc.rb lib/deadlock_rpc/*.rb scripts/package.rb test/test_deadlock_rpc.rb

# Run unit tests
ruby -Ilib:test test/test_deadlock_rpc.rb

# Build Windows (.exe installer) and Linux (.tar.gz) packages
ruby scripts/package.rb

# Run directly
ruby bin/deadlock-rpc --no-launch
```

## Pull Request Process

1. Rebase onto `main` before submitting
2. Ensure all Ruby syntax checks and Minitest unit tests pass with zero warnings
3. Open a PR against `main` and describe what changed and why

## License

All contributions are licensed under the **GNU General Public License v3.0 ([GPL-3.0](LICENSE))**.
