// Microphone input: the Switch's audin:u service (nn::audio::detail::IAudioIn) over the host's default recording device.
// The game queues buffers and starts/stops the capture; a thread fills each queued buffer from the device and hands its
// tag back through the release event. Nothing is captured until the game starts it (state 0 = started), and the device
// stream is only opened when the game asks for an input.
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <SDL3/SDL.h>

#include "../hle.h"
#include "../ipc.h"
#include "../kernel.h"

enum { INPUT_QUEUE = 64, MAX_INPUT_BYTES = 1024 * 1024, MAX_INPUTS = 8 };
typedef struct { uint64_t tag, data; uint32_t size; } InputBuffer;
typedef struct {
    uint32_t rate, channels, state, ev_r, ev_w;  // state: 0 capturing, 1 stopped
    float gain, applied_gain;
    SDL_AudioStream *stream;
    KEvent *event;
    pthread_mutex_t lock;
    pthread_t thread;
    atomic_bool quit;
    InputBuffer queued[INPUT_QUEUE];
    uint64_t released[INPUT_QUEUE];
    unsigned count, released_count, completed;
    bool logged_append;
} AudioIn;

static AudioIn *inputs[MAX_INPUTS];
static pthread_mutex_t inputs_lock = PTHREAD_MUTEX_INITIALIZER;

static void device_name_out(IpcReq *req) {
    IpcBuf *b = out_buf(req, 0);
    if (b && b->size) {
        memset((void *)(uintptr_t)b->addr, 0, b->size);
        strncpy((char *)(uintptr_t)b->addr, "BuiltInHeadset", b->size - 1);
    }
}

static void *input_thread(void *arg) {
    AudioIn *a = arg;
    while (!atomic_load(&a->quit)) {
        pthread_mutex_lock(&a->lock);
        if (!a->state && a->count && a->released_count < INPUT_QUEUE) {
            InputBuffer b = a->queued[0];
            float gain = a->gain >= 0.0f && a->gain <= 192.0f ? a->gain : 1.0f;
            if (a->applied_gain != gain) { SDL_SetAudioStreamGain(a->stream, gain); a->applied_gain = gain; }
            int available = SDL_GetAudioStreamAvailable(a->stream);
            if (available >= (int)b.size || available < 0) {
                int n = available < 0 ? 0 : SDL_GetAudioStreamData(a->stream, (void *)(uintptr_t)b.data, (int)b.size);
                if (n < 0) n = 0;
                if ((uint32_t)n < b.size) memset((void *)(uintptr_t)(b.data + n), 0, b.size - (uint32_t)n);
                if (!a->completed++) {
                    const int16_t *samples = (const int16_t *)(uintptr_t)b.data;
                    int peak = 0;
                    for (uint32_t i = 0; i < b.size / 2; i++) {
                        int value = samples[i] < 0 ? -samples[i] : samples[i];
                        if (value > peak) peak = value;
                    }
                    LOG("[audin] first buffer: %d/%u bytes captured, peak %d/32768\n", n, b.size, peak);
                }
                a->released[a->released_count++] = b.tag;
                memmove(a->queued, a->queued + 1, --a->count * sizeof(a->queued[0]));
                pthread_mutex_lock(&g_klock);
                kernel_signal(a->event);
                pthread_mutex_unlock(&g_klock);
            }
        }
        pthread_mutex_unlock(&a->lock);
        struct timespec delay = {0, 2000000};
        nanosleep(&delay, NULL);
    }
    return NULL;
}

static void input_free(AudioIn *a) {
    atomic_store(&a->quit, true);
    pthread_join(a->thread, NULL);
    SDL_DestroyAudioStream(a->stream);
    pthread_mutex_destroy(&a->lock);
    free(a);
}

static void input_close(Service *s) {
    AudioIn *a = s->state;
    bool owned = false;
    pthread_mutex_lock(&inputs_lock);
    for (int i = 0; i < MAX_INPUTS; i++) if (inputs[i] == a) { inputs[i] = NULL; owned = true; }
    pthread_mutex_unlock(&inputs_lock);
    if (owned) { s->state = NULL; input_free(a); LOG("[audin] closed\n"); }
}

