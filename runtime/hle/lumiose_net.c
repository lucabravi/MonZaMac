// The network calls the Lumiose module makes (UDP only: its import list has nn::nifm Initialize, IsNetworkAvailable and
// SubmitNetworkRequestAndWait, and nn::socket Initialize, Finalize, Socket, SendTo, RecvFrom and Close), on the host's
// sockets. Bound only while the module is loaded (dispatch.c: hle_lookup_impl), so the game's own behaviour is unchanged.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include "../hle.h"
#include "../devlog.h"

enum { MAX_SOCKETS = 64 };
static int host_fd[MAX_SOCKETS];
static bool used[MAX_SOCKETS];
static unsigned send_notes, recv_notes;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void close_all(void) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < MAX_SOCKETS; i++)
        if (used[i]) close(host_fd[i]), used[i] = false;
    send_notes = recv_notes = 0;
    pthread_mutex_unlock(&lock);
}
RT_ON_RESET(lumiose_net_reset) { close_all(); }

// Caller holds lock until the non-blocking operation completes, preventing fd reuse.
static int host_of(int guest) {
    int fd = -1;
    if (guest >= 0 && guest < MAX_SOCKETS && used[guest]) fd = host_fd[guest];
    return fd;
}

// Nothing leaves the Mac unless LUMIOSE_TEST_NETWORK=1: sends are dropped (reported as sent) and receives are empty.
static pthread_once_t network_once = PTHREAD_ONCE_INIT;
static bool network_enabled;
static void network_init(void) {
    const char *value = getenv("LUMIOSE_TEST_NETWORK");
    network_enabled = value && !strcmp(value, "1");
}
static bool network_on(void) {
    pthread_once(&network_once, network_init);
    return network_enabled;
}

// Switch MSG_DONTWAIT is 0x80; all socket operations are already non-blocking.
// The Switch's sockaddr_in: length, family, port (big endian), address (network order), 8 bytes of padding
typedef struct { uint8_t len, family; uint16_t port; uint32_t addr; uint8_t pad[8]; } SwitchSockAddr;

HLE_FUNC("_ZN2nn4nifm10InitializeEv", nifm_initialize) { c->x[0] = 0; }
HLE_FUNC("_ZN2nn4nifm18IsNetworkAvailableEv", nifm_available) { c->x[0] = 1; }
HLE_FUNC("_ZN2nn4nifm27SubmitNetworkRequestAndWaitEv", nifm_request) { c->x[0] = 0; }
HLE_FUNC("_ZN2nn6socket10InitializeEPvmmi", socket_initialize) { c->x[0] = 0; }
HLE_FUNC("_ZN2nn6socket8FinalizeEv", socket_finalize) { close_all(); c->x[0] = 0; }

HLE_FUNC("_ZN2nn6socket6SocketENS0_6FamilyENS0_4TypeENS0_8ProtocolE", socket_open) {
    int family = (int)c->x[0], type = (int)c->x[1], protocol = (int)c->x[2], guest = -1;
    if (family == 2 && type == 2 && (protocol == 0 || protocol == 17)) {  // AF_INET, SOCK_DGRAM, UDP
        int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd >= 0) {
            int flags = fcntl(fd, F_GETFL, 0);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
                close(fd); c->x[0] = (uint64_t)(int64_t)-1; return;
            }  // The module polls; never allow a blocking fd into the table.
            pthread_mutex_lock(&lock);
            for (int i = 0; i < MAX_SOCKETS && guest < 0; i++)
                if (!used[i]) used[i] = true, host_fd[i] = fd, guest = i;
            pthread_mutex_unlock(&lock);
            if (guest < 0) close(fd);
        }
    }
    c->x[0] = (uint64_t)(int64_t)guest;
}

