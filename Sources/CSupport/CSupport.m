#import "CSupport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define MR_HEADER 16
#define MR_MAX_RECORD (1u << 20)

NSError *MRInstallTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount size, AVAudioFormat *format,
                      AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:bus bufferSize:size format:format block:block];
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"MeetRec" code:1
                               userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: exception.name}];
    }
    return nil;
}

struct MRRing {
    size_t capacity;
    uint8_t *buffer;
    _Atomic uint64_t head;
    _Atomic uint64_t tail;
    _Atomic uint64_t drops;
};

MRRing *MRRingCreate(size_t capacity) {
    size_t size = 1;
    while (size < capacity) size <<= 1;
    MRRing *ring = calloc(1, sizeof(MRRing));
    if (!ring) return NULL;
    ring->buffer = malloc(size);
    if (!ring->buffer) {
        free(ring);
        return NULL;
    }
    ring->capacity = size;
    return ring;
}

void MRRingFree(MRRing *ring) {
    if (!ring) return;
    free(ring->buffer);
    free(ring);
}

static void copyIn(MRRing *ring, uint64_t pos, const void *src, size_t n) {
    size_t offset = pos & (ring->capacity - 1);
    size_t first = n < ring->capacity - offset ? n : ring->capacity - offset;
    memcpy(ring->buffer + offset, src, first);
    memcpy(ring->buffer, (const uint8_t *)src + first, n - first);
}

static void copyOut(MRRing *ring, uint64_t pos, void *dst, size_t n) {
    size_t offset = pos & (ring->capacity - 1);
    size_t first = n < ring->capacity - offset ? n : ring->capacity - offset;
    memcpy(dst, ring->buffer + offset, first);
    memcpy((uint8_t *)dst + first, ring->buffer, n - first);
}

static void zeroIn(MRRing *ring, uint64_t pos, size_t n) {
    static const uint8_t zeros[256] = {0};
    while (n > 0) {
        size_t chunk = n < sizeof(zeros) ? n : sizeof(zeros);
        copyIn(ring, pos, zeros, chunk);
        pos += chunk;
        n -= chunk;
    }
}

uint64_t MRRingDrops(MRRing *ring) {
    return atomic_load_explicit(&ring->drops, memory_order_relaxed);
}

bool MRRingWrite(MRRing *ring, uint64_t hostTime, const AudioBufferList *list) {
    size_t total = 0;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) total += list->mBuffers[i].mDataByteSize;
    if (total == 0 || total > MR_MAX_RECORD) return false;
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (ring->capacity - (head - tail) < MR_HEADER + total) {
        atomic_fetch_add_explicit(&ring->drops, 1, memory_order_relaxed);
        return false;
    }
    uint8_t header[MR_HEADER] = {0};
    uint32_t size32 = (uint32_t)total;
    memcpy(header, &hostTime, 8);
    memcpy(header + 8, &size32, 4);
    copyIn(ring, head, header, MR_HEADER);
    head += MR_HEADER;
    for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
        const AudioBuffer *b = &list->mBuffers[i];
        if (b->mData) {
            copyIn(ring, head, b->mData, b->mDataByteSize);
        } else {
            zeroIn(ring, head, b->mDataByteSize);
        }
        head += b->mDataByteSize;
    }
    atomic_store_explicit(&ring->head, head, memory_order_release);
    return true;
}

bool MRRingRead(MRRing *ring, uint64_t *hostTime, void *dst, size_t dstCapacity, size_t *bytes) {
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    if (head == tail) return false;
    uint8_t header[MR_HEADER];
    copyOut(ring, tail, header, MR_HEADER);
    uint32_t size32;
    memcpy(hostTime, header, 8);
    memcpy(&size32, header + 8, 4);
    *bytes = 0;
    if (size32 <= dstCapacity) {
        copyOut(ring, tail + MR_HEADER, dst, size32);
        *bytes = size32;
    }
    atomic_store_explicit(&ring->tail, tail + MR_HEADER + size32, memory_order_release);
    return true;
}