RT_ON_RESET(audio_input_reset) {
    pthread_mutex_lock(&inputs_lock);
    for (int i = 0; i < MAX_INPUTS; i++) if (inputs[i]) { input_free(inputs[i]); inputs[i] = NULL; }
    pthread_mutex_unlock(&inputs_lock);
}

static void audio_input(Service *s, IpcReq *req, IpcResp *resp) {
    AudioIn *a = s->state;
    if (!a) { resp->result = MAKE_RESULT(153, 1); return; }
    switch (req->cmd) {
    case 0: pthread_mutex_lock(&a->lock); OUT(uint32_t, 0) = a->state; pthread_mutex_unlock(&a->lock); resp_size(resp, 4); break;
    case 1:  // Start
        pthread_mutex_lock(&a->lock);
        SDL_ClearAudioStream(a->stream);
        if (SDL_ResumeAudioStreamDevice(a->stream)) a->state = 0;
        else resp->result = MAKE_RESULT(153, 1);
        pthread_mutex_unlock(&a->lock);
        LOG("[audin] capture %s\n", resp->result ? "failed to start" : "started");
        break;
    case 2:  // Stop
        pthread_mutex_lock(&a->lock);
        a->state = 1;
        SDL_PauseAudioStreamDevice(a->stream);
        SDL_ClearAudioStream(a->stream);
        pthread_mutex_unlock(&a->lock);
        LOG("[audin] capture stopped\n");
        break;
    case 3: case 8: {  // AppendAudioInBuffer: the buffer descriptor {next, data, capacity, length, offset}
        IpcBuf *b = in_buf(req, 0);
        if (!b || b->size < 0x28 || !b->addr || req->data_size < 8) { resp->result = MAKE_RESULT(153, 1); break; }
        const uint64_t *v = (const uint64_t *)(uintptr_t)b->addr;
        uint64_t capacity = v[2], offset = v[4];
        uint64_t length = v[3] ? v[3] : (offset <= capacity ? capacity - offset : 0);
        if (!v[1] || offset > capacity || length > capacity - offset || !length || length > MAX_INPUT_BYTES ||
            v[1] + offset < v[1]) { resp->result = MAKE_RESULT(153, 1); break; }
        pthread_mutex_lock(&a->lock);
        if (a->count == INPUT_QUEUE) resp->result = MAKE_RESULT(153, 1);
        else {
            a->queued[a->count++] = (InputBuffer){IN(uint64_t, 0), v[1] + offset, (uint32_t)length};
            if (!a->logged_append) { LOG("[audin] queued first %u-byte buffer\n", (unsigned)length); a->logged_append = true; }
        }
        pthread_mutex_unlock(&a->lock);
        break;
    }
    case 4: resp->copy_handles[resp->ncopy++] = a->ev_r; break;  // RegisterBufferEvent
    case 5: case 9: {  // GetReleasedAudioInBuffers
        IpcBuf *b = out_buf(req, 0);
        pthread_mutex_lock(&a->lock);
        unsigned n = a->released_count, max = b ? (unsigned)(b->size / 8) : 0;
        if (n > max) n = max;
        if (n) memcpy((void *)(uintptr_t)b->addr, a->released, n * sizeof(uint64_t));
        memmove(a->released, a->released + n, (a->released_count - n) * sizeof(uint64_t));
        a->released_count -= n;
        pthread_mutex_unlock(&a->lock);
        OUT(uint32_t, 0) = n;
        resp_size(resp, 4);
        break;
    }
    case 6: {  // ContainsAudioInBuffer
        bool found = false;
        uint64_t tag = req->data_size >= 8 ? IN(uint64_t, 0) : 0;
        pthread_mutex_lock(&a->lock);
        for (unsigned i = 0; i < a->count; i++) found |= a->queued[i].tag == tag;
        pthread_mutex_unlock(&a->lock);
        OUT(uint8_t, 0) = found;
        resp_size(resp, 1);
        break;
    }
    case 11: pthread_mutex_lock(&a->lock); OUT(uint32_t, 0) = a->count; pthread_mutex_unlock(&a->lock); resp_size(resp, 4); break;
    case 12: if (req->data_size >= 4) { pthread_mutex_lock(&a->lock); a->gain = IN(float, 0); pthread_mutex_unlock(&a->lock); } break;
    case 13: pthread_mutex_lock(&a->lock); OUT(float, 0) = a->gain; pthread_mutex_unlock(&a->lock); resp_size(resp, 4); break;
    case 14: {  // Flush: every queued buffer goes back as it is
        pthread_mutex_lock(&a->lock);
        unsigned n = 0;
        while (a->count && a->released_count < INPUT_QUEUE) {
            a->released[a->released_count++] = a->queued[0].tag;
            memmove(a->queued, a->queued + 1, --a->count * sizeof(a->queued[0]));
            n++;
        }
        if (n) { pthread_mutex_lock(&g_klock); kernel_signal(a->event); pthread_mutex_unlock(&g_klock); }
        pthread_mutex_unlock(&a->lock);
        OUT(uint8_t, 0) = n != 0;
        resp_size(resp, 1);
        break;
    }
    default: LOG("[audin] unsupported IAudioIn cmd %u\n", req->cmd); resp->result = MAKE_RESULT(153, 1);
    }
}