HLE_FUNC("_ZN2nn6socket5CloseEi", socket_close) {
    int guest = (int)c->x[0], fd = -1;
    pthread_mutex_lock(&lock);
    if (guest >= 0 && guest < MAX_SOCKETS && used[guest]) fd = host_fd[guest], used[guest] = false;
    pthread_mutex_unlock(&lock);
    if (fd >= 0) close(fd);
    c->x[0] = fd >= 0 ? 0 : (uint64_t)(int64_t)-1;
}

HLE_FUNC("_ZN2nn6socket6SendToEiPKvmNS0_7MsgFlagEPKNS0_8SockAddrEj", socket_sendto) {
    const SwitchSockAddr *to = (const SwitchSockAddr *)(uintptr_t)c->x[4];
    if (!to || (uint32_t)c->x[5] < sizeof *to || to->family != 2 ||
        (!c->x[1] && c->x[2]) || c->x[2] > 65507 || (c->x[3] & ~0x80ull) != 0) {
        c->x[0] = (uint64_t)(int64_t)-1; return;
    }
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET, sa.sin_port = to->port, sa.sin_addr.s_addr = to->addr;
    // The test operator pins the destination; do not silently send to a changed module endpoint.
    const char *allowed = getenv("LUMIOSE_TEST_SERVER");
    if (network_on()) {
        char ip[INET_ADDRSTRLEN], endpoint[64];
        inet_ntop(AF_INET, &sa.sin_addr, ip, sizeof ip);
        snprintf(endpoint, sizeof endpoint, "%s:%u", ip, ntohs(sa.sin_port));
        if (!allowed || strcmp(allowed, endpoint)) { c->x[0] = (uint64_t)(int64_t)-1; return; }
    }
    pthread_mutex_lock(&lock);
    int fd = host_of((int)c->x[0]);
    ssize_t n = -1;
    if (fd >= 0) {
        if (!network_on()) n = (ssize_t)c->x[2];
        else n = sendto(fd, (const void *)(uintptr_t)c->x[1], c->x[2], 0,
                        (struct sockaddr *)&sa, sizeof sa);
    }
    if (devlog_on("lumiose-net") && send_notes++ < 8) {
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sa.sin_addr, ip, sizeof ip);
        devlog("lumiose-net", "UDP destination %s:%u bytes %llu result %lld network %s",
               ip, ntohs(sa.sin_port), (unsigned long long)c->x[2], (long long)n,
               network_on() ? "on" : "off");
    }
    pthread_mutex_unlock(&lock);
    c->x[0] = (uint64_t)(int64_t)n;
}

HLE_FUNC("_ZN2nn6socket8RecvFromEiPvmNS0_7MsgFlagEPNS0_8SockAddrEPj", socket_recvfrom) {
    if ((!c->x[1] && c->x[2]) || c->x[2] > INT64_MAX || (c->x[3] & ~0x80ull) != 0) {
        c->x[0] = (uint64_t)(int64_t)-1; return;
    }
    struct sockaddr_in sa = {0};
    socklen_t len = sizeof sa;
    pthread_mutex_lock(&lock);
    int fd = host_of((int)c->x[0]);
    ssize_t n = -1;
    if (fd >= 0 && network_on())
        n = recvfrom(fd, (void *)(uintptr_t)c->x[1], c->x[2], 0, (struct sockaddr *)&sa, &len);
    if (n >= 0 && devlog_on("lumiose-net") && recv_notes++ < 8)
        devlog("lumiose-net", "UDP received %lld bytes", (long long)n);
    pthread_mutex_unlock(&lock);
    SwitchSockAddr *from = (SwitchSockAddr *)(uintptr_t)c->x[4];
    uint32_t *from_len = (uint32_t *)(uintptr_t)c->x[5];
    if (n >= 0 && from && from_len) {
        SwitchSockAddr result = {.len = sizeof result, .family = 2, .port = sa.sin_port, .addr = sa.sin_addr.s_addr};
        size_t copy = *from_len < sizeof result ? *from_len : sizeof result;
        memcpy(from, &result, copy);
        *from_len = sizeof result;
    }
    c->x[0] = (uint64_t)(int64_t)n;
}
