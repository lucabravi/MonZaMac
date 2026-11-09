// Synthetic ARM64 veneers only: no module/game bytes or network needed.
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include "../runtime/dispatch.c"
#include "../runtime/lumiose_module.c"

Module g_modules[4];int g_nmodules=2;
void rt_unwind_point(void) {}
void rt_fatal_msg(const char *fmt,...) {(void)fmt;}
void plat_print_backtrace(void) {}
void plat_commit(uint64_t addr,uint64_t size){(void)addr;(void)size;}
void plat_fatal_notice(void) {}
Cpu *kernel_current_cpu(void) {return NULL;}
const char *plat_symbol(uint64_t a,uint64_t *b){(void)a;(void)b;return NULL;}
const char *loader_symbol_at(uint64_t addr,uint64_t *off){(void)addr;(void)off;return NULL;}
bool devlog_on(const char *s){(void)s;return false;}
void devlog(const char *s,const char *fmt,...){(void)s;(void)fmt;}
static void original(Cpu *c){c->x[0]+=3;}
static bool expect_scratch;
static void guest_hook(Cpu *c){if(expect_scratch)assert(c->x[17]==c->pc);c->x[0]=0xabc;}
static uint64_t invoke(uint64_t addr,uint64_t arg){Cpu c={.pc=addr};c.x[0]=arg;rt_dispatch(&c);return c.x[0];}
int main(void){
 uint64_t canonical=hle_register("synthetic-original",original);assert(canonical==HLE_BASE&&invoke(canonical,7)==10);
 assert(mmap((void *)HLE_CODE_BASE,HLE_CODE_SIZE,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON|MAP_FIXED,-1,0)==(void *)HLE_CODE_BASE);
 g_nmodules=3;hle_guest_code_init(true);uint64_t veneer=hle_register("synthetic-original",original);
 assert(veneer==HLE_CODE_BASE&&invoke(veneer,7)==10);assert(!strcmp(hle_name_at(veneer),"synthetic-original"));
 assert(hle_guest_code_range(veneer,0x1000));assert(!hle_guest_code_range(UINT64_MAX-15,32));
 uint64_t addrs[]={HLE_CODE_BASE+0x1000000};GuestFn fns[]={guest_hook};tables[2]=(FnTable){addrs,fns,1,addrs[0],addrs[0]};
 uint32_t copy[1024];memcpy(copy,(void *)veneer,sizeof copy);assert(lumiose_alias_add((uintptr_t)copy,veneer,sizeof copy));
 lumiose_test_store((uintptr_t)copy,0x58000051,4);lumiose_test_store((uintptr_t)copy+4,0xd61f0220,4);
 lumiose_test_store((uintptr_t)copy+8,addrs[0],8);
 assert(invoke(veneer,7)==10); // no half-written hook is visible
 assert(!lumiose_alias_remove((uintptr_t)copy,veneer,sizeof copy-1));
 assert(lumiose_alias_remove((uintptr_t)copy,veneer,sizeof copy));expect_scratch=true;assert(invoke(veneer,7)==0xabc);
 assert(invoke(veneer+16,7)==10&&invoke(veneer+20,7)==10&&invoke(canonical,7)==10);
 // A normal B detour is also recognized.
 memcpy(copy,(void *)veneer,sizeof copy);assert(lumiose_alias_add((uintptr_t)copy,veneer,sizeof copy));
 expect_scratch=false;uint32_t b=0x14000000u|((uint32_t)((addrs[0]-veneer)>>2)&0x3ffffffu);lumiose_test_store((uintptr_t)copy,b,4);
 assert(lumiose_alias_remove((uintptr_t)copy,veneer,sizeof copy)&&invoke(veneer,1)==0xabc);
 // An invalid patch cannot replace a previously committed hook.
 memcpy(copy,(void *)veneer,sizeof copy);assert(lumiose_alias_add((uintptr_t)copy,veneer,sizeof copy));lumiose_test_store((uintptr_t)copy,0,4);
 assert(!lumiose_alias_remove((uintptr_t)copy,veneer,sizeof copy));assert(invoke(veneer,1)==0xabc);
 uint64_t late=hle_register("late-original",original);assert(late==veneer+HLE_CODE_STRIDE&&invoke(late,5)==8);
 assert(!memcmp((unsigned char *)copy+HLE_CODE_STRIDE,(void *)late,HLE_CODE_STRIDE));
 // Native bulk copies into a writable alias must also be committed back before hook publication.
 copy[0]=b;assert(lumiose_alias_remove((uintptr_t)copy,veneer,sizeof copy));assert(invoke(veneer,1)==0xabc);
 uint32_t data[4]={0},left[4],right[4];
 assert(lumiose_alias_add((uintptr_t)left,(uintptr_t)data,sizeof data));assert(lumiose_alias_add((uintptr_t)right,(uintptr_t)data,sizeof data));
 left[0]=0x11112222;right[1]=0x33334444;
 assert(lumiose_alias_remove((uintptr_t)left,(uintptr_t)data,sizeof data));assert(lumiose_alias_remove((uintptr_t)right,(uintptr_t)data,sizeof data));
 assert(data[0]==0x11112222&&data[1]==0x33334444);
 hle_guest_code_init(false);assert(!hle_guest_code_range(veneer,0x1000));assert(!munmap((void *)HLE_CODE_BASE,HLE_CODE_SIZE));
 assert(invoke(veneer,7)==10); // cached native callback addresses remain usable after a vanilla reboot
 puts("PASS HLE veneer, original continuation, atomic hook publication, bounds and vanilla fallback");
}
