// Synthetic NSO headers and native metadata only; no game/mod code.
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../runtime/lumiose_module.c"

int main(int argc, char **argv) {
    assert(argc == 2);
    char path[] = "/tmp/monzamac-module-XXXXXX";
    int fd = mkstemp(path); assert(fd >= 0);
    unsigned char header[0x60] = {'N','S','O','0'};
    memset(header + 0x40, 0x11, 32);
    assert(write(fd,header,sizeof header)==sizeof header);close(fd);
    setenv("LUMIOSE_TEST_MODULE",path,1);
    void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);assert(lib);
    assert(lumiose_library_matches(lib));
    header[0x40]=0x22;
    FILE *f=fopen(path,"wb");assert(f);assert(fwrite(header,1,sizeof header,f)==sizeof header);fclose(f);
    assert(!lumiose_library_matches(lib));
    unsetenv("LUMIOSE_TEST_MODULE");assert(!lumiose_library_matches(lib));
    dlclose(lib);unlink(path);
    puts("PASS module/library identity match and mismatch rejection");
}
