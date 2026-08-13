#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <erl_driver.h>
#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/syscall.h>
#endif

#ifdef __APPLE__
#include <sys/stdio.h>
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#ifndef O_DIRECTORY
#define O_DIRECTORY 0
#endif

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

typedef struct cleanup_job {
  int first_fd;
  int second_fd;
  int third_fd;
  char *allocation;
  ErlNifMutex *mutex;
  struct cleanup_job *next;
} cleanup_job;

typedef struct {
  _Atomic(cleanup_job *) pending;
  pthread_t thread;
  int wake_read_fd;
  _Atomic(int) wake_write_fd;
} cleanup_worker;

typedef struct {
  ErlNifResourceType *root_resource_type;
  ErlNifResourceType *segment_resource_type;
  ErlNifResourceType *adoption_resource_type;
  ErlNifResourceType *bound_entry_resource_type;
  cleanup_worker cleanup;
} nif_state;

typedef struct {
  int fd;
  int lock_fd;
  ErlNifMutex *mutex;
  cleanup_job *cleanup;
  cleanup_worker *cleanup_worker;
} root_resource;

typedef struct {
  int directory_fd;
  int file_fd;
  char *basename;
  size_t basename_size;
  dev_t device;
  ino_t inode;
  int write_started;
  int linked;
  ErlNifMutex *mutex;
  cleanup_job *cleanup;
  cleanup_worker *cleanup_worker;
} segment_resource;

typedef struct {
  int source_parent_fd;
  int destination_parent_fd;
  int source_fd;
  char *names;
  char *source_name;
  char *destination_name;
  char *source_parent_path;
  char *destination_parent_path;
  dev_t source_device;
  ino_t source_inode;
  dev_t source_parent_device;
  ino_t source_parent_inode;
  dev_t destination_parent_device;
  ino_t destination_parent_inode;
  int adopted;
  ErlNifMutex *mutex;
  cleanup_job *cleanup;
  cleanup_worker *cleanup_worker;
} adoption_resource;

typedef struct {
  int parent_fd;
  int entry_fd;
  char *basename;
  dev_t device;
  ino_t inode;
  off_t size;
  mode_t type;
  int removed;
  ErlNifMutex *mutex;
  cleanup_job *cleanup;
  cleanup_worker *cleanup_worker;
} bound_entry_resource;

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_closed;
static ERL_NIF_TERM atom_invalid_basename;
static ERL_NIF_TERM atom_stale_root;
static ERL_NIF_TERM atom_unlink_forbidden;
static ERL_NIF_TERM atom_name_changed;
static ERL_NIF_TERM atom_stale_source;
static ERL_NIF_TERM atom_stale_source_parent;
static ERL_NIF_TERM atom_stale_destination_parent;
static ERL_NIF_TERM atom_destination_mismatch;
static ERL_NIF_TERM atom_adopted;
static ERL_NIF_TERM atom_none;
static ERL_NIF_TERM atom_after_rename;
static ERL_NIF_TERM atom_source_parent_sync;
static ERL_NIF_TERM atom_destination_parent_sync;
static ERL_NIF_TERM atom_regular;
static ERL_NIF_TERM atom_directory;
static ERL_NIF_TERM atom_stale_entry;

static ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM reason) {
  return enif_make_tuple2(env, atom_error, reason);
}

static ERL_NIF_TERM make_errno_reason(ErlNifEnv *env, int error) {
  const char *name = erl_errno_id(error);

  if (name != NULL) {
    return enif_make_atom(env, name);
  }

  return enif_make_int(env, error);
}

static ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int error) {
  return make_error(env, make_errno_reason(env, error));
}

static int sync_fd(int fd) {
  int result;

#ifdef F_FULLFSYNC
  do {
    result = fcntl(fd, F_FULLFSYNC, 0);
  } while (result == -1 && errno == EINTR);

  if (result == 0 ||
      (errno != ENOTSUP && errno != EINVAL && errno != ENOTTY)) {
    return result;
  }
#endif

  do {
    result = fsync(fd);
  } while (result == -1 && errno == EINTR);

  return result;
}

static int take_fd(int *fd) {
  int taken = *fd;
  *fd = -1;
  return taken;
}

static int close_owned_fd(int fd) {
  if (fd == -1) {
    return 0;
  }

  return close(fd);
}

static void cleanup_job_run(cleanup_job *job) {
  close_owned_fd(job->first_fd);
  close_owned_fd(job->second_fd);
  close_owned_fd(job->third_fd);
  if (job->allocation != NULL) {
    enif_free(job->allocation);
  }
  if (job->mutex != NULL) {
    enif_mutex_destroy(job->mutex);
  }
  enif_free(job);
}

static void cleanup_jobs_run(cleanup_job *jobs) {
  while (jobs != NULL) {
    cleanup_job *next = jobs->next;
    cleanup_job_run(jobs);
    jobs = next;
  }
}

static void cleanup_worker_signal(cleanup_worker *state) {
  unsigned char byte = 0;
  int wake_write_fd = atomic_load(&state->wake_write_fd);
  ssize_t result;

  if (wake_write_fd == -1) {
    return;
  }

  do {
    result = write(wake_write_fd, &byte, sizeof(byte));
  } while (result == -1 && errno == EINTR);

  if (result == -1 && errno != EAGAIN && errno != EWOULDBLOCK) {
    return;
  }
}

static void *cleanup_worker_main(void *argument) {
  cleanup_worker *state = argument;
  unsigned char bytes[64];

  while (1) {
    cleanup_job *jobs = atomic_exchange(&state->pending, NULL);
    ssize_t read_result;

    if (jobs != NULL) {
      cleanup_jobs_run(jobs);
    }

    do {
      read_result = read(state->wake_read_fd, bytes, sizeof(bytes));
    } while (read_result == -1 && errno == EINTR);

    if (read_result == 0 || (read_result == -1 && errno != EINTR)) {
      cleanup_jobs_run(atomic_exchange(&state->pending, NULL));
      return NULL;
    }
  }
}

static int set_descriptor_flag(int fd, int command, int flag) {
  int current;
  int result;

  do {
    current = fcntl(fd, command);
  } while (current == -1 && errno == EINTR);

  if (current == -1) {
    return -1;
  }

  do {
    result = fcntl(fd, command == F_GETFL ? F_SETFL : F_SETFD,
                   current | flag);
  } while (result == -1 && errno == EINTR);

  return result;
}

static int duplicate_descriptor(int fd) {
  int duplicate;

  do {
    duplicate = dup(fd);
  } while (duplicate == -1 && errno == EINTR);

  if (duplicate != -1 &&
      set_descriptor_flag(duplicate, F_GETFD, FD_CLOEXEC) == -1) {
    int error = errno;
    close_owned_fd(duplicate);
    errno = error;
    return -1;
  }

  return duplicate;
}

static int cleanup_worker_start(cleanup_worker *state) {
  int wake_fds[2];

  memset(state, 0, sizeof(*state));
  state->wake_read_fd = -1;
  atomic_init(&state->wake_write_fd, -1);
  atomic_init(&state->pending, NULL);

  if (pipe(wake_fds) == -1) {
    return -1;
  }
  state->wake_read_fd = wake_fds[0];
  atomic_store(&state->wake_write_fd, wake_fds[1]);

  if (set_descriptor_flag(state->wake_read_fd, F_GETFD, FD_CLOEXEC) == -1 ||
      set_descriptor_flag(wake_fds[1], F_GETFD, FD_CLOEXEC) == -1 ||
      set_descriptor_flag(wake_fds[1], F_GETFL, O_NONBLOCK) == -1) {
    close_owned_fd(state->wake_read_fd);
    close_owned_fd(atomic_exchange(&state->wake_write_fd, -1));
    state->wake_read_fd = -1;
    return -1;
  }

  if (pthread_create(&state->thread, NULL, cleanup_worker_main, state) != 0) {
    close_owned_fd(state->wake_read_fd);
    close_owned_fd(atomic_exchange(&state->wake_write_fd, -1));
    state->wake_read_fd = -1;
    return -1;
  }

  return 0;
}

