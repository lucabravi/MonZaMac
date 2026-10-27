#include "nstool_path_safety.hpp"
#include <cassert>
#include <string>

int main() {
    assert(monzamac::safe_nstool_entry_name("data.trpfd"));
    assert(monzamac::safe_nstool_entry_name(u8"Pokémon"));
    assert(!monzamac::safe_nstool_entry_name(""));
    assert(!monzamac::safe_nstool_entry_name("."));
    assert(!monzamac::safe_nstool_entry_name(".."));
    assert(!monzamac::safe_nstool_entry_name("../outside"));
    assert(!monzamac::safe_nstool_entry_name("dir/file"));
    assert(!monzamac::safe_nstool_entry_name("dir\\file"));
    assert(!monzamac::safe_nstool_entry_name(std::string("bad\0name", 8)));
}
