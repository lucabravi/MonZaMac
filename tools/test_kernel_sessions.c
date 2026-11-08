// Asset-free tests of kernel IPC sessions and Exlaunch's process-handle exchange.
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../runtime/kernel.c"

uint64_t plat_now_ns(void) { struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return (uint64_t)ts.tv_sec*1000000000+ts.tv_nsec; }
void rt_fatal_msg(const char *fmt,...) {(void)fmt;}
void rt_fatal_trace(void) {abort();}
const char *plat_symbol(uint64_t pc,uint64_t *off) {(void)pc;(void)off;return NULL;}
void plat_print_backtrace(void) {}
uint32_t vi_vsync_handle(void) {return 0;}
int ipc_handle_request(Cpu *c,uint32_t h) {(void)c;KObject *o=handle_get(h);return o&&o->type==KOBJ_SESSION?0x1234:R_INVALID_HANDLE;}

static void init_thread(KThread *t,uint32_t *msg) {
 memset(t,0,sizeof *t);t->obj.type=KOBJ_THREAD;t->cpu.tpidrro=(uintptr_t)msg;
 assert(!pthread_cond_init(&t->cond,NULL));
}
static void destroy_thread(KThread *t) {assert(!pthread_cond_destroy(&t->cond));}
typedef struct {KThread thread;uint32_t msg[64];uint32_t client,result;} Sender;
static void *send_main(void *arg) {
 Sender *s=arg;t_cur=&s->thread;s->result=svc_send_sync_request(&s->thread.cpu,s->client,0x100);t_cur=NULL;return NULL;
}
static void start_sender(Sender *s,uint32_t h,uint32_t tag,pthread_t *host) {
 memset(s,0,sizeof *s);init_thread(&s->thread,s->msg);s->client=h;s->msg[0]=4;s->msg[1]=1;s->msg[2]=tag;
 assert(!pthread_create(host,NULL,send_main,s));
}
static void close_handle(uint32_t h) {pthread_mutex_lock(&g_klock);handle_close(h);pthread_mutex_unlock(&g_klock);}
static void await_request(uint32_t server) {
 int32_t index=-1;assert(svc_wait_synchronization((uintptr_t)&server,1,1000000000,&index)==0&&index==0);
}
typedef struct {KThread thread;uint32_t msg[64],server,result;int32_t index;} ReceiverWait;
static void *receive_main(void *arg) {
 ReceiverWait *w=arg;t_cur=&w->thread;
 w->result=session_reply_receive(&w->thread.cpu,&w->server,1,0,1000000000,&w->index);t_cur=NULL;return NULL;
}

static void pair(uint32_t *server,uint32_t *client) {assert(session_create(server,client,false)==0);}