SERVICE("audin:u", audin_u) {
    (void)s;
    switch (req->cmd) {
    case 0: case 2: case 4:  // ListAudioIns
        device_name_out(req);
        OUT(uint32_t, 0) = 1;
        resp_size(resp, 4);
        break;
    case 1: case 3: case 5: {  // OpenAudioIn: command 5 prefixes the ordinary input configuration with a u64 protocol
        const unsigned param_offset = req->cmd == 5 ? 8 : 0;
        if (req->data_size < param_offset + 8 || !SDL_InitSubSystem(SDL_INIT_AUDIO)) { resp->result = MAKE_RESULT(153, 1); break; }
        AudioIn *a = calloc(1, sizeof *a);
        if (!a) { resp->result = MAKE_RESULT(153, 1); break; }
        a->rate = IN(uint32_t, param_offset);
        if (a->rate < 8000 || a->rate > 192000) a->rate = 48000;
        a->channels = IN(uint32_t, param_offset + 4) & 0xffff;
        if (a->channels != 1 && a->channels != 2) a->channels = 2;
        a->state = 1;
        a->gain = 1.0f;
        a->applied_gain = -1.0f;
        SDL_AudioSpec spec = {SDL_AUDIO_S16, (int)a->channels, (int)a->rate};
        a->stream = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_RECORDING, &spec, NULL, NULL);
        if (!a->stream) {
            LOG("[audin] microphone unavailable: %s\n", SDL_GetError());
            free(a);
            resp->result = MAKE_RESULT(153, 1);
            break;
        }
        pthread_mutex_init(&a->lock, NULL);
        a->event = kernel_create_event_pair(&a->ev_w, &a->ev_r);
        pthread_mutex_lock(&inputs_lock);
        int slot = 0;
        while (slot < MAX_INPUTS && inputs[slot]) slot++;
        if (slot == MAX_INPUTS || pthread_create(&a->thread, NULL, input_thread, a)) {
            pthread_mutex_unlock(&inputs_lock);
            SDL_DestroyAudioStream(a->stream);
            pthread_mutex_destroy(&a->lock);
            free(a);
            resp->result = MAKE_RESULT(153, 1);
            break;
        }
        inputs[slot] = a;
        pthread_mutex_unlock(&inputs_lock);
        device_name_out(req);
        OUT(uint32_t, 0) = a->rate;
        OUT(uint32_t, 4) = a->channels;
        OUT(uint32_t, 8) = 2;   // sample format: PCM int16
        OUT(uint32_t, 12) = 1;  // state
        resp_size(resp, 16);
        Service *svc = service_new("IAudioIn", audio_input, a);
        svc->on_close = input_close;
        ipc_return_object(resp, svc);
        LOG("[audin] microphone opened %u Hz, %u ch (paused)\n", a->rate, a->channels);
        break;
    }
    default: LOG("[audin] unsupported manager cmd %u\n", req->cmd); resp->result = MAKE_RESULT(153, 1);
    }
}
