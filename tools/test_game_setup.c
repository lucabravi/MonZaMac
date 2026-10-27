// Asset-free setup filesystem checks. Only a private temporary data root is touched.
#include "paths.h"
#include "gamelib.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>

static void put(const char *p) { FILE *f = fopen(p, "w"); assert(f); fputs("keep", f); fclose(f); }
static int has(const char *p) { return access(p, F_OK) == 0; }
int main(int argc, char **argv) {
    rt_paths_init();
    char stage[1200], why[256] = "";
    if (argc > 1 && !strcmp(argv[1], "hold")) { put("helper-ready"); for (;;) pause(); }
    if (argc > 1) return rt_game_setup_begin("extracted",false, stage, sizeof stage, why, sizeof why) ? 1 : 0;
    mkdir("save",0700); put("save/sentinel"); put("larecomp.ini");
    assert(rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    char p[1400]; snprintf(p,sizeof p,"%s/.gamebuild",stage); mkdir(p,0700);
    assert(rt_remove_game_file(stage,".gamebuild")); assert(!has(p));
    assert(rt_game_setup_end(false,why,sizeof why)); assert(!has("extracted"));
    assert(has("save/sentinel") && has("larecomp.ini"));
    assert(!rt_game_setup_begin("outside",false,stage,sizeof stage,why,sizeof why));
    assert(rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    mkdir("extracted",0700); put("extracted/arrived-during-setup");
    assert(!rt_game_setup_end(true,why,sizeof why));
    assert(has("extracted/arrived-during-setup"));
    unlink("extracted/arrived-during-setup"); rmdir("extracted");
    mkdir(".game-setup",0700); put(".game-setup/personal");
    assert(!rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    assert(has(".game-setup/personal")); unlink(".game-setup/personal"); rmdir(".game-setup");
    // Interrupted owned staging is cleaned on retry.
    pid_t pid=fork(); assert(pid>=0);
    if (!pid) { assert(rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why)); _exit(0); }
    int status; waitpid(pid,&status,0); assert(WIFEXITED(status) && !WEXITSTATUS(status));
    assert(rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    pid=fork(); assert(pid>=0);
    if (!pid) { execl(argv[0],argv[0],"locked",NULL); _exit(2); }
    waitpid(pid,&status,0); assert(WIFEXITED(status) && !WEXITSTATUS(status));
    assert(rt_game_setup_end(false,why,sizeof why));
    // A killed app's exec'd helper must retain exclusion until it stops.
    int pipefd[2]; assert(!pipe(pipefd));
    pid=fork(); assert(pid>=0);
    if (!pid) {
        close(pipefd[0]);
        assert(rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
        pid_t helper=fork(); assert(helper>=0);
        if (!helper) { execl(argv[0],argv[0],"hold",NULL); _exit(2); }
        assert(write(pipefd[1],&helper,sizeof helper)==sizeof helper); _exit(0);
    }
    close(pipefd[1]); pid_t helper;
    assert(read(pipefd[0],&helper,sizeof helper)==sizeof helper); close(pipefd[0]);
    waitpid(pid,&status,0);
    for (int i=0; i<200 && !has("helper-ready"); i++) usleep(10000);
    assert(has("helper-ready"));
    bool incorrectly_unlocked=rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why);
    kill(helper,SIGTERM);
    assert(!incorrectly_unlocked);
    bool recovered=false;
    for (int i=0;i<200 && !(recovered=rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));i++) usleep(10000);
    assert(recovered);
    snprintf(p,sizeof p,"%s/exefs",stage); mkdir(p,0700);
    snprintf(p,sizeof p,"%s/exefs/sentinel",stage); put(p);
    assert(rt_game_setup_end(true,why,sizeof why)); assert(has("extracted/exefs/sentinel"));
    assert(!rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    assert(has("extracted/exefs/sentinel"));
    assert(rt_game_setup_begin("extracted",true,stage,sizeof stage,why,sizeof why));
    assert(!rt_remove_game_files("extracted"));
    assert(rt_game_setup_end(false,why,sizeof why));
    assert(has("extracted/exefs/sentinel"));
    assert(rt_game_setup_begin("extracted",true,stage,sizeof stage,why,sizeof why));
    assert(!rt_game_setup_end(true,why,sizeof why));
    assert(has("extracted/exefs/sentinel"));
    assert(rt_game_setup_begin("extracted",true,stage,sizeof stage,why,sizeof why));
    snprintf(p,sizeof p,"%s/" GAMELIB_NAME,stage); put(p);
    snprintf(p,sizeof p,"%s/" GAMELIB_NAME ".id",stage); put(p);
    assert(rt_game_setup_end(true,why,sizeof why));
    assert(has("extracted/" GAMELIB_NAME) && has("extracted/" GAMELIB_NAME ".id"));
    assert(has("extracted/exefs/sentinel")); assert(rt_remove_game_files("extracted"));
    mkdir("outside",0700); put("outside/sentinel"); assert(!symlink("outside","extracted"));
    assert(!rt_game_setup_begin("extracted",false,stage,sizeof stage,why,sizeof why));
    assert(!rt_remove_game_files("extracted")); assert(has("outside/sentinel"));
    puts("PASS setup abort, retry, locking, publish and symlink protection");
    return 0;
}
