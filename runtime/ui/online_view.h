// What the Lumiose Online column of the start screen shows (decided in launcher.mm, drawn by saves_online_draw in saves_ui.mm)
#pragma once

struct OnlineView {
    const char *headline;  // "Service ready", "Set up on first play", ...
    const char *line;      // under it
    const char *build;     // the Build row's value
    bool build_good;       // ... in green
    bool good;             // headline in green with a check (else an info dot, or a warning when bad)
    bool bad;              // a problem: warning colour
    const char *button;    // the button's label
    bool on;               // it can be pressed
    float progress;        // < 0: none; else 0..1, drawn as the button fills
};
