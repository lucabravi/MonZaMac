// Synthetic socket ABI regression; no game or mod input.
#include <assert.h>
#include <stdio.h>
#include "../runtime/hle/lumiose_net.c"

bool devlog_on(const char *subject) { (void)subject; return false; }
void devlog(const char *subject, const char *fmt, ...) { (void)subject; (void)fmt; }

int main(int argc, char **argv) {
    bool online = argc > 1 && !strcmp(argv[1], "loopback");
    if (argc > 1 && !strcmp(argv[1], "disabled")) setenv("LUMIOSE_TEST_NETWORK", "0", 1);
    else if (online) setenv("LUMIOSE_TEST_NETWORK", "1", 1);
    else unsetenv("LUMIOSE_TEST_NETWORK");
    assert(network_on() == online);
    unsetenv("LUMIOSE_TEST_SERVER");
    Cpu c = {0};
    c.x[0] = 2; c.x[1] = 2; c.x[2] = 17;
    socket_open(&c);
    int guest = (int)c.x[0];
    assert(guest >= 0);
    SwitchSockAddr to = {.len = sizeof to, .family = 2};
    char payload[178] = {0};
    c.x[0] = guest;
    c.x[1] = (uintptr_t)payload;
    c.x[2] = sizeof payload;
    c.x[3] = 0;
    c.x[4] = (uintptr_t)&to;
    c.x[5] = sizeof to;
    c.x[6] = 0x816c; // Unrelated caller-saved register, as in the crash.
    if (!online) { socket_sendto(&c); assert(c.x[0] == sizeof payload); }
    c.x[0] = guest; c.x[5] = sizeof to - 1;
    socket_sendto(&c);
    assert((int64_t)c.x[0] == -1);
    c.x[0] = guest; c.x[4] = 0; c.x[5] = sizeof to;
    socket_sendto(&c);
    assert((int64_t)c.x[0] == -1);
    c.x[0] = guest;
    socket_close(&c);
    c.x[0] = 2; c.x[1] = 2; c.x[2] = 17;
    socket_open(&c); guest = (int)c.x[0]; assert(guest >= 0);
    if (online) {
        int peer = socket(AF_INET, SOCK_DGRAM, 0); assert(peer >= 0);
        struct sockaddr_in sa = {.sin_family=AF_INET, .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        assert(bind(peer, (struct sockaddr *)&sa, sizeof sa) == 0);
        socklen_t n = sizeof sa; assert(getsockname(peer, (struct sockaddr *)&sa, &n) == 0);
        struct timeval timeout = {.tv_sec=1};
        assert(setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout) == 0);
        to.addr=sa.sin_addr.s_addr; to.port=sa.sin_port;
        char endpoint[64]; snprintf(endpoint,sizeof endpoint,"127.0.0.1:%u",ntohs(sa.sin_port));
        setenv("LUMIOSE_TEST_SERVER",endpoint,1);
        c.x[0]=guest; c.x[1]=(uintptr_t)payload; c.x[2]=sizeof payload;
        c.x[4]=(uintptr_t)&to; c.x[5]=sizeof to;
        setenv("LUMIOSE_TEST_SERVER","127.0.0.1:0",1);
        socket_sendto(&c); assert((int64_t)c.x[0] == -1);
        unsetenv("LUMIOSE_TEST_SERVER"); c.x[0]=guest;
        socket_sendto(&c); assert((int64_t)c.x[0] == -1);
        setenv("LUMIOSE_TEST_SERVER",endpoint,1); c.x[0]=guest;
        socket_sendto(&c); assert(c.x[0] == sizeof payload);
        char data[256]; struct sockaddr_in source; n=sizeof source;
        assert(recvfrom(peer,data,sizeof data,0,(struct sockaddr *)&source,&n)==sizeof payload);
        assert(!memcmp(data,payload,sizeof payload));
        assert(sendto(peer,"reply",5,0,(struct sockaddr *)&source,n)==5);
        SwitchSockAddr from={0}; uint32_t size=sizeof from;
        c.x[3]=0x80; // Switch MSG_DONTWAIT, used by the actual module.
        c.x[0]=guest; c.x[1]=(uintptr_t)data; c.x[2]=sizeof data;
        c.x[4]=(uintptr_t)&from; c.x[5]=(uintptr_t)&size;
        for(int i=0;i<100;i++) {
            c.x[0]=guest; socket_recvfrom(&c);
            if((int64_t)c.x[0]>=0) break;
            usleep(1000);
        }
        assert(c.x[0]==5 && !memcmp(data,"reply",5));
        assert(from.family==2 && from.port==to.port && from.addr==to.addr && size==sizeof from);
        c.x[0]=guest; socket_recvfrom(&c); assert((int64_t)c.x[0]==-1);
        close(peer);
    }
    socket_finalize(&c);
    c.x[0]=guest; socket_close(&c); assert((int64_t)c.x[0]==-1);
    c.x[0]=2;c.x[1]=2;c.x[2]=17;socket_open(&c);guest=(int)c.x[0];assert(guest>=0);
    lumiose_net_reset(); c.x[0]=guest;socket_close(&c);assert((int64_t)c.x[0]==-1);
    // Finalize must release the complete table, not just the most recent handle.
    for(int i=0;i<MAX_SOCKETS;i++) {
        c.x[0]=2;c.x[1]=2;c.x[2]=17;socket_open(&c);assert((int)c.x[0]>=0);
    }
    c.x[0]=2;c.x[1]=2;c.x[2]=17;socket_open(&c);assert((int64_t)c.x[0]==-1);
    socket_finalize(&c);
    c.x[0]=2;c.x[1]=2;c.x[2]=17;socket_open(&c);assert((int)c.x[0]>=0);
    lumiose_net_reset();
    printf("lumiose sockets: ok (%s)\n", online ? "loopback UDP" : "offline");
}
