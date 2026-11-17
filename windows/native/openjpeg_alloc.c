/*
 * Allocator for the bundled OpenJPEG, built in place of opj_malloc.c. Every block carries a
 * 16 byte header and is charged to a per-thread budget, so a small hostile header cannot make
 * the decoder allocate gigabytes: past the budget an allocation returns NULL.
 */
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "opj_malloc.h"

#define EXPORT __declspec(dllexport)
#define HEADER 16U

typedef struct {
    size_t charged;
    void *raw;
} header_t;

static __declspec(thread) size_t used_bytes;
static __declspec(thread) size_t limit_bytes;

EXPORT void lazypdf_opj_budget(size_t bytes)
{
    limit_bytes = bytes;
}

EXPORT size_t lazypdf_opj_used(void)
{
    return used_bytes;
}

static int charge(size_t n)
{
    if (limit_bytes != 0 && (n > limit_bytes || used_bytes > limit_bytes - n)) {
        return 0;
    }
    used_bytes += n;
    return 1;
}

static void refund(size_t n)
{
    used_bytes = n > used_bytes ? 0 : used_bytes - n;
}

static header_t *header_of(void *user)
{
    return (header_t *)((char *)user - HEADER);
}

static void *alloc_aligned(size_t alignment, size_t size, int zero)
{
    size_t total;
    char *raw, *user;
    if (size == 0U || size > SIZE_MAX - alignment - HEADER) {
        return NULL;
    }
    total = size + alignment + HEADER;
    if (!charge(total)) {
        return NULL;
    }
    raw = (char *)(zero ? calloc(1, total) : malloc(total));
    if (raw == NULL) {
        refund(total);
        return NULL;
    }
    user = (char *)(((uintptr_t)raw + HEADER + alignment - 1U) & ~(uintptr_t)(alignment - 1U));
    header_of(user)->charged = total;
    header_of(user)->raw = raw;
    return user;
}

static size_t user_size(void *user)
{
    header_t *h = header_of(user);
    return h->charged - (size_t)((char *)user - (char *)h->raw);
}

static void free_block(void *user)
{
    header_t *h;
    if (user == NULL) {
        return;
    }
    h = header_of(user);
    refund(h->charged);
    free(h->raw);
}

static void *realloc_aligned(void *ptr, size_t alignment, size_t size)
{
    void *fresh;
    size_t old;
    if (ptr == NULL) {
        return alloc_aligned(alignment, size, 0);
    }
    if (size == 0U) {
        return NULL;
    }
    fresh = alloc_aligned(alignment, size, 0);
    if (fresh == NULL) {
        return NULL;
    }
    old = user_size(ptr);
    memcpy(fresh, ptr, old < size ? old : size);
    free_block(ptr);
    return fresh;
}

void *opj_malloc(size_t size)
{
    return alloc_aligned(16U, size, 0);
}

void *opj_calloc(size_t num, size_t size)
{
    if (num == 0 || size == 0 || num > SIZE_MAX / size) {
        return NULL;
    }
    return alloc_aligned(16U, num * size, 1);
}

void *opj_realloc(void *ptr, size_t size)
{
    return realloc_aligned(ptr, 16U, size);
}

void opj_free(void *ptr)
{
    free_block(ptr);
}

void *opj_aligned_malloc(size_t size)
{
    return alloc_aligned(16U, size, 0);
}

void *opj_aligned_realloc(void *ptr, size_t size)
{
    return realloc_aligned(ptr, 16U, size);
}

void opj_aligned_free(void *ptr)
{
    free_block(ptr);
}

void *opj_aligned_32_malloc(size_t size)
{
    return alloc_aligned(32U, size, 0);
}

void *opj_aligned_32_realloc(void *ptr, size_t size)
{
    return realloc_aligned(ptr, 32U, size);
}
