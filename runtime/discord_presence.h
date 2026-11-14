#pragma once
// Discord Rich Presence: while the player has it on (settings), the Discord app on this machine shows that they are
// playing. Off by default; needs DISCORD_CLIENT_ID (the Application ID of MonZaMac's Discord application).
void discord_presence_start(void);
void discord_presence_stop(void);
void discord_presence_note_input(void);