static void cleanup_worker_enqueue(cleanup_worker *state, cleanup_job *job,
                                   int first_fd, int second_fd, int third_fd,
                                   char *allocation, ErlNifMutex *mutex) {
  cleanup_job *pending;

  if (job == NULL || state == NULL) {
    return;
  }

  job->first_fd = first_fd;
  job->second_fd = second_fd;
  job->third_fd = third_fd;
  job->allocation = allocation;
  job->mutex = mutex;

  do {
    pending = atomic_load(&state->pending);
    job->next = pending;
  } while (!atomic_compare_exchange_weak(&state->pending, &pending, job));

  cleanup_worker_signal(state);
}

static void cleanup_worker_stop(cleanup_worker *state) {
  close_owned_fd(atomic_exchange(&state->wake_write_fd, -1));
  pthread_join(state->thread, NULL);
  cleanup_jobs_run(atomic_exchange(&state->pending, NULL));
  close_owned_fd(state->wake_read_fd);
  state->wake_read_fd = -1;
}

static int valid_basename(const ErlNifBinary *basename) {
  size_t index;

  if (basename->size == 0 || basename->size > 255) {
    return 0;
  }

  if ((basename->size == 1 && basename->data[0] == '.') ||
      (basename->size == 2 && basename->data[0] == '.' &&
       basename->data[1] == '.')) {
    return 0;
  }

  for (index = 0; index < basename->size; index++) {
    if (basename->data[index] == '/' || basename->data[index] == '\0') {
      return 0;
    }
  }

  return 1;
}

static int get_root_identity(ErlNifEnv *env, ERL_NIF_TERM term,
                             ErlNifUInt64 *device,
                             ErlNifUInt64 *special_device,
                             ErlNifUInt64 *inode) {
  const ERL_NIF_TERM *elements;
  int arity;

  if (!enif_get_tuple(env, term, &arity, &elements) || arity != 3) {
    return 0;
  }

  if (!enif_get_uint64(env, elements[0], device)) {
    return 0;
  }

  if (!enif_get_uint64(env, elements[1], special_device)) {
    return 0;
  }

  if (!enif_get_uint64(env, elements[2], inode)) {
    return 0;
  }

  return 1;
}

static void root_destructor(ErlNifEnv *env, void *object) {
  root_resource *root = object;
  ErlNifMutex *mutex;
  int fd;
  int lock_fd;
  (void)env;

  fd = take_fd(&root->fd);
  lock_fd = take_fd(&root->lock_fd);
  mutex = root->mutex;
  root->mutex = NULL;
  cleanup_worker_enqueue(root->cleanup_worker, root->cleanup, fd, lock_fd, -1,
                         NULL, mutex);
  root->cleanup = NULL;
  root->cleanup_worker = NULL;
}

static void segment_destructor(ErlNifEnv *env, void *object) {
  segment_resource *segment = object;
  ErlNifMutex *mutex;
  int file_fd;
  int directory_fd;
  char *basename;
  (void)env;

  file_fd = take_fd(&segment->file_fd);
  directory_fd = take_fd(&segment->directory_fd);
  basename = segment->basename;
  segment->basename = NULL;
  mutex = segment->mutex;
  segment->mutex = NULL;
  cleanup_worker_enqueue(segment->cleanup_worker, segment->cleanup, file_fd,
                         directory_fd, -1, basename, mutex);
  segment->cleanup = NULL;
  segment->cleanup_worker = NULL;
}

static void adoption_destructor(ErlNifEnv *env, void *object) {
  adoption_resource *adoption = object;
  ErlNifMutex *mutex;
  int source_fd;
  int source_parent_fd;
  int destination_parent_fd;
  char *names;
  (void)env;

  source_fd = take_fd(&adoption->source_fd);
  source_parent_fd = take_fd(&adoption->source_parent_fd);
  destination_parent_fd = take_fd(&adoption->destination_parent_fd);
  names = adoption->names;
  adoption->names = NULL;
  mutex = adoption->mutex;
  adoption->mutex = NULL;
  cleanup_worker_enqueue(adoption->cleanup_worker, adoption->cleanup, source_fd,
                         source_parent_fd, destination_parent_fd, names, mutex);
  adoption->cleanup = NULL;
  adoption->cleanup_worker = NULL;
}

static void bound_entry_destructor(ErlNifEnv *env, void *object) {
  bound_entry_resource *entry = object;
  ErlNifMutex *mutex;
  int parent_fd;
  int entry_fd;
  char *basename;
  (void)env;

  parent_fd = take_fd(&entry->parent_fd);
  entry_fd = take_fd(&entry->entry_fd);
  basename = entry->basename;
  entry->basename = NULL;
  mutex = entry->mutex;
  entry->mutex = NULL;
  cleanup_worker_enqueue(entry->cleanup_worker, entry->cleanup, parent_fd,
                         entry_fd, -1, basename, mutex);
  entry->cleanup = NULL;
  entry->cleanup_worker = NULL;
}

static int path_parent_and_name(const ErlNifBinary *path, char **parent,
                                size_t *parent_size, char **name,
                                size_t *name_size) {
  size_t end = path->size;
  size_t slash;

  while (end > 1 && path->data[end - 1] == '/') {
    end--;
  }
  if (end == 0) {
    return 0;
  }

  slash = end;
  while (slash > 0 && path->data[slash - 1] != '/') {
    slash--;
  }
  if (slash == end || (end - slash == 1 && path->data[slash] == '.') ||
      (end - slash == 2 && path->data[slash] == '.' &&
       path->data[slash + 1] == '.')) {
    return 0;
  }

  *name = (char *)path->data + slash;
  *name_size = end - slash;
  if (slash == 0) {
    *parent = ".";
    *parent_size = 1;
  } else if (slash == 1) {
    *parent = "/";
    *parent_size = 1;
  } else {
    *parent = (char *)path->data;
    *parent_size = slash - 1;
  }
  return 1;
}

static int identity_matches(const struct stat *stat, dev_t device, ino_t inode,
                            mode_t type) {
  return stat->st_dev == device && stat->st_ino == inode &&
         (stat->st_mode & S_IFMT) == type;
}

static int absolute_path(const ErlNifBinary *path) {
  return path->size > 0 && path->data[0] == '/';
}

static int path_within_root(const ErlNifBinary *path,
                            const ErlNifBinary *root) {
  if (!absolute_path(path) || !absolute_path(root) || root->size == 0 ||
      path->size <= root->size ||
      memcmp(path->data, root->data, root->size) != 0) {
    return 0;
  }

  if (root->size == 1 && root->data[0] == '/') {
    return 1;
  }

  return path->data[root->size] == '/';
}

