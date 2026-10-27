#import <AVFoundation/AVFoundation.h>
#include <stdbool.h>
#include <stdint.h>

NSError *_Nullable MRInstallTap(AVAudioNode *_Nonnull node, AVAudioNodeBus bus, AVAudioFrameCount size,
                                AVAudioFormat *_Nullable format, AVAudioNodeTapBlock _Nonnull block);

typedef struct MRRing MRRing;

MRRing *_Nullable MRRingCreate(size_t capacity);
void MRRingFree(MRRing *_Nullable ring);
uint64_t MRRingDrops(MRRing *_Nonnull ring);
bool MRRingWrite(MRRing *_Nonnull ring, uint64_t hostTime, const AudioBufferList *_Nonnull list);
bool MRRingRead(MRRing *_Nonnull ring, uint64_t *_Nonnull hostTime, void *_Nonnull dst, size_t dstCapacity,
                size_t *_Nonnull bytes);
