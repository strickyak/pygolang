# -*- coding: utf-8 -*-
# cython: language_level=2
# cython: binding=False
# distutils: language = c++
# distutils: depends = libgolang.h
#
# Copyright (C) 2018-2019  Nexedi SA and Contributors.
#                          Kirill Smelkov <kirr@nexedi.com>
#
# This program is free software: you can Use, Study, Modify and Redistribute
# it under the terms of the GNU General Public License version 3, or (at your
# option) any later version, as published by the Free Software Foundation.
#
# You can also Link and Combine this program with other software covered by
# the terms of any of the Free Software licenses or any of the Open Source
# Initiative approved licenses and Convey the resulting work. Corresponding
# source of such a combination shall include the source code for all other
# software used.
#
# This program is distributed WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# See COPYING file for full licensing terms.
# See https://www.nexedi.com/licensing for rationale and options.
"""_golang.pyx provides Python interface to libgolang.{h,cpp}.

See _golang.pxd for package overview.
"""

from __future__ import print_function, absolute_import

# init libgolang runtime early
_init_libgolang()

from cpython cimport PyObject, Py_INCREF, Py_DECREF, PY_MAJOR_VERSION
ctypedef PyObject *pPyObject # https://github.com/cython/cython/issues/534
cdef extern from "Python.h":
    ctypedef struct PyTupleObject:
        PyObject **ob_item
    void Py_FatalError(const char *msg)

from libcpp.vector cimport vector
from cython cimport final

import sys

# ---- panic ----

@final
cdef class _PanicError(Exception):
    pass

# panic stops normal execution of current goroutine.
cpdef pypanic(arg):
    raise _PanicError(arg)

# topyexc converts C-level panic/exc to python panic/exc.
# (see usage in e.g. *_pyexc functions in "misc")
cdef void topyexc() except *:
    # TODO use libunwind/libbacktrace/libstacktrace/... to append C-level traceback
    #      from where it panicked till topyexc user.
    # TODO install C-level traceback dump as std::terminate handler.
    #
    # recover_ is declared `except +` - if it was another - not panic -
    # exception, it will be converted to py exc by cython automatically.
    arg = recover_()
    if arg != NULL:
        pyarg = <bytes>arg
        if PY_MAJOR_VERSION >= 3:
            pyarg = pyarg.decode("utf-8")
        pypanic(pyarg)

cdef extern from "golang/libgolang.h" nogil:
    const char *recover_ "golang::recover" () except +


# ---- go ----

# go spawns lightweight thread.
#
# go spawns:
#
# - lightweight thread (with    gevent integration), or
# - full OS thread     (without gevent integration).
#
# Use gpython to run Python with integrated gevent, or use gevent directly to do so.
def pygo(f, *argv, **kw):
    _ = _togo(); _.f = f; _.argv = argv; _.kw    = kw
    Py_INCREF(_)    # we transfer 1 ref to _goviac
    with nogil:
        _taskgo_pyexc(_goviac, <void*>_)

@final
cdef class _togo:
    cdef object f
    cdef tuple  argv
    cdef dict   kw

cdef extern from "Python.h" nogil:
    ctypedef struct PyGILState_STATE:
        pass
    PyGILState_STATE PyGILState_Ensure()
    void PyGILState_Release(PyGILState_STATE)

cdef void _goviac(void *arg) nogil:
    # create new py thread state and keep it alive while __goviac runs.
    #
    # Just `with gil` is not enough: for `with gil` if exceptions could be
    # raised inside, cython generates several GIL release/reacquire calls.
    # This way the thread state will be deleted on first release and _new_ one
    # - _another_ thread state - create on acquire. All that implicitly with
    # the effect of loosing things associated with thread state - e.g. current
    # exception.
    #
    # -> be explicit and manually keep py thread state alive ourselves.
    gstate = PyGILState_Ensure() # py thread state will stay alive until PyGILState_Release
    __goviac(arg)
    PyGILState_Release(gstate)

cdef void __goviac(void *arg) nogil:
    with gil:
        try:
            _ = <_togo>arg
            Py_DECREF(_)
            _.f(*_.argv, **_.kw)
        except:
            # ignore exceptions during python interpreter shutdown.
            # python clears sys and other modules at exit which can result in
            # arbitrary exceptions in still alive "daemon" threads that go
            # spawns. Similarly to threading.py(*) we just ignore them.
            #
            # if we don't - there could lots of output like e.g. "lost sys.stderr"
            # and/or "sys.excepthook is missing" etc.
            #
            # (*) github.com/python/cpython/tree/v2.7.16-121-g53639dd55a0/Lib/threading.py#L760-L778
            #     see also "Technical details" in stackoverflow.com/a/12807285/9456786.
            if sys is None:
                return

            raise   # XXX exception -> exit program with traceback (same as in go) ?


# ---- channels ----

