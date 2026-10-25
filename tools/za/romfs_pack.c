// Builds a RomFS image from a folder: usage: romfs_pack <dir> <out.bin> (the start screen does this for players;
// this is the command-line version, for a merged base + update tree).
#include <stdio.h>
#include "romfs_build.h"

static void progress(uint64_t done, uint64_t total) {
    fprintf(stderr, "\r%llu / %llu MB", (unsigned long long)(done >> 20), (unsigned long long)(total >> 20));
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: romfs_pack <romfs folder> <romfs.bin>\n");
        return 1;
    }
    char why[256] = "";
    if (!romfs_build(argv[1], argv[2], progress, why, sizeof why)) {
        fprintf(stderr, "\nromfs_pack: %s\n", why);
        return 1;
    }
    fprintf(stderr, "\n");
    return 0;
}