static int traverse_directory_chain(const ErlNifBinary *path, int create,
                                    mode_t mode) {
  char *copy;
  char *component;
  char *save = NULL;
  int fd;
  int child_fd;
  int error;
  int created;

  if (!absolute_path(path)) {
    errno = EINVAL;
    return -1;
  }
  copy = enif_alloc(path->size + 1);
  if (copy == NULL) {
    errno = ENOMEM;
    return -1;
  }
  memcpy(copy, path->data, path->size);
  copy[path->size] = '\0';

  do {
    fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  } while (fd == -1 && errno == EINTR);
  if (fd == -1) {
    error = errno;
    enif_free(copy);
    errno = error;
    return -1;
  }

  component = strtok_r(copy + 1, "/", &save);
  while (component != NULL) {
    if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
      error = EINVAL;
      goto fail;
    }

    created = 0;
    do {
      child_fd = openat(fd, component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    } while (child_fd == -1 && errno == EINTR);
    if (child_fd == -1 && errno == ENOENT && create) {
      do {
        error = mkdirat(fd, component, mode);
      } while (error == -1 && errno == EINTR);
      if (error == -1 && errno != EEXIST) {
        error = errno;
        goto fail;
      }
      created = error == 0;
      do {
        child_fd = openat(fd, component,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      } while (child_fd == -1 && errno == EINTR);
    }
    if (child_fd == -1) {
      error = errno;
      goto fail;
    }
    if (created &&
        (fchmod(child_fd, mode) == -1 || sync_fd(child_fd) == -1 ||
         sync_fd(fd) == -1)) {
      error = errno;
      close_owned_fd(child_fd);
      goto fail;
    }

    close_owned_fd(fd);
    fd = child_fd;
    component = strtok_r(NULL, "/", &save);
  }

  enif_free(copy);
  return fd;

fail:
  close_owned_fd(fd);
  enif_free(copy);
  errno = error;
  return -1;
}

static int open_directory_chain_nofollow(const ErlNifBinary *path) {
  return traverse_directory_chain(path, 0, 0700);
}

static int open_or_create_directory_chain_nofollow(const ErlNifBinary *path,
                                                    mode_t mode) {
  return traverse_directory_chain(path, 1, mode);
}

static int open_relative_directory_chain_nofollow(int root_fd,
                                                  const char *path) {
  char *copy;
  char *component;
  char *save = NULL;
  int fd;
  int child_fd;
  int error;

  if (path == NULL || path[0] == '/') {
    errno = EINVAL;
    return -1;
  }
  if (path[0] == '\0' || strcmp(path, ".") == 0) {
    return duplicate_descriptor(root_fd);
  }
  copy = enif_alloc(strlen(path) + 1);
  if (copy == NULL) {
    errno = ENOMEM;
    return -1;
  }
  strcpy(copy, path);

  fd = duplicate_descriptor(root_fd);
  if (fd == -1) {
    error = errno;
    enif_free(copy);
    errno = error;
    return -1;
  }

  component = strtok_r(copy, "/", &save);
  while (component != NULL) {
    if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
      error = EINVAL;
      goto fail;
    }

    do {
      child_fd = openat(fd, component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    } while (child_fd == -1 && errno == EINTR);
    if (child_fd == -1) {
      error = errno;
      goto fail;
    }

    close_owned_fd(fd);
    fd = child_fd;
    component = strtok_r(NULL, "/", &save);
  }

  enif_free(copy);
  return fd;

fail:
  close_owned_fd(fd);
  enif_free(copy);
  errno = error;
  return -1;
}

static int open_or_create_relative_directory_chain_nofollow(
    int root_fd, const char *path, mode_t mode) {
  char *copy;
  char *component;
  char *save = NULL;
  int fd;
  int child_fd;
  int error;
  int created;

  if (path == NULL || path[0] == '/') {
    errno = EINVAL;
    return -1;
  }
  if (path[0] == '\0') {
    return duplicate_descriptor(root_fd);
  }
  copy = enif_alloc(strlen(path) + 1);
  if (copy == NULL) {
    errno = ENOMEM;
    return -1;
  }
  strcpy(copy, path);

  fd = duplicate_descriptor(root_fd);
  if (fd == -1) {
    error = errno;
    enif_free(copy);
    errno = error;
    return -1;
  }

  component = strtok_r(copy, "/", &save);
  while (component != NULL) {
    if (strcmp(component, ".") == 0 || strcmp(component, "..") == 0) {
      error = EINVAL;
      goto fail;
    }

    created = 0;
    do {
      child_fd = openat(fd, component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    } while (child_fd == -1 && errno == EINTR);
    if (child_fd == -1 && errno == ENOENT) {
      do {
        error = mkdirat(fd, component, mode);
      } while (error == -1 && errno == EINTR);
      if (error == -1 && errno != EEXIST) {
        error = errno;
        goto fail;
      }
      created = error == 0;
      do {
        child_fd = openat(fd, component,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
      } while (child_fd == -1 && errno == EINTR);
    }
    if (child_fd == -1) {
      error = errno;
      goto fail;
    }
    if (created &&
        (fchmod(child_fd, mode) == -1 || sync_fd(child_fd) == -1 ||
         sync_fd(fd) == -1)) {
      error = errno;
      close_owned_fd(child_fd);
      goto fail;
    }

    close_owned_fd(fd);
    fd = child_fd;
    component = strtok_r(NULL, "/", &save);
  }

  enif_free(copy);
  return fd;

fail:
  close_owned_fd(fd);
  enif_free(copy);
  errno = error;
  return -1;
}

static int path_matches_identity_nofollow(const char *path, dev_t device,
                                          ino_t inode) {
  ErlNifBinary path_binary = {.size = strlen(path),
                              .data = (unsigned char *)path};
  struct stat stat;
  int fd;
  int matches;

  fd = open_directory_chain_nofollow(&path_binary);
  if (fd == -1) {
    return 0;
  }

  matches = fstat(fd, &stat) == 0 &&
            identity_matches(&stat, device, inode, S_IFDIR);
  close_owned_fd(fd);
  return matches;
}

static int exclusive_renameat(int source_parent_fd, const char *source_name,
                              int destination_parent_fd,
                              const char *destination_name) {
#ifdef __APPLE__
  return renameatx_np(source_parent_fd, source_name, destination_parent_fd,
                      destination_name, RENAME_EXCL);
#elif defined(__linux__)
  return (int)syscall(__NR_renameat2, source_parent_fd, source_name,
                      destination_parent_fd, destination_name, 1U);
#else
  errno = ENOTSUP;
  return -1;
#endif
}

static ERL_NIF_TERM adoption_prepare_nif(ErlNifEnv *env, int argc,
                                         const ERL_NIF_TERM argv[]) {
  ErlNifBinary source_path;
  ErlNifBinary destination_path;
  ErlNifBinary root_path;
  nif_state *state = enif_priv_data(env);
  adoption_resource *adoption;
  cleanup_job *cleanup;
  struct stat source_stat;
  struct stat source_parent_stat;
  struct stat destination_parent_stat;
  char *source_parent;
  char *source_name;
  char *destination_parent;
  char *destination_name;
  char *destination_parent_relative;
  char *cursor;
  size_t source_parent_size;
  size_t source_name_size;
  size_t destination_parent_size;
  size_t destination_name_size;
  int root_fd = -1;
  int source_parent_fd = -1;
  int destination_parent_fd = -1;
  int source_fd = -1;
  int error;
  ERL_NIF_TERM result;

  if (argc != 3 || !enif_inspect_binary(env, argv[0], &source_path) ||
      !enif_inspect_binary(env, argv[1], &destination_path) ||
      !enif_inspect_binary(env, argv[2], &root_path) ||
      memchr(source_path.data, '\0', source_path.size) != NULL ||
      memchr(destination_path.data, '\0', destination_path.size) != NULL ||
      memchr(root_path.data, '\0', root_path.size) != NULL ||
      !path_within_root(&destination_path, &root_path) ||
      !path_parent_and_name(&source_path, &source_parent, &source_parent_size,
                            &source_name, &source_name_size) ||
      !path_parent_and_name(&destination_path, &destination_parent,
                            &destination_parent_size, &destination_name,
                            &destination_name_size) ||
      source_name_size > 255 || destination_name_size > 255) {
    return enif_make_badarg(env);
  }

  cleanup = enif_alloc(sizeof(*cleanup));
  if (cleanup == NULL) {
    return make_errno_error(env, ENOMEM);
  }

  adoption = enif_alloc_resource(state->adoption_resource_type,
                                 sizeof(*adoption));
  if (adoption == NULL) {
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }
  memset(adoption, 0, sizeof(*adoption));
  adoption->source_parent_fd = -1;
  adoption->destination_parent_fd = -1;
  adoption->source_fd = -1;
  adoption->cleanup = cleanup;
  adoption->cleanup_worker = &state->cleanup;

  adoption->names = enif_alloc(source_name_size + destination_name_size +
                               source_parent_size + destination_parent_size + 4);
  if (adoption->names == NULL) {
    enif_release_resource(adoption);
    return make_errno_error(env, ENOMEM);
  }

  cursor = adoption->names;
  adoption->source_name = cursor;
  memcpy(cursor, source_name, source_name_size);
  cursor[source_name_size] = '\0';
  cursor += source_name_size + 1;
  adoption->destination_name = cursor;
  memcpy(cursor, destination_name, destination_name_size);
  cursor[destination_name_size] = '\0';
  cursor += destination_name_size + 1;
  adoption->source_parent_path = cursor;
  memcpy(cursor, source_parent, source_parent_size);
  cursor[source_parent_size] = '\0';
  cursor += source_parent_size + 1;
  adoption->destination_parent_path = cursor;
  memcpy(cursor, destination_parent, destination_parent_size);
  cursor[destination_parent_size] = '\0';
  destination_parent_relative =
      adoption->destination_parent_path + root_path.size;
  while (*destination_parent_relative == '/') {
    destination_parent_relative++;
  }

  {
    char *source_parent_string = enif_alloc(source_parent_size + 1);
    if (source_parent_string == NULL) {
      enif_release_resource(adoption);
      return make_errno_error(env, ENOMEM);
    }
    memcpy(source_parent_string, source_parent, source_parent_size);
    source_parent_string[source_parent_size] = '\0';

    {
      ErlNifBinary source_parent_binary = {
          .size = source_parent_size,
          .data = (unsigned char *)source_parent_string};
      root_fd = open_or_create_directory_chain_nofollow(&root_path, 0700);
      if (root_fd != -1) {
        source_parent_fd = open_directory_chain_nofollow(&source_parent_binary);
      }
      if (source_parent_fd != -1) {
        destination_parent_fd =
            open_or_create_relative_directory_chain_nofollow(
                root_fd, destination_parent_relative, 0700);
      }
    }
    enif_free(source_parent_string);
  }
  error = errno;
  if (root_fd == -1 || source_parent_fd == -1 || destination_parent_fd == -1) {
    close_owned_fd(root_fd);
    close_owned_fd(source_parent_fd);
    close_owned_fd(destination_parent_fd);
    enif_release_resource(adoption);
    return make_errno_error(env, error);
  }
  close_owned_fd(root_fd);

  do {
    source_fd = openat(source_parent_fd, adoption->source_name,
                       O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  } while (source_fd == -1 && errno == EINTR);
  if (source_fd == -1 || fstat(source_fd, &source_stat) == -1 ||
      fstat(source_parent_fd, &source_parent_stat) == -1 ||
      fstat(destination_parent_fd, &destination_parent_stat) == -1) {
    error = errno;
    close_owned_fd(source_fd);
    close_owned_fd(source_parent_fd);
    close_owned_fd(destination_parent_fd);
    enif_release_resource(adoption);
    return make_errno_error(env, error);
  }

  if (source_stat.st_dev != source_parent_stat.st_dev ||
      source_stat.st_dev != destination_parent_stat.st_dev) {
    close_owned_fd(source_fd);
    close_owned_fd(source_parent_fd);
    close_owned_fd(destination_parent_fd);
    enif_release_resource(adoption);
    return make_errno_error(env, EXDEV);
  }

  adoption->source_parent_fd = source_parent_fd;
  adoption->destination_parent_fd = destination_parent_fd;
  adoption->source_fd = source_fd;
  adoption->source_device = source_stat.st_dev;
  adoption->source_inode = source_stat.st_ino;
  adoption->source_parent_device = source_parent_stat.st_dev;
  adoption->source_parent_inode = source_parent_stat.st_ino;
  adoption->destination_parent_device = destination_parent_stat.st_dev;
  adoption->destination_parent_inode = destination_parent_stat.st_ino;
  adoption->mutex = enif_mutex_create("atomic_file_adoption");
  if (adoption->mutex == NULL) {
    enif_release_resource(adoption);
    return make_errno_error(env, ENOMEM);
  }

  result = enif_make_tuple2(env, atom_ok, enif_make_resource(env, adoption));
  enif_release_resource(adoption);
  return result;
}

static ERL_NIF_TERM adoption_commit_nif(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  adoption_resource *adoption;
  struct stat stat;
  char fault[32];
  int rename_result;
  int error;
  int sync_result;

  if (argc != 2 ||
      !enif_get_resource(env, argv[0], state->adoption_resource_type,
                         (void **)&adoption) ||
      !enif_get_atom(env, argv[1], fault, sizeof(fault), ERL_NIF_LATIN1) ||
      (strcmp(fault, "none") != 0 && strcmp(fault, "after_rename") != 0 &&
       strcmp(fault, "source_parent_sync") != 0 &&
       strcmp(fault, "destination_parent_sync") != 0)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(adoption->mutex);
  if (adoption->source_fd == -1 || adoption->adopted) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, atom_closed);
  }

  if (fstat(adoption->source_parent_fd, &stat) == -1 ||
      !identity_matches(&stat, adoption->source_parent_device,
                        adoption->source_parent_inode, S_IFDIR) ||
      !path_matches_identity_nofollow(adoption->source_parent_path,
                                     adoption->source_parent_device,
                                     adoption->source_parent_inode)) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, atom_stale_source_parent);
  }
  if (fstat(adoption->destination_parent_fd, &stat) == -1 ||
      !identity_matches(&stat, adoption->destination_parent_device,
                        adoption->destination_parent_inode, S_IFDIR) ||
      !path_matches_identity_nofollow(adoption->destination_parent_path,
                                     adoption->destination_parent_device,
                                     adoption->destination_parent_inode)) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, atom_stale_destination_parent);
  }
  if (fstatat(adoption->source_parent_fd, adoption->source_name, &stat,
              AT_SYMLINK_NOFOLLOW) == -1 ||
      stat.st_dev != adoption->source_device ||
      stat.st_ino != adoption->source_inode) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, atom_stale_source);
  }

  do {
    rename_result = exclusive_renameat(
        adoption->source_parent_fd, adoption->source_name,
        adoption->destination_parent_fd, adoption->destination_name);
  } while (rename_result == -1 && errno == EINTR);
  if (rename_result == -1) {
    error = errno;
    enif_mutex_unlock(adoption->mutex);
    return make_errno_error(env, error);
  }
  adoption->adopted = 1;

  if (strcmp(fault, "after_rename") == 0) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, enif_make_tuple2(env, atom_adopted,
                                             enif_make_atom(env, "fault_injected")));
  }

  if (fstatat(adoption->destination_parent_fd, adoption->destination_name, &stat,
              AT_SYMLINK_NOFOLLOW) == -1 ||
      stat.st_dev != adoption->source_device ||
      stat.st_ino != adoption->source_inode) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, enif_make_tuple2(env, atom_adopted,
                                             atom_destination_mismatch));
  }

  sync_result = strcmp(fault, "source_parent_sync") == 0
                    ? (errno = EIO, -1)
                    : sync_fd(adoption->source_parent_fd);
  if (sync_result == -1) {
    error = errno;
    enif_mutex_unlock(adoption->mutex);
    return make_error(
        env, enif_make_tuple2(
                 env, atom_adopted,
                 enif_make_tuple2(env, atom_source_parent_sync,
                                  make_errno_reason(env, error))));
  }

  sync_result = strcmp(fault, "destination_parent_sync") == 0
                    ? (errno = EIO, -1)
                    : sync_fd(adoption->destination_parent_fd);
  if (sync_result == -1) {
    error = errno;
    enif_mutex_unlock(adoption->mutex);
    return make_error(
        env, enif_make_tuple2(
                 env, atom_adopted,
                 enif_make_tuple2(env, atom_destination_parent_sync,
                                  make_errno_reason(env, error))));
  }

  if (fstatat(adoption->destination_parent_fd, adoption->destination_name, &stat,
              AT_SYMLINK_NOFOLLOW) == -1 ||
      stat.st_dev != adoption->source_device ||
      stat.st_ino != adoption->source_inode ||
      !path_matches_identity_nofollow(adoption->source_parent_path,
                                     adoption->source_parent_device,
                                     adoption->source_parent_inode) ||
      !path_matches_identity_nofollow(adoption->destination_parent_path,
                                     adoption->destination_parent_device,
                                     adoption->destination_parent_inode)) {
    enif_mutex_unlock(adoption->mutex);
    return make_error(env, enif_make_tuple2(env, atom_adopted,
                                             atom_destination_mismatch));
  }

  enif_mutex_unlock(adoption->mutex);
  return atom_ok;
}

