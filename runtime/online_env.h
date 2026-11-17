// Online play (the Lumiose module is loaded: LUMIOSE_TEST_MODULE) shares the game with other players and a server, so the
// debug, test and experimental LARECOMP_* variables are switched off in it: the scripted input, route replay, warps,
// scripted state and the like. Only the supported ones (docs/environment.md) and what the start screen itself passes on
// stay. The app's settings (larecomp.ini) are not touched.
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Removes every LARECOMP_* variable that is not allowed online from the environment, when this is an online start
// (LUMIOSE_TEST_MODULE set). Safe to call again. The removed ones are kept for rt_online_env_restore.
void rt_online_env_sanitize(void);

// Puts the removed variables back (going on to an offline game: it is a new process that inherits the environment).
void rt_online_env_restore(void);

#ifdef __cplusplus
}
#endif