# pychan is chan<object>.
@final
cdef class pychan:
    def __cinit__(pychan pych, size=0):
        pych._ch = _makechan_pyexc(sizeof(PyObject*), size)

    def __dealloc__(pychan pych):
        # on del: drain buffered channel to decref sent objects.
        # verify that the channel is not connected anywhere outside us.
        # (if it was present also somewhere else - draining would be incorrect)
        if pych._ch == NULL:
            return
        cdef int refcnt = _chanrefcnt(pych._ch)
        if refcnt != 1:
            # cannot raise py-level exception in __dealloc__
            Py_FatalError("pychan.__dealloc__: chan.refcnt=%d ; must be =1" % refcnt)

        cdef chan[pPyObject] ch = _wrapchan[pPyObject](pych._ch)
        _chanxdecref(pych._ch)
        pych._ch = NULL

        cdef PyObject *_rx
        while ch.len() != 0:
            # NOTE *not* chanrecv_pyexc(ch):
            # - recv must not block and must not panic as we verified that we
            #   are the only holder of the channel and that ch buffer is not empty.
            # - even if recv panics, we cannot convert that panic to python
            #   exception in __dealloc__. So if it really panics - let the
            #   panic make it and crash the process similarly to Py_FatalError above.
            _rx = ch.recv()
            Py_DECREF(<object>_rx)

        # ch is decref'ed automatically at return


    # send sends object to a receiver.
    def send(pychan pych, obj):
        cdef PyObject *_tx = <PyObject*>obj

        # increment obj reference count - until received the channel is holding pointer to the object.
        Py_INCREF(obj)

        try:
            with nogil:
                _chansend_pyexc(pych._ch, &_tx)
        except: # not only _PanicError as send can also throw e.g. bad_alloc
            # the object was not sent - e.g. it was "send on a closed channel"
            Py_DECREF(obj)
            raise

    # recv_ is "comma-ok" version of recv.
    #
    # ok is true - if receive was delivered by a successful send.
    # ok is false - if receive is due to channel being closed and empty.
    def recv_(pychan pych): # -> (rx, ok)
        cdef PyObject *_rx = NULL
        cdef bint ok

        with nogil:
            ok = _chanrecv__pyexc(pych._ch, &_rx)

        if not ok:
            return (None, ok)

        # we received the object and the channel dropped pointer to it.
        rx = <object>_rx
        Py_DECREF(rx)
        return (rx, ok)

    # recv receives from the channel.
    def recv(pychan pych): # -> rx
        rx, _ = pych.recv_()    # TODO call recv_ via C
        return rx

    # close closes sending side of the channel.
    def close(pychan pych):
        with nogil:
            _chanclose_pyexc(pych._ch)

    def __len__(pychan pych):
        return _chanlen_pyexc(pych._ch)

    def __repr__(pychan pych):
        if pych._ch == NULL:
            return "nilchan"
        else:
            return super(pychan, pych).__repr__()


# pynilchan is the nil py channel.
#
# On nil channel: send/recv block forever; close panics.
cdef pychan _pynilchan = pychan()
_chanxdecref(_pynilchan._ch)
_pynilchan._ch = NULL
pynilchan = _pynilchan


# pydefault represents default case for pyselect.
pydefault  = object()

# pyselect executes one ready send or receive channel case.
#
# if no case is ready and default case was provided, select chooses default.
# if no case is ready and default was not provided, select blocks until one case becomes ready.
#
# returns: selected case number and receive info (None if send case was selected).
#
# example:
#
#   _, _rx = select(
#       ch1.recv,           # 0
#       ch2.recv_,          # 1
#       (ch2.send, obj2),   # 2
#       default,            # 3
#   )
#   if _ == 0:
#       # _rx is what was received from ch1
#       ...
#   if _ == 1:
#       # _rx is (rx, ok) of what was received from ch2
#       ...
#   if _ == 2:
#       # we know obj2 was sent to ch2
#       ...
#   if _ == 3:
#       # default case
#       ...
def pyselect(*pycasev):
    cdef int i, n = len(pycasev), selected
    cdef vector[_selcase] casev = vector[_selcase](n, default)
    cdef pychan pych
    cdef PyObject *_rx = NULL # all select recvs are setup to receive into _rx
    cdef cbool rxok = False   # (its ok as only one receive will be actually executed)

    selected = -1
    try:
        # prepare casev for chanselect
        for i in range(n):
            pycase = pycasev[i]
            # default
            if pycase is pydefault:
                casev[i] = default

            # send
            elif type(pycase) is tuple:
                if len(pycase) != 2:
                    pypanic("pyselect: invalid [%d]() case" % len(pycase))
                _tcase = <PyTupleObject *>pycase

                pysend = <object>(_tcase.ob_item[0])
                if pysend.__self__.__class__ is not pychan:
                    pypanic("pyselect: send on non-chan: %r" % (pysend.__self__.__class__,))
                pych = pysend.__self__

                if pysend.__name__ != "send":       # XXX better check PyCFunction directly
                    pypanic("pyselect: send expected: %r" % (pysend,))

                tx = <object>(_tcase.ob_item[1])

                # incref tx as if corresponding channel is holding pointer to the object while it is being sent.
                # we'll decref the object if it won't be sent.
                # see pychan.send for details.
                Py_INCREF(tx)
                casev[i] = _selsend(pych._ch, NULL)
                casev[i].flags = _INPLACE_DATA
                (<PyObject **>&casev[i].itxrx)[0] = <PyObject *>tx

            # recv
            else:
                pyrecv = pycase
                if pyrecv.__self__.__class__ is not pychan:
                    pypanic("pyselect: recv on non-chan: %r" % (pyrecv.__self__.__class__,))
                pych = pyrecv.__self__

                if pyrecv.__name__ == "recv":       # XXX better check PyCFunction directly
                    casev[i] = _selrecv(pych._ch, &_rx)
                elif pyrecv.__name__ == "recv_":    # XXX better check PyCFunction directly
                    casev[i] = _selrecv_(pych._ch, &_rx, &rxok)
                else:
                    pypanic("pyselect: recv expected: %r" % (pyrecv,))

        with nogil:
            selected = _chanselect_pyexc(&casev[0], casev.size())

    finally:
        # decref not sent tx (see ^^^ send prepare)
        for i in range(n):
            if casev[i].op == _CHANSEND and (i != selected):
                _tx = (<PyObject **>casev[i].ptx())[0]
                tx  = <object>_tx
                Py_DECREF(tx)

    # return what was selected
    cdef _chanop op = casev[selected].op
    if op == _DEFAULT:
        return selected, None
    if op == _CHANSEND:
        return selected, None

    if op != _CHANRECV:
        raise AssertionError("pyselect: chanselect returned with bad op")
    # we received NULL or the object; if it is object, corresponding channel
    # dropped pointer to it (see pychan.recv_ for details).
    cdef object rx = None
    if _rx != NULL:
        rx = <object>_rx
        Py_DECREF(rx)

    if casev[selected].rxok != NULL:
        return selected, (rx, rxok)
    else:
        return selected, rx

