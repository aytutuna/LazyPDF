/* Written by hand for MSVC on Windows x64 and arm64; CMake would generate this. */

#define OPJ_PACKAGE_VERSION "2.5.4"

/* _aligned_malloc comes with the MSVC runtime; there is no fseeko, memalign or malloc.h use. */
#define OPJ_HAVE__ALIGNED_MALLOC

/* Both targets are little endian, so OPJ_BIG_ENDIAN stays undefined. */
