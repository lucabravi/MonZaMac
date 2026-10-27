#pragma once

#include <string>

namespace monzamac {

inline bool safe_nstool_entry_name(const std::string& name)
{
	return !name.empty() && name != "." && name != ".." &&
	       name.find('/') == std::string::npos && name.find('\\') == std::string::npos &&
	       name.find('\0') == std::string::npos;
}

} // namespace monzamac