static ERL_NIF_TERM adoption_close_nif(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  adoption_resource *adoption;
  int source_fd;
  int source_parent_fd;
  int destination_parent_fd;
  int result = 0;
  int error = 0;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->adoption_resource_type,
                         (void **)&adoption)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(adoption->mutex);
  source_fd = take_fd(&adoption->source_fd);
  source_parent_fd = take_fd(&adoption->source_parent_fd);
  destination_parent_fd = take_fd(&adoption->destination_parent_fd);
  enif_mutex_unlock(adoption->mutex);

  if (close_owned_fd(source_fd) == -1) {
    result = -1;
    error = errno;
  }
  if (close_owned_fd(source_parent_fd) == -1) {
    result = -1;
    if (error == 0) error = errno;
  }
  if (close_owned_fd(destination_parent_fd) == -1) {
    result = -1;
    if (error == 0) error = errno;
  }
  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM open_root_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  ErlNifBinary path;
  ErlNifUInt64 expected_device;
  ErlNifUInt64 expected_special_device;
  ErlNifUInt64 expected_inode;
  nif_state *state = enif_priv_data(env);
  cleanup_job *cleanup;
  root_resource *root;
  struct stat stat;
  char *path_string;
  int fd;
  int error;
  ERL_NIF_TERM result;

  if (argc != 2 || !enif_inspect_binary(env, argv[0], &path) ||
      !get_root_identity(env, argv[1], &expected_device,
                         &expected_special_device, &expected_inode)) {
    return enif_make_badarg(env);
  }

  if (memchr(path.data, '\0', path.size) != NULL) {
    return enif_make_badarg(env);
  }

  cleanup = enif_alloc(sizeof(*cleanup));
  if (cleanup == NULL) {
    return make_errno_error(env, ENOMEM);
  }

  path_string = enif_alloc(path.size + 1);
  if (path_string == NULL) {
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }
  memcpy(path_string, path.data, path.size);
  path_string[path.size] = '\0';

  fd = open(path_string, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  error = errno;
  enif_free(path_string);

  if (fd == -1) {
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (fstat(fd, &stat) == -1) {
    error = errno;
    close(fd);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (!S_ISDIR(stat.st_mode) || (ErlNifUInt64)stat.st_dev != expected_device ||
      (ErlNifUInt64)stat.st_rdev != expected_special_device ||
      (ErlNifUInt64)stat.st_ino != expected_inode) {
    close(fd);
    enif_free(cleanup);
    return make_error(env, atom_stale_root);
  }

  root = enif_alloc_resource(state->root_resource_type, sizeof(*root));
  if (root == NULL) {
    close(fd);
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }

  memset(root, 0, sizeof(*root));
  root->fd = fd;
  root->lock_fd = -1;
  root->cleanup_worker = &state->cleanup;
  root->cleanup = cleanup;

  root->mutex = enif_mutex_create("outbox_segment_root");
  if (root->mutex == NULL) {
    enif_release_resource(root);
    return make_errno_error(env, ENOMEM);
  }

  result = enif_make_tuple2(env, atom_ok, enif_make_resource(env, root));
  enif_release_resource(root);
  return result;
}

static ERL_NIF_TERM try_lock_root_nif(ErlNifEnv *env, int argc,
                                      const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  root_resource *root;
  int lock_fd;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->root_resource_type,
                         (void **)&root)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(root->mutex);
  if (root->fd == -1) {
    enif_mutex_unlock(root->mutex);
    return make_error(env, atom_closed);
  }

  if (root->lock_fd != -1) {
    enif_mutex_unlock(root->mutex);
    return atom_ok;
  }

  do {
    lock_fd = openat(root->fd, ".outbox.lock",
                     O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
  } while (lock_fd == -1 && errno == EINTR);

  if (lock_fd == -1) {
    error = errno;
    enif_mutex_unlock(root->mutex);
    return make_errno_error(env, error);
  }

  do {
    result = flock(lock_fd, LOCK_EX | LOCK_NB);
  } while (result == -1 && errno == EINTR);
  error = errno;

  if (result == -1) {
    close_owned_fd(lock_fd);
  } else {
    root->lock_fd = lock_fd;
  }
  enif_mutex_unlock(root->mutex);

  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM close_root_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  root_resource *root;
  int result;
  int lock_result;
  int result_fd;
  int lock_fd;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->root_resource_type,
                         (void **)&root)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(root->mutex);
  result_fd = take_fd(&root->fd);
  lock_fd = take_fd(&root->lock_fd);
  enif_mutex_unlock(root->mutex);

  lock_result = close_owned_fd(lock_fd);
  error = errno;
  result = close_owned_fd(result_fd);

  if (lock_result == -1) {
    return make_errno_error(env, error);
  }

  error = errno;
  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM create_nif(ErlNifEnv *env, int argc,
                               const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  cleanup_job *cleanup;
  root_resource *root;
  segment_resource *segment;
  ErlNifBinary basename;
  unsigned int mode;
  struct stat stat;
  char *basename_string;
  int directory_fd;
  int file_fd;
  int error;
  ERL_NIF_TERM result;

  if (argc != 3 ||
      !enif_get_resource(env, argv[0], state->root_resource_type,
                         (void **)&root) ||
      !enif_inspect_binary(env, argv[1], &basename) ||
      !enif_get_uint(env, argv[2], &mode)) {
    return enif_make_badarg(env);
  }

  if (!valid_basename(&basename)) {
    return make_error(env, atom_invalid_basename);
  }

  cleanup = enif_alloc(sizeof(*cleanup));
  if (cleanup == NULL) {
    return make_errno_error(env, ENOMEM);
  }

  basename_string = enif_alloc(basename.size + 1);
  if (basename_string == NULL) {
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }
  memcpy(basename_string, basename.data, basename.size);
  basename_string[basename.size] = '\0';

  enif_mutex_lock(root->mutex);
  if (root->fd == -1) {
    enif_mutex_unlock(root->mutex);
    enif_free(basename_string);
    enif_free(cleanup);
    return make_error(env, atom_closed);
  }
  directory_fd = duplicate_descriptor(root->fd);
  error = errno;
  enif_mutex_unlock(root->mutex);

  if (directory_fd == -1) {
    enif_free(basename_string);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  file_fd = openat(directory_fd, basename_string,
                   O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW |
                       O_CLOEXEC,
                   (mode_t)mode);
  error = errno;

  if (file_fd == -1) {
    close(directory_fd);
    enif_free(basename_string);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (fstat(file_fd, &stat) == -1) {
    error = errno;
    close(file_fd);
    close(directory_fd);
    enif_free(basename_string);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (!S_ISREG(stat.st_mode)) {
    close(file_fd);
    close(directory_fd);
    enif_free(basename_string);
    enif_free(cleanup);
    return make_errno_error(env, EINVAL);
  }

  segment = enif_alloc_resource(state->segment_resource_type, sizeof(*segment));
  if (segment == NULL) {
    close(file_fd);
    close(directory_fd);
    enif_free(basename_string);
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }

  memset(segment, 0, sizeof(*segment));
  segment->directory_fd = directory_fd;
  segment->file_fd = file_fd;
  segment->device = stat.st_dev;
  segment->inode = stat.st_ino;
  segment->linked = 1;
  segment->cleanup_worker = &state->cleanup;
  segment->basename_size = basename.size;
  segment->basename = basename_string;
  segment->cleanup = cleanup;

  segment->mutex = enif_mutex_create("outbox_segment_file");
  if (segment->mutex == NULL) {
    enif_release_resource(segment);
    return make_errno_error(env, ENOMEM);
  }

  result = enif_make_tuple2(env, atom_ok, enif_make_resource(env, segment));
  enif_release_resource(segment);
  return result;
}

static ERL_NIF_TERM chmod_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  unsigned int mode;
  int result;
  int error;

  if (argc != 2 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment) ||
      !enif_get_uint(env, argv[1], &mode)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->file_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }
  result = fchmod(segment->file_fd, (mode_t)mode);
  error = errno;
  enif_mutex_unlock(segment->mutex);

  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM write_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  ErlNifBinary bytes;
  size_t offset = 0;
  ssize_t written;
  int error = 0;

  if (argc != 2 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment) ||
      !enif_inspect_iolist_as_binary(env, argv[1], &bytes)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->file_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }

  segment->write_started = 1;

  while (offset < bytes.size) {
    written = write(segment->file_fd, bytes.data + offset, bytes.size - offset);
    if (written > 0) {
      offset += (size_t)written;
    } else if (written == -1 && errno == EINTR) {
      continue;
    } else {
      error = written == -1 ? errno : EIO;
      break;
    }
  }
  enif_mutex_unlock(segment->mutex);

  return error == 0 ? atom_ok : make_errno_error(env, error);
}

static ERL_NIF_TERM sync_file_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->file_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }
  result = sync_fd(segment->file_fd);
  error = errno;
  enif_mutex_unlock(segment->mutex);

  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM sync_directory_nif(ErlNifEnv *env, int argc,
                                       const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->directory_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }
  result = sync_fd(segment->directory_fd);
  error = errno;
  enif_mutex_unlock(segment->mutex);

  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM file_info_nif(ErlNifEnv *env, int argc,
                                  const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  struct stat stat;
  int result;
  int error;
  ERL_NIF_TERM keys[6];
  ERL_NIF_TERM values[6];
  ERL_NIF_TERM map;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->file_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }
  result = fstat(segment->file_fd, &stat);
  error = errno;
  enif_mutex_unlock(segment->mutex);

  if (result == -1) {
    return make_errno_error(env, error);
  }

  keys[0] = enif_make_atom(env, "major_device");
  keys[1] = enif_make_atom(env, "minor_device");
  keys[2] = enif_make_atom(env, "inode");
  keys[3] = enif_make_atom(env, "mode");
  keys[4] = enif_make_atom(env, "links");
  keys[5] = enif_make_atom(env, "size");
  values[0] = enif_make_uint64(env, (ErlNifUInt64)stat.st_dev);
  values[1] = enif_make_uint64(env, (ErlNifUInt64)stat.st_rdev);
  values[2] = enif_make_uint64(env, (ErlNifUInt64)stat.st_ino);
  values[3] = enif_make_uint(env, (unsigned int)stat.st_mode);
  values[4] = enif_make_uint64(env, (ErlNifUInt64)stat.st_nlink);
  values[5] = enif_make_uint64(env, (ErlNifUInt64)stat.st_size);

  if (!enif_make_map_from_arrays(env, keys, values, 6, &map)) {
    return make_errno_error(env, ENOMEM);
  }

  return enif_make_tuple2(env, atom_ok, map);
}

