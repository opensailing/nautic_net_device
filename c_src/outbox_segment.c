#include <erl_driver.h>
#include <erl_nif.h>

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

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
  cleanup_worker cleanup;
} nif_state;

typedef struct {
  int fd;
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

static ERL_NIF_TERM atom_ok;
static ERL_NIF_TERM atom_error;
static ERL_NIF_TERM atom_closed;
static ERL_NIF_TERM atom_invalid_basename;
static ERL_NIF_TERM atom_stale_root;
static ERL_NIF_TERM atom_unlink_forbidden;
static ERL_NIF_TERM atom_name_changed;

static ERL_NIF_TERM make_error(ErlNifEnv *env, ERL_NIF_TERM reason) {
  return enif_make_tuple2(env, atom_error, reason);
}

static ERL_NIF_TERM make_errno_error(ErlNifEnv *env, int error) {
  const char *name = erl_errno_id(error);

  if (name != NULL) {
    return make_error(env, enif_make_atom(env, name));
  }

  return make_error(env, enif_make_int(env, error));
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
                                   int first_fd, int second_fd,
                                   char *allocation, ErlNifMutex *mutex) {
  cleanup_job *pending;

  if (job == NULL || state == NULL) {
    return;
  }

  job->first_fd = first_fd;
  job->second_fd = second_fd;
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
  (void)env;

  fd = take_fd(&root->fd);
  mutex = root->mutex;
  root->mutex = NULL;
  cleanup_worker_enqueue(root->cleanup_worker, root->cleanup, fd, -1, NULL,
                         mutex);
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
                         directory_fd, basename, mutex);
  segment->cleanup = NULL;
  segment->cleanup_worker = NULL;
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

static ERL_NIF_TERM close_root_nif(ErlNifEnv *env, int argc,
                                   const ERL_NIF_TERM argv[]) {
  nif_state *state = enif_priv_data(env);
  root_resource *root;
  int result;
  int error;

  if (argc != 1 ||
      !enif_get_resource(env, argv[0], state->root_resource_type,
                         (void **)&root)) {
    return enif_make_badarg(env);
  }

  enif_mutex_lock(root->mutex);
  result = take_fd(&root->fd);
  enif_mutex_unlock(root->mutex);

  if (result == -1) {
    return atom_ok;
  }

  result = close_owned_fd(result);
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

  if (state->root_resource_type == NULL ||
      state->segment_resource_type == NULL ||
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
  return 0;
}

static void unload(ErlNifEnv *env, void *private_data) {
  nif_state *state = private_data;
  (void)env;

  cleanup_worker_stop(&state->cleanup);
  enif_free(state);
}

static ErlNifFunc nif_functions[] = {
    {"nif_open_root", 2, open_root_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close_root", 1, close_root_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"create", 3, create_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"chmod", 2, chmod_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"write", 2, write_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync_file", 1, sync_file_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"sync_directory", 1, sync_directory_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"unlink_empty", 1, unlink_empty_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"file_info", 1, file_info_nif, ERL_NIF_DIRTY_JOB_IO_BOUND},
    {"close", 1, close_nif, ERL_NIF_DIRTY_JOB_IO_BOUND}};

ERL_NIF_INIT(Elixir.RacingOrg.Tracker.Pro.DurableDelivery.Outbox.SegmentFileSystem,
             nif_functions, load, NULL, NULL, unload)
