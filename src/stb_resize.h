#ifndef GHOSTEL_STB_RESIZE_H
#define GHOSTEL_STB_RESIZE_H

#include <stddef.h>

/* Caller-owned working memory, valid until the resize returns. */
typedef struct {
    void *context;
    void *(*acquire)(void *context, size_t size);
} GhostelResizeScratch;

#endif