static ERL_NIF_TERM unlink_empty_nif(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  struct stat file_stat;
  struct stat path_stat;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  if (segment->file_fd == -1 || segment->directory_fd == -1) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_closed);
  }

  if (segment->write_started) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_unlink_forbidden);
  }

  if (fstat(segment->file_fd, &file_stat) == -1) {
    error = errno;
    enif_mutex_unlock(segment->mutex);
    return make_errno_error(env, error);
  }

  if (file_stat.st_size != 0) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_unlink_forbidden);
  }

  if (fstatat(segment->directory_fd, segment->basename, &path_stat,
              AT_SYMLINK_NOFOLLOW) == -1) {
    error = errno;
    enif_mutex_unlock(segment->mutex);
    return make_errno_error(env, error);
  }

  if (!S_ISREG(path_stat.st_mode) || path_stat.st_dev != segment->device ||
      path_stat.st_ino != segment->inode) {
    enif_mutex_unlock(segment->mutex);
    return make_error(env, atom_name_changed);
  }

  result = unlinkat(segment->directory_fd, segment->basename, 0);
  error = errno;

  if (result == 0) {
    segment->linked = 0;
  }
  enif_mutex_unlock(segment->mutex);

  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM bind_entry_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  ErlNifBinary root_path;
  ErlNifBinary path;
  ErlNifUInt64 expected_device;
  ErlNifUInt64 expected_special_device;
  ErlNifUInt64 expected_inode;
  const ERL_NIF_TERM *identity_elements;
  int identity_arity;
  cleanup_job *cleanup;
  bound_entry_resource *entry;
  struct stat stat;
  struct stat path_stat;
  struct stat parent_stat;
  struct stat root_stat;
  char *parent;
  char *name;
  char *relative_parent;
  char *parent_copy;
  char *name_copy;
  size_t parent_size;
  size_t name_size;
  mode_t expected_type;
  int root_fd;
  int parent_fd;
  int entry_fd;
  int flags;
  int error;
  ERL_NIF_TERM result;

  ErlNifUInt64 expected_parent_device;
  ErlNifUInt64 expected_parent_special_device;
  ErlNifUInt64 expected_parent_inode;
  ErlNifUInt64 expected_root_device;
  ErlNifUInt64 expected_root_special_device;
  ErlNifUInt64 expected_root_inode;
  const ERL_NIF_TERM *parent_identity_elements;
  const ERL_NIF_TERM *root_identity_elements;
  int parent_identity_arity;
  int root_identity_arity;

  if (argc != 6 || !enif_inspect_binary(env, argv[0], &root_path) ||
      !enif_inspect_binary(env, argv[1], &path) ||
      !enif_get_tuple(env, argv[3], &identity_arity, &identity_elements) ||
      identity_arity != 3 ||
      !enif_get_uint64(env, identity_elements[0], &expected_device) ||
      !enif_get_uint64(env, identity_elements[1], &expected_special_device) ||
      !enif_get_uint64(env, identity_elements[2], &expected_inode) ||
      !enif_get_tuple(env, argv[4], &parent_identity_arity,
                      &parent_identity_elements) ||
      parent_identity_arity != 3 ||
      !enif_get_uint64(env, parent_identity_elements[0],
                       &expected_parent_device) ||
      !enif_get_uint64(env, parent_identity_elements[1],
                       &expected_parent_special_device) ||
      !enif_get_uint64(env, parent_identity_elements[2],
                       &expected_parent_inode) ||
      !enif_get_tuple(env, argv[5], &root_identity_arity,
                      &root_identity_elements) ||
      root_identity_arity != 3 ||
      !enif_get_uint64(env, root_identity_elements[0], &expected_root_device) ||
      !enif_get_uint64(env, root_identity_elements[1],
                       &expected_root_special_device) ||
      !enif_get_uint64(env, root_identity_elements[2], &expected_root_inode)) {
    return enif_make_badarg(env);
  }

  if (enif_is_identical(argv[2], atom_regular)) {
    expected_type = S_IFREG;
    flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC;
  } else if (enif_is_identical(argv[2], atom_directory)) {
    expected_type = S_IFDIR;
    flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  } else {
    return enif_make_badarg(env);
  }

  if (!absolute_path(&root_path) || !absolute_path(&path) ||
      !path_within_root(&path, &root_path) ||
      !path_parent_and_name(&path, &parent, &parent_size, &name, &name_size)) {
    return enif_make_badarg(env);
  }

  parent_copy = enif_alloc(parent_size + 1);
  name_copy = enif_alloc(name_size + 1);
  cleanup = enif_alloc(sizeof(*cleanup));
  if (parent_copy == NULL || name_copy == NULL || cleanup == NULL) {
    if (parent_copy != NULL) enif_free(parent_copy);
    if (name_copy != NULL) enif_free(name_copy);
    if (cleanup != NULL) enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }
  memcpy(parent_copy, parent, parent_size);
  parent_copy[parent_size] = '\0';
  memcpy(name_copy, name, name_size);
  name_copy[name_size] = '\0';

  char *root_copy = enif_alloc(root_path.size + 1);
  if (root_copy == NULL) {
    enif_free(parent_copy);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }
  memcpy(root_copy, root_path.data, root_path.size);
  root_copy[root_path.size] = '\0';
  root_fd = open(root_copy, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  error = errno;
  enif_free(root_copy);
  if (root_fd == -1) {
    enif_free(parent_copy);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }
  if (fstat(root_fd, &root_stat) == -1) {
    error = errno;
    close_owned_fd(root_fd);
    enif_free(parent_copy);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }
  if (!S_ISDIR(root_stat.st_mode) ||
      (ErlNifUInt64)root_stat.st_dev != expected_root_device ||
      (ErlNifUInt64)root_stat.st_rdev != expected_root_special_device ||
      (ErlNifUInt64)root_stat.st_ino != expected_root_inode) {
    close_owned_fd(root_fd);
    enif_free(parent_copy);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_error(env, atom_stale_entry);
  }

  if (parent_size < root_path.size ||
      memcmp(parent_copy, root_path.data, root_path.size) != 0 ||
      (parent_size > root_path.size && root_path.size > 1 &&
       parent_copy[root_path.size] != '/')) {
    close_owned_fd(root_fd);
    enif_free(parent_copy);
    enif_free(name_copy);
    enif_free(cleanup);
    return enif_make_badarg(env);
  }

  relative_parent = parent_copy + root_path.size;
  while (*relative_parent == '/') relative_parent++;
  parent_fd = open_relative_directory_chain_nofollow(root_fd, relative_parent);
  error = errno;
  close_owned_fd(root_fd);
  enif_free(parent_copy);
  if (parent_fd == -1) {
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (fstat(parent_fd, &parent_stat) == -1) {
    error = errno;
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }
  if (!S_ISDIR(parent_stat.st_mode) ||
      (ErlNifUInt64)parent_stat.st_dev != expected_parent_device ||
      (ErlNifUInt64)parent_stat.st_rdev != expected_parent_special_device ||
      (ErlNifUInt64)parent_stat.st_ino != expected_parent_inode) {
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_error(env, atom_stale_entry);
  }

  do {
    entry_fd = openat(parent_fd, name_copy, flags);
  } while (entry_fd == -1 && errno == EINTR);
  if (entry_fd == -1) {
    error = errno;
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (fstat(entry_fd, &stat) == -1 ||
      fstatat(parent_fd, name_copy, &path_stat, AT_SYMLINK_NOFOLLOW) == -1) {
    error = errno;
    close_owned_fd(entry_fd);
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, error);
  }

  if (!identity_matches(&stat, (dev_t)expected_device,
                        (ino_t)expected_inode, expected_type) ||
      !identity_matches(&path_stat, (dev_t)expected_device,
                        (ino_t)expected_inode, expected_type) ||
      (ErlNifUInt64)stat.st_rdev != expected_special_device) {
    close_owned_fd(entry_fd);
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_error(env, atom_stale_entry);
  }

  entry = enif_alloc_resource(state->bound_entry_resource_type, sizeof(*entry));
  if (entry == NULL) {
    close_owned_fd(entry_fd);
    close_owned_fd(parent_fd);
    enif_free(name_copy);
    enif_free(cleanup);
    return make_errno_error(env, ENOMEM);
  }

  memset(entry, 0, sizeof(*entry));
  entry->parent_fd = parent_fd;
  entry->entry_fd = entry_fd;
  entry->basename = name_copy;
  entry->device = stat.st_dev;
  entry->inode = stat.st_ino;
  entry->size = stat.st_size;
  entry->type = expected_type;
  entry->cleanup_worker = &state->cleanup;
  entry->cleanup = cleanup;
  entry->mutex = enif_mutex_create("bound_filesystem_entry");
  if (entry->mutex == NULL) {
    enif_release_resource(entry);
    return make_errno_error(env, ENOMEM);
  }

  result = enif_make_tuple2(env, atom_ok, enif_make_resource(env, entry));
  enif_release_resource(entry);
  return result;
}

static ERL_NIF_TERM bound_info_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  bound_entry_resource *entry;
  struct stat stat;
  ERL_NIF_TERM keys[4];
  ERL_NIF_TERM values[4];
  ERL_NIF_TERM map;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->bound_entry_resource_type,
                         (void **)&entry)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(entry->mutex);
  if (entry->entry_fd == -1) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_closed);
  }
  result = fstat(entry->entry_fd, &stat);
  error = errno;
  enif_mutex_unlock(entry->mutex);
  if (result == -1) return make_errno_error(env, error);

  keys[0] = enif_make_atom(env, "major_device");
  keys[1] = enif_make_atom(env, "minor_device");
  keys[2] = enif_make_atom(env, "inode");
  keys[3] = enif_make_atom(env, "size");
  values[0] = enif_make_uint64(env, (ErlNifUInt64)stat.st_dev);
  values[1] = enif_make_uint64(env, (ErlNifUInt64)stat.st_rdev);
  values[2] = enif_make_uint64(env, (ErlNifUInt64)stat.st_ino);
  values[3] = enif_make_uint64(env, (ErlNifUInt64)stat.st_size);
  if (!enif_make_map_from_arrays(env, keys, values, 4, &map)) {
    return make_errno_error(env, ENOMEM);
  }
  return enif_make_tuple2(env, atom_ok, map);
}

