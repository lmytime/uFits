# libyaml

The parts of [libyaml](https://github.com/yaml/libyaml) 0.2.5 (tag `0.2.5`)
that read YAML: `src/api.c`, `src/reader.c`, `src/scanner.c`, `src/parser.c`,
`src/yaml_private.h` and `include/yaml.h`, unchanged. `config.h` holds the
version, which libyaml's own build would write. uFits uses the event parser
to read the tree of ASDF files (core/fq_asdf.c), as Python's `asdf` does
through PyYAML.

MIT license: [LICENSE](LICENSE).
