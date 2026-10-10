# Zstandard decompressor

The unmodified single-file decompressor and public header from
[facebook/zstd v1.5.7](https://github.com/facebook/zstd/tree/v1.5.7), commit
`f8745da6ff1ad1e7bab384bd1f9d742439278e99`, under the BSD license in `LICENSE`.
Only decompression is built; no external Zstandard library is required.

To regenerate `zstddeclib.c`, run in upstream `build/single_file_libs`:

```sh
python3 combine.py -r ../../lib -x legacy/zstd_legacy.h -o zstddeclib.c zstddeclib-in.c
```

Copy the output, `lib/zstd.h`, `lib/zstd_errors.h`, and the root `LICENSE` into this directory.
The generated source disables assembly, legacy formats and tracing, so the
same file builds for both macOS architectures and the portable test tool.