static ERL_NIF_TERM read_bound_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  bound_entry_resource *entry;
  unsigned int count;
  unsigned char *bytes;
  ERL_NIF_TERM binary;
  ssize_t result;
  int error;

  if (argc != 2 ||
      !enif_get_resource(env, argv[0], state->bound_entry_resource_type,
                         (void **)&entry) ||
      !enif_get_uint(env, argv[1], &count)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(entry->mutex);
  if (entry->entry_fd == -1 || entry->type != S_IFREG) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_closed);
  }
  bytes = enif_make_new_binary(env, count, &binary);
  do {
    result = read(entry->entry_fd, bytes, count);
  } while (result == -1 && errno == EINTR);
  error = errno;
  enif_mutex_unlock(entry->mutex);

  if (result == -1) return make_errno_error(env, error);
  if (result == 0) return enif_make_atom(env, "eof");
  return enif_make_tuple2(env, atom_ok,
                          enif_make_sub_binary(env, binary, 0, result));
}

static ERL_NIF_TERM sync_bound_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  bound_entry_resource *entry;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->bound_entry_resource_type,
                         (void **)&entry)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(entry->mutex);
  if (entry->entry_fd == -1) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_closed);
  }
  result = sync_fd(entry->entry_fd);
  error = errno;
  enif_mutex_unlock(entry->mutex);
  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM remove_bound_nif(ErlNifEnv *env, int argc,
                                     const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  bound_entry_resource *entry;
  struct stat stat;
  int flags;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->bound_entry_resource_type,
                         (void **)&entry)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(entry->mutex);
  if (entry->entry_fd == -1 || entry->parent_fd == -1 || entry->removed) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_closed);
  }
  if (fstatat(entry->parent_fd, entry->basename, &stat,
              AT_SYMLINK_NOFOLLOW) == -1) {
    error = errno;
    enif_mutex_unlock(entry->mutex);
    return make_errno_error(env, error);
  }
  if (!identity_matches(&stat, entry->device, entry->inode, entry->type) ||
      (entry->type == S_IFREG && stat.st_size != entry->size)) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_name_changed);
  }

  flags = entry->type == S_IFDIR ? AT_REMOVEDIR : 0;
  result = unlinkat(entry->parent_fd, entry->basename, flags);
  error = errno;
  if (result == 0) entry->removed = 1;
  enif_mutex_unlock(entry->mutex);
  return result == -1 ? make_errno_error(env, error) : atom_ok;
}

