#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Forks a child whose controlling terminal is a new pseudo-terminal `columns` × `rows`, and executes `path` in it with
/// `argv` and `envp`. The terminal is the child's standard output; `stdin_fd` and `stderr_fd` become its standard
/// input and error (-1: the terminal too). Every other descriptor is closed and every signal reset. The child leads its
/// own session and process group. Returns the child's pid (-1 on failure, with errno set) and the terminal's master
/// side in `master`.
pid_t cpty_spawn(const char *path, char *const argv[], char *const envp[], int stdin_fd, int stderr_fd,
                 unsigned short columns, unsigned short rows, int *master);

/// Gives the terminal of `master` a new size; its program gets SIGWINCH. Returns 0, or -1 with errno set.
int cpty_resize(int master, unsigned short columns, unsigned short rows);

#endif