int main(void) {
 uint32_t msg[64]={0};KThread receiver;init_thread(&receiver,msg);t_cur=&receiver;
 uint32_t server,client;pair(&server,&client);Sender a,b;pthread_t ah,bh;int32_t index=-1;
 start_sender(&a,client,17,&ah);await_request(server);start_sender(&b,client,23,&bh);
 assert(session_reply_receive(&receiver.cpu,&server,1,0,1000000000,&index)==0&&index==0&&msg[2]==17);
 msg[2]=117;
 assert(session_reply_receive(&receiver.cpu,&server,1,server,1000000000,&index)==0&&msg[2]==23);
 msg[2]=123;
 assert(session_reply_receive(&receiver.cpu,NULL,0,server,0,&index)==R_TIMEOUT);
 assert(!pthread_join(ah,NULL)&&!pthread_join(bh,NULL));
 assert(a.result==0&&a.msg[2]==117&&b.result==0&&b.msg[2]==123);
 destroy_thread(&a.thread);destroy_thread(&b.thread);close_handle(client);close_handle(server);
 puts("PASS queued requests, exact inline payload, replies and server readiness");

 pair(&server,&client);
 assert(session_reply_receive(&receiver.cpu,&server,1,0,1000000,&index)==R_TIMEOUT);
 start_sender(&a,client,0,&ah);await_request(server);
 pthread_mutex_lock(&g_klock);a.thread.cancel=true;wake(&a.thread);pthread_mutex_unlock(&g_klock);
 assert(!pthread_join(ah,NULL)&&a.result==R_CANCELLED);destroy_thread(&a.thread);
 assert(session_reply_receive(&receiver.cpu,&server,1,0,0,&index)==R_TIMEOUT);
 start_sender(&a,client,0,&ah);await_request(server);close_handle(server);
 assert(!pthread_join(ah,NULL)&&a.result==R_SESSION_CLOSED);destroy_thread(&a.thread);close_handle(client);
 puts("PASS receive timeout, client cancellation and peer-close wakeup");

 pair(&server,&client);memset(&a,0,sizeof a);init_thread(&a.thread,a.msg);a.client=client;
 a.msg[0]=0;a.msg[1]=0x80000000u;a.msg[2]=2;a.msg[3]=PSEUDO_PROCESS;
 assert(!pthread_create(&ah,NULL,send_main,&a));
 assert(session_reply_receive(&receiver.cpu,&server,1,0,1000000000,&index)==0);
 uint32_t process=msg[3];assert(process!=PSEUDO_PROCESS&&handle_get(process)==handle_get(PSEUDO_PROCESS));
 assert(process_handle_is_current(process)&&!process_handle_is_current(server));
 close_handle(server);assert(!pthread_join(ah,NULL)&&a.result==R_SESSION_CLOSED);
 assert(process_handle_is_current(process));close_handle(process);assert(!process_handle_is_current(process));
 close_handle(client);destroy_thread(&a.thread);
 puts("PASS Exlaunch copy-handle transfer and real process-handle lifetime");

 pair(&server,&client);memset(&a,0,sizeof a);init_thread(&a.thread,a.msg);a.client=client;
 a.msg[1]=0x80000000u;a.msg[2]=2;a.msg[3]=0xdead;
 t_cur=&a.thread;assert(svc_send_sync_request(&a.thread.cpu,client,0x100)==R_INVALID_HANDLE);t_cur=&receiver;
 assert(session_reply_receive(&receiver.cpu,&server,1,0,0,&index)==R_TIMEOUT);
 a.msg[1]=0x3ff;assert(svc_send_sync_request(&a.thread.cpu,client,0x100)==R_INVALID_SIZE);
 assert(session_reply_receive(&receiver.cpu,&client,1,0,0,&index)==R_INVALID_HANDLE);
 close_handle(client);assert(session_reply_receive(&receiver.cpu,&server,1,0,0,&index)==R_SESSION_CLOSED);
 close_handle(server);destroy_thread(&a.thread);
 pair(&server,&client);
 KObject event={.type=KOBJ_EVENT};uint32_t source=kernel_new_handle(&event);
 memset(&a,0,sizeof a);init_thread(&a.thread,a.msg);a.client=client;
 a.msg[1]=0x80000000u;a.msg[2]=1u<<5;a.msg[3]=source;
 assert(!pthread_create(&ah,NULL,send_main,&a));
 assert(session_reply_receive(&receiver.cpu,&server,1,0,1000000000,&index)==0);
 uint32_t moved=msg[3];assert(!handle_get(source)&&handle_get(moved)==&event);
 close_handle(server);assert(!pthread_join(ah,NULL)&&a.result==R_SESSION_CLOSED);
 assert(handle_get(moved)==&event);close_handle(moved);close_handle(client);destroy_thread(&a.thread);
 assert(event.refs==0);
 puts("PASS moved handle ownership survives session closure");

 pair(&server,&client);ReceiverWait waiter={.server=server};init_thread(&waiter.thread,waiter.msg);pthread_t wh;
 assert(!pthread_create(&wh,NULL,receive_main,&waiter));
 uint64_t end=plat_now_ns()+1000000000;
 for(;;){
  pthread_mutex_lock(&g_klock);
  if(waiter.thread.in_sync_wait)break;
  pthread_mutex_unlock(&g_klock);assert(plat_now_ns()<end);sched_yield();
 }
 KObject *replacement=calloc(1,sizeof *replacement);assert(replacement);replacement->type=KOBJ_EVENT;
 handle_close(server);uint32_t reused=handle_alloc(replacement);assert(reused==server);kernel_signal(replacement);
 pthread_mutex_unlock(&g_klock);
 assert(!pthread_join(wh,NULL)&&waiter.result==R_INVALID_HANDLE);
 close_handle(reused);close_handle(client);free(replacement);destroy_thread(&waiter.thread);
 puts("PASS receive rejects endpoint slot reuse while blocked");

 KObject service={.type=KOBJ_SESSION};uint32_t sh=kernel_new_handle(&service);
 assert(svc_send_sync_request(&receiver.cpu,sh,0x100)==0x1234);close_handle(sh);
 kernel_reset();assert(!g_session_pairs&&!process_handle_is_current(process));destroy_thread(&receiver);t_cur=NULL;
 puts("PASS malformed messages, wrong endpoints, HLE routing and reset");
}
