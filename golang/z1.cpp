// DEMO OF libgolang.
// g++ -g -static  -I..  -I../3rdparty/include -fno-permissive  z1.cpp $( find
// [a-y]* -name \*.cpp | grep -v _test[.] | grep -v py  )   cxx_test.cpp $
// ./a.out && echo OKAY Nando 0.000000 Created thread 140273270052544 Worker 1
// start Job one: result 144 Worker 1 end OKAY

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "cxx.h"
#include "libgolang.h"

using namespace std;
using namespace golang;

// go should spawn a task (coroutine/thread/...).
void runt_go(void (*f)(void*), void* arg) {
  typedef void* (*func)(void*);
  pthread_t id = 0;
  pthread_create(&id, nullptr, (func)f, arg);
  fprintf(stderr, "Created thread %lu\n", (unsigned long)id);
}

// sema_alloc should allocate a semaphore.
// if allocation fails it must return NULL.
_libgolang_sema* runt_sema_alloc(void) {
  auto mup = new pthread_mutex_t;
  *mup = PTHREAD_MUTEX_INITIALIZER;
  return (_libgolang_sema*)mup;
}

// sema_free should release previously allocated semaphore.
// libgolang guarantees to call it only once and only for a semaphore
// previously successfully allocated via sema_alloc.
void runt_sema_free(_libgolang_sema* p) {
  auto mup = (pthread_mutex_t*)p;
  delete mup;
}

// sema_acquire/sema_release should acquire/release live semaphore allocated via
// sema_alloc.
void runt_sema_acquire(_libgolang_sema* p) {
  auto mup = (pthread_mutex_t*)p;
  int z = pthread_mutex_lock(mup);
}
void runt_sema_release(_libgolang_sema* p) {
  auto mup = (pthread_mutex_t*)p;
  int z = pthread_mutex_unlock(mup);
}

// nanosleep should pause current goroutine for at least dt nanoseconds.
// nanosleep(0) is not noop - such call must be at least yielding to other
// goroutines.
void runt_nanosleep(uint64_t dt) {
  // int nanosleep(const struct timespec *req, struct timespec *_Nullable rem);
  // struct timespec { time_t   tv_sec; long     tv_nsec; }

  struct timespec req = {0, (long)dt};
  nanosleep(&req, nullptr);
}

// nanotime should return current time since EPOCH in nanoseconds.
uint64_t runt_nanotime(void) {
  // int clock_gettime(clockid_t clk_id, struct timespec *tp);
  struct timespec tp;
  int z = clock_gettime(CLOCK_MONOTONIC, &tp);
  return (uint64_t)tp.tv_nsec + (uint64_t)1000000000UL * (uint64_t)tp.tv_sec;
}

struct io {
  int fd;
};

// io_open should open file @path similarly to open(2), but the error is
// returned in out_syserr, _not_ in errno.
_libgolang_ioh* runt_io_open(int* out_syserr, const char* path, int flags,
                             mode_t mode) {
  auto* f = new struct io;
  f->fd = open(path, flags, mode);
  *out_syserr = (f->fd < 0) ? errno : 0;
  return (_libgolang_ioh*)f;
}

// io_fdopen should wrap OS-level file descriptor into libgolang IO handle.
// the ownership of sysfd is transferred to returned ioh.
_libgolang_ioh* runt_io_fdopen(int* out_syserr, int sysfd) {
  auto* f = new struct io;
  f->fd = sysfd;
  *out_syserr = (f->fd < 0) ? errno : 0;
  return (_libgolang_ioh*)f;
}

// io_close should close underlying file and release file resources
// associated with ioh. it will be called exactly once and with the
// guarantee that no other ioh operation is running durion io_close call.
int /*syserr*/ runt_io_close(_libgolang_ioh* ioh) {
  auto* io = (struct io*)ioh;
  int z = close(io->fd);
  return z;
}

// io_free should release ioh memory.
// it will be called exactly once after io_close.
void runt_io_free(_libgolang_ioh* ioh) {
  auto* io = (struct io*)ioh;
  delete io;
}

// io_sysfd should return OS-level file descriptor associated with
// libgolang IO handle. it should return -1 on error.
int /*sysfd*/ runt_io_sysfd(_libgolang_ioh* ioh) {
  auto* io = (struct io*)ioh;
  return io->fd;
}

// io_read should read up to count bytes of data from ioh.
// it should block if waiting for at least some data is needed.
// it should return read amount, 0 on EOF, or syserr on error.
int /*(n|syserr)*/ runt_io_read(_libgolang_ioh* ioh, void* buf, size_t count) {
  auto* io = (struct io*)ioh;
  return read(io->fd, buf, count);
}

// io_write should write up to count bytes of data into ioh.
// it should block if waiting is needed to write at least some data.
// it should return wrote amount, or syserr on error.
int /*(n|syserr)*/ runt_io_write(_libgolang_ioh* ioh, const void* buf,
                                 size_t count) {
  auto* io = (struct io*)ioh;
  return write(io->fd, buf, count);
}

// io_fstat should stat the file underlying ioh similarly to fstat(2).
int /*syserr*/ runt_io_fstat(struct stat* out_st, _libgolang_ioh* ioh) {
  auto* io = (struct io*)ioh;
  return fstat(io->fd, out_st);
}

void worker(golang::chan<int> ch, int param) {
  printf("Worker %d start\n", param);
  int x = ch.recv();
  ch.send(x * x);
  printf("Worker %d end\n", param);
}

void one() {
  golang::chan<int> ch = golang::makechan<int>();  // create new channel
  go(worker, ch, 1);  // spawn worker(chan<int>, int)
  ch.send(12);
  int result = ch.recv();
  printf("Job one: result %d\n", result);
}

extern void _test_cxx_dict();
extern void _test_cxx_set();

int main() {
  struct _libgolang_runtime_ops ops = {
      .go = runt_go,
      .sema_alloc = runt_sema_alloc,
      .sema_free = runt_sema_free,
      .sema_acquire = runt_sema_acquire,
      .sema_release = runt_sema_release,
      .nanosleep = runt_nanosleep,
      .nanotime = runt_nanotime,
      .io_open = runt_io_open,
      .io_fdopen = runt_io_fdopen,
      .io_close = runt_io_close,
      .io_free = runt_io_free,
      .io_sysfd = runt_io_sysfd,
      .io_read = runt_io_read,
      .io_write = runt_io_write,
      .io_fstat = runt_io_fstat,
  };

  _libgolang_init(&ops);

  _test_cxx_dict();
  _test_cxx_set();
  double aaa = 5;
  typeof(aaa) bbb = aaa * bbb;
  printf("Nando %f\n", bbb);
  one();
}