static ERL_NIF_TERM close_bound_nif(ErlNifEnv *env, int argc,
                                    const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  bound_entry_resource *entry;
  int parent_fd;
  int entry_fd;
  int parent_result;
  int entry_result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->bound_entry_resource_type,
                         (void **)&entry)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(entry->mutex);
  if (entry->parent_fd == -1 && entry->entry_fd == -1) {
    enif_mutex_unlock(entry->mutex);
    return make_error(env, atom_closed);
  }
  parent_fd = take_fd(&entry->parent_fd);
  entry_fd = take_fd(&entry->entry_fd);
  enif_mutex_unlock(entry->mutex);
  entry_result = close_owned_fd(entry_fd);
  error = errno;
  parent_result = close_owned_fd(parent_fd);
  if (entry_result == -1) return make_errno_error(env, error);
  return parent_result == -1 ? make_errno_error(env, errno) : atom_ok;
}

static ERL_NIF_TERM close_nif(ErlNifEnv *env, int argc,
                              const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  segment_resource *segment;
  int file_result;
  int file_error;
  int directory_result;
  int directory_error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->segment_resource_type,
                         (void **)&segment)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(segment->mutex);
  file_result = take_fd(&segment->file_fd);
  directory_result = take_fd(&segment->directory_fd);
  enif_mutex_unlock(segment->mutex);

  file_result = close_owned_fd(file_result);
  file_error = errno;
  directory_result = close_owned_fd(directory_result);
  directory_error = errno;

  if (file_result == -1) {
    return make_errno_error(env, file_error);
  }

  if (directory_result == -1) {
    return make_errno_error(env, directory_error);
  }

  return atom_ok;
}