# ---- init libgolang runtime ---

cdef extern from "golang/libgolang.h" namespace "golang" nogil:
    struct _libgolang_runtime_ops
    void _libgolang_init(const _libgolang_runtime_ops*)
from cpython cimport PyCapsule_Import

cdef void _init_libgolang() except*:
    # detect whether we are running under gevent or OS threads mode
    # -> use golang.runtime._runtime_(gevent|thread) as libgolang runtime.
    threadmod = "thread"
    if PY_MAJOR_VERSION >= 3:
        threadmod = "_thread"
    t = __import__(threadmod)
    runtime = "thread"
    if "gevent" in t.start_new_thread.__module__:
        runtime = "gevent"
    runtimemod = "golang.runtime." + "_runtime_" + runtime

    # PyCapsule_Import("golang.X") does not work properly while we are in the
    # process of importing golang (it tries to access "X" attribute of half-created
    # golang module). -> preimport runtimemod via regular import first.
    __import__(runtimemod)
    runtimecaps = (runtimemod + ".libgolang_runtime_ops").encode("utf-8") # py3
    cdef const _libgolang_runtime_ops *runtime_ops = \
        <const _libgolang_runtime_ops*>PyCapsule_Import(runtimecaps, 0)
    if runtime_ops == NULL:
        pypanic("init: %s: libgolang_runtime_ops=NULL" % runtimemod)
    _libgolang_init(runtime_ops)



# ---- misc ----

cdef extern from "golang/libgolang.h" namespace "golang" nogil:
    _chan  *_makechan(unsigned elemsize, unsigned size)
    chan[T] _wrapchan[T](_chan *)
    void    _chanxincref(_chan *ch)
    void    _chanxdecref(_chan *ch)
    int     _chanrefcnt(_chan *ch)
    void    _chansend(_chan *ch, const void *ptx)
    bint    _chanrecv_(_chan *ch, void *prx)
    void    _chanclose(_chan *ch)
    unsigned _chanlen(_chan *ch)

    int  _chanselect(_selcase *casev, int casec)
    _selcase _selsend(_chan *ch, const void *ptx)
    _selcase _selrecv(_chan *ch, void *prx)
    _selcase _selrecv_(_chan *ch, void *prx, bint *pok)

    void _taskgo(void (*f)(void *), void *arg)

cdef nogil:

    _chan* _makechan_pyexc(unsigned elemsize, unsigned size)    except +topyexc:
        return _makechan(elemsize, size)

    void _chansend_pyexc(_chan *ch, const void *ptx)            except +topyexc:
        _chansend(ch, ptx)

    bint _chanrecv__pyexc(_chan *ch, void *prx)                 except +topyexc:
        return _chanrecv_(ch, prx)

    void _chanclose_pyexc(_chan *ch)                            except +topyexc:
        _chanclose(ch)

    unsigned _chanlen_pyexc(_chan *ch)                          except +topyexc:
        return _chanlen(ch)

    int _chanselect_pyexc(const _selcase *casev, int casec)     except +topyexc:
        return _chanselect(casev, casec)

    void _taskgo_pyexc(void (*f)(void *) nogil, void *arg)      except +topyexc:
        _taskgo(f, arg)
