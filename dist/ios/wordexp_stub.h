// iOS declares wordexp/wordfree unavailable; Boost.Process only needs them for shell parsing.
#pragma once
#include <wordexp.h>

static inline int lichii_wordexp_stub(const char*, wordexp_t* p, int) {
    p->we_wordc = 0;
    p->we_wordv = nullptr;
    return WRDE_NOSPACE;
}
static inline void lichii_wordfree_stub(wordexp_t*) {}

#define wordexp lichii_wordexp_stub
#define wordfree lichii_wordfree_stub
