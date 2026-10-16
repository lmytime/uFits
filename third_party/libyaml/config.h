/* libyaml's version, which its build would write here. */
#define YAML_VERSION_MAJOR 0
#define YAML_VERSION_MINOR 2
#define YAML_VERSION_PATCH 5
#define YAML_VERSION_STRING "0.2.5"

/* api.c calls strdup, which glibc declares only for POSIX sources: without
   a declaration the pointer it returns would be cut to an int. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
