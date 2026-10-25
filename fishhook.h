// Copyright (c) 2013, Facebook, Inc.
// All rights reserved.

#ifndef FISHHOOK_H
#define FISHHOOK_H

#include <stddef.h>
#include <stdint.h>

#if !defined(FISHHOOK_EXPORT)
#define FISHHOOK_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

FISHHOOK_EXPORT int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

FISHHOOK_EXPORT int rebind_symbols_image(void *header,
                                         intptr_t slide,
                                         struct rebinding rebindings[],
                                         size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif // FISHHOOK_H
