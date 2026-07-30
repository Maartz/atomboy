# The blob rides in flash as an opaque binary rather than a C array: 110 KB of
# `0x13,` would be seven hundred kilobytes of source for the compiler to parse
# and nothing to read.
idf_component_register(SRCS "main.c" INCLUDE_DIRS "." EMBED_FILES "blob.bin")