static int load(ErlNifEnv *env, void **private_data, ERL_NIF_TERM load_info) {
  nif_state *state;
  int flags = ERL_NIF_RT_CREATE;
  (void)load_info;

  state = enif_alloc(sizeof(*state));
  if (state == NULL) {
    return -1;
  }
  memset(state, 0, sizeof(*state));

  state->root_resource_type = enif_open_resource_type(
      env, NULL, "outbox_segment_root", root_destructor, flags, NULL);
  state->segment_resource_type = enif_open_resource_type(
      env, NULL, "outbox_segment_file", segment_destructor, flags, NULL);
  state->adoption_resource_type = enif_open_resource_type(
      env, NULL, "atomic_file_adoption", adoption_destructor, flags, NULL);
  state->bound_entry_resource_type = enif_open_resource_type(
      env, NULL, "bound_filesystem_entry", bound_entry_destructor, flags, NULL);

  if (state->root_resource_type == NULL ||
      state->segment_resource_type == NULL ||
      state->adoption_resource_type == NULL ||
      state->bound_entry_resource_type == NULL ||
      cleanup_worker_start(&state->cleanup) != 0) {
    enif_free(state);
    return -1;
  }

  *private_data = state;
  atom_ok = enif_make_atom(env, "ok");
  atom_error = enif_make_atom(env, "error");
  atom_closed = enif_make_atom(env, "closed");
  atom_invalid_basename = enif_make_atom(env, "invalid_basename");
  atom_stale_root = enif_make_atom(env, "stale_root");
  atom_unlink_forbidden = enif_make_atom(env, "unlink_forbidden");
  atom_name_changed = enif_make_atom(env, "name_changed");
  atom_stale_source = enif_make_atom(env, "stale_source");
  atom_stale_source_parent = enif_make_atom(env, "stale_source_parent");
  atom_stale_destination_parent = enif_make_atom(env, "stale_destination_parent");
  atom_destination_mismatch = enif_make_atom(env, "destination_mismatch");
  atom_adopted = enif_make_atom(env, "adopted");
  atom_none = enif_make_atom(env, "none");
  atom_after_rename = enif_make_atom(env, "after_rename");
  atom_source_parent_sync = enif_make_atom(env, "source_parent_sync");
  atom_destination_parent_sync = enif_make_atom(env, "destination_parent_sync");
  atom_regular = enif_make_atom(env, "regular");
  atom_directory = enif_make_atom(env, "directory");
  atom_stale_entry = enif_make_atom(env, "stale_entry");
  return 0;
}

static void unload(ErlNifEnv *env, void *private_data) {
  nif_state *state = private_data;
  (void)env;

  cleanup_worker_stop(&state->cleanup);
  enif_free(state);
}

static ErlNifFunc nif_functions[] = {
    {"adoption_prepare", 3, adoption_prepare_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adoption_commit", 2, adoption_commit_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"adoption_close", 1, adoption_close_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"nif_open_root", 2, open_root_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close_root", 1, close_root_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"try_lock_root", 1, try_lock_root_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"create", 3, create_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"chmod", 2, chmod_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write", 2, write_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync_file", 1, sync_file_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync_directory", 1, sync_directory_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"unlink_empty", 1, unlink_empty_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"file_info", 1, file_info_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, close_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"bind_entry", 6, bind_entry_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"bound_info", 1, bound_info_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"read_bound", 2, read_bound_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync_bound", 1, sync_bound_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"remove_bound", 1, remove_bound_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close_bound", 1, close_bound_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}};

ERL_NIF_INIT(Elixir.RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem,
             nif_functions, load, NULL, NULL, unload)
