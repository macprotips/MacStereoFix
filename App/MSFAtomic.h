// MSFAtomic.h
// Tiny C atomic helpers used by RingBuffer.swift. Imported via
// -import-objc-header in build.sh so Swift can call them in real-time
// audio callbacks (no locks, no allocation).

#ifndef MSFAtomic_h
#define MSFAtomic_h

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "Audio callbacks require lock-free atomics");

// MARK: - MSFAtomicU64 (ring-buffer read/write indices)

typedef struct {
    _Atomic uint64_t value;
} MSFAtomicU64;

static inline void msf_atomic_init(MSFAtomicU64 *a, uint64_t v) {
    atomic_init(&a->value, v);
}

static inline void msf_atomic_store(MSFAtomicU64 *a, uint64_t v) {
    atomic_store_explicit(&a->value, v, memory_order_release);
}

static inline uint64_t msf_atomic_load(MSFAtomicU64 *a) {
    return atomic_load_explicit(&a->value, memory_order_acquire);
}

// MARK: - MSFAtomicFloat (gain parameters)
//
// Stores the float's bit pattern in a 32-bit atomic so real-time audio threads
// can read gain values from the UI thread without tearing on any architecture.

typedef struct {
    _Atomic uint32_t bits;
} MSFAtomicFloat;

static inline void msf_atomic_float_init(MSFAtomicFloat *a, float v) {
    uint32_t b;
    memcpy(&b, &v, sizeof(b));
    atomic_init(&a->bits, b);
}

static inline void msf_atomic_float_store(MSFAtomicFloat *a, float v) {
    uint32_t b;
    memcpy(&b, &v, sizeof(b));
    atomic_store_explicit(&a->bits, b, memory_order_release);
}

static inline float msf_atomic_float_load(MSFAtomicFloat *a) {
    uint32_t b = atomic_load_explicit(&a->bits, memory_order_acquire);
    float v;
    memcpy(&v, &b, sizeof(v));
    return v;
}

#endif /* MSFAtomic_h */
