// Store-buffering litmus using the guest CPU helpers. STLR followed by LDAR
// on both threads forbids both loads observing zero. Scheduling makes this a
// stress check; test_cpu_ordering.py also checks the generated instructions.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include "cpu.h"

enum { ITERATIONS = 1000000 };
static _Alignas(128) uint64_t a, b;
static _Alignas(128) atomic_int phase;
static _Alignas(128) atomic_int done[2];
static uint64_t result[2];

static void *worker(void *arg) {
    int id = (int)(intptr_t)arg;
    uint64_t own = (uintptr_t)(id ? &b : &a);
    uint64_t other = (uintptr_t)(id ? &a : &b);
    for (int i = 1; i <= ITERATIONS; i++) {
        while (atomic_load_explicit(&phase, memory_order_acquire) != i) {}
        stl64(own, 1);
        result[id] = lda64(other);
        atomic_store_explicit(&done[id], i, memory_order_release);
    }
    return NULL;
}

int main(void) {
    pthread_t threads[2];
    if (pthread_create(&threads[0], NULL, worker, (void *)(intptr_t)0) ||
        pthread_create(&threads[1], NULL, worker, (void *)(intptr_t)1)) return 2;
    unsigned forbidden = 0;
    for (int i = 1; i <= ITERATIONS; i++) {
        __atomic_store_n(&a, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&b, 0, __ATOMIC_RELAXED);
        atomic_store_explicit(&phase, i, memory_order_release);
        while (atomic_load_explicit(&done[0], memory_order_acquire) != i ||
               atomic_load_explicit(&done[1], memory_order_acquire) != i) {}
        forbidden += result[0] == 0 && result[1] == 0;
    }
    pthread_join(threads[0], NULL);
    pthread_join(threads[1], NULL);
    printf("%d iterations: %u forbidden store/load outcomes\n", ITERATIONS, forbidden);
    return forbidden ? 1 : 0;
}
