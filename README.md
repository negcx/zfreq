# zfreq

This is a project to play around with multi-threading in Zig. There is a small implementation of Go-like unbuffered channels for communicating between threads.

`zfreq` itself uses all cores on a machine to count the frequency of different characters (or byte values) within a file. On my MBP, it counts the characters in a 8.85gb file in 1.25s.
