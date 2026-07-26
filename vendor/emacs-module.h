/* emacs-module.h - GNU Emacs module API.

Copyright (C) 2015-2026 Free Software Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.  */

/*
This file defines the Emacs module API.  Please see the chapter
`Dynamic Modules' in the GNU Emacs Lisp Reference Manual for
information how to write modules and use this header file.
*/

/*
This file is vendored from GNU Emacs 31
with local changes applied:

  - musl libc workaround: pre-define struct timespec before <time.h>
    so that Zig's translate-c sees a concrete struct instead of the
    opaque type produced by musl's bit-field padding expressions.
    Guard: __DEFINED_struct_timespec (musl's own include guard).
*/

#ifndef EMACS_MODULE_H
#define EMACS_MODULE_H

#include <stddef.h>
#include <stdint.h>

/* musl libc workaround — musl defines struct timespec using bit-field
   padding expressions that Zig's translate-c cannot parse, producing
   an opaque type.  Pre-define a plain struct that is ABI-compatible
   (tv_sec is time_t, tv_nsec is long, padded to 2 * sizeof(time_t))
   and set the musl guard macro so <time.h> skips its version.
   Bionic is also non-glibc but parses cleanly and has no
   <bits/alltypes.h>, so Android is excluded.  */
#ifndef __DEFINED_struct_timespec
#if defined(__linux__) && !defined(__GLIBC__) && !defined(__ANDROID__)
#define __NEED_time_t
#include <bits/alltypes.h>
#define __DEFINED_struct_timespec
struct timespec {
    time_t tv_sec;
    long   tv_nsec;
    char   __padding[sizeof(time_t) - sizeof(long)];
};
#endif
#endif

#include <time.h>

#if ((defined __STDC_VERSION__ ? __STDC_VERSION__ : 0) < 202311 \
     && !defined __bool_true_false_are_defined && !defined __cplusplus)
#include <stdbool.h>
#endif

#define EMACS_MAJOR_VERSION 31

#if defined __cplusplus && __cplusplus >= 201103L
# define EMACS_NOEXCEPT noexcept
#else
# define EMACS_NOEXCEPT
#endif

#if defined __cplusplus && __cplusplus >= 201703L
# define EMACS_NOEXCEPT_TYPEDEF noexcept
#else
# define EMACS_NOEXCEPT_TYPEDEF
#endif

#if 3 < __GNUC__ + (3 <= __GNUC_MINOR__)
# define EMACS_ATTRIBUTE_NONNULL(...) \
   __attribute__ ((__nonnull__ (__VA_ARGS__)))
#elif (defined __has_attribute \
       && (!defined __clang_minor__ \
	   || 3 < __clang_major__ + (5 <= __clang_minor__)))
# if __has_attribute (__nonnull__)
#  define EMACS_ATTRIBUTE_NONNULL(...) \
    __attribute__ ((__nonnull__ (__VA_ARGS__)))
# endif
#endif
#ifndef EMACS_ATTRIBUTE_NONNULL
# define EMACS_ATTRIBUTE_NONNULL(...)
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Current environment.  */
typedef struct emacs_env_31 emacs_env;

/* Opaque pointer representing an Emacs Lisp value.
   BEWARE: Do not assume NULL is a valid value!  */
typedef struct emacs_value_tag *emacs_value;

enum { emacs_variadic_function = -2 };

/* Struct passed to a module init function (emacs_module_init).  */
struct emacs_runtime
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_runtime_private *private_members;

  /* Return an environment pointer.  */
  emacs_env *(*get_environment) (struct emacs_runtime *runtime)
    EMACS_ATTRIBUTE_NONNULL (1);
};

/* Type aliases for function pointer types used in the module API.
   Note that we don't use these aliases directly in the API to be able
   to mark the function arguments as 'noexcept' before C++20.
   However, users can use them if they want.  */

/* Function prototype for the module Lisp functions.  These must not
   throw C++ exceptions.  */
typedef emacs_value (*emacs_function) (emacs_env *env, ptrdiff_t nargs,
                                       emacs_value *args,
                                       void *data)
  EMACS_NOEXCEPT_TYPEDEF EMACS_ATTRIBUTE_NONNULL (1);

/* Function prototype for module user-pointer and function finalizers.
   These must not throw C++ exceptions.  */
typedef void (*emacs_finalizer) (void *data) EMACS_NOEXCEPT_TYPEDEF;

/* Possible Emacs function call outcomes.  */
enum emacs_funcall_exit
{
  /* Function has returned normally.  */
  emacs_funcall_exit_return = 0,

  /* Function has signaled an error using `signal'.  */
  emacs_funcall_exit_signal = 1,

  /* Function has exited using `throw'.  */
  emacs_funcall_exit_throw = 2
};

/* Possible return values for emacs_env.process_input.  */
enum emacs_process_input_result
{
  /* Module code may continue  */
  emacs_process_input_continue = 0,

  /* Module code should return control to Emacs as soon as possible.  */
  emacs_process_input_quit = 1
};

/* Define emacs_limb_t so that it is likely to match GMP's mp_limb_t.
   This micro-optimization can help modules that use mpz_export and
   mpz_import, which operate more efficiently on mp_limb_t.  It's OK
   (if perhaps a bit slower) if the two types do not match, and
   modules shouldn't rely on the two types matching.  */
typedef size_t emacs_limb_t;
#define EMACS_LIMB_MAX SIZE_MAX

struct emacs_env_25
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);

};

struct emacs_env_26
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

};

struct emacs_env_27
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Processes pending input events and returns whether the module
     function should quit.  */
  enum emacs_process_input_result (*process_input) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL (1);

  struct timespec (*extract_time) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_time) (emacs_env *env, struct timespec time)
    EMACS_ATTRIBUTE_NONNULL (1);

  bool (*extract_big_integer) (emacs_env *env, emacs_value arg, int *sign,
                               ptrdiff_t *count, emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_big_integer) (emacs_env *env, int sign, ptrdiff_t count,
                                   const emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

};

struct emacs_env_28
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Processes pending input events and returns whether the module
     function should quit.  */
  enum emacs_process_input_result (*process_input) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL (1);

  struct timespec (*extract_time) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_time) (emacs_env *env, struct timespec time)
    EMACS_ATTRIBUTE_NONNULL (1);

  bool (*extract_big_integer) (emacs_env *env, emacs_value arg, int *sign,
                               ptrdiff_t *count, emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_big_integer) (emacs_env *env, int sign, ptrdiff_t count,
                                   const emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);


  void (*(*EMACS_ATTRIBUTE_NONNULL (1)
            get_function_finalizer) (emacs_env *env,
                                     emacs_value arg)) (void *) EMACS_NOEXCEPT;

  void (*set_function_finalizer) (emacs_env *env, emacs_value arg,
                                  void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL (1);

  int (*open_channel) (emacs_env *env, emacs_value pipe_process)
    EMACS_ATTRIBUTE_NONNULL (1);

  void (*make_interactive) (emacs_env *env, emacs_value function,
                            emacs_value spec)
    EMACS_ATTRIBUTE_NONNULL (1);

  /* Create a unibyte Lisp string from a string.  */
  emacs_value (*make_unibyte_string) (emacs_env *env,
				      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

};

struct emacs_env_29
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Processes pending input events and returns whether the module
     function should quit.  */
  enum emacs_process_input_result (*process_input) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL (1);

  struct timespec (*extract_time) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_time) (emacs_env *env, struct timespec time)
    EMACS_ATTRIBUTE_NONNULL (1);

  bool (*extract_big_integer) (emacs_env *env, emacs_value arg, int *sign,
                               ptrdiff_t *count, emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_big_integer) (emacs_env *env, int sign, ptrdiff_t count,
                                   const emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);


  void (*(*EMACS_ATTRIBUTE_NONNULL (1)
            get_function_finalizer) (emacs_env *env,
                                     emacs_value arg)) (void *) EMACS_NOEXCEPT;

  void (*set_function_finalizer) (emacs_env *env, emacs_value arg,
                                  void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL (1);

  int (*open_channel) (emacs_env *env, emacs_value pipe_process)
    EMACS_ATTRIBUTE_NONNULL (1);

  void (*make_interactive) (emacs_env *env, emacs_value function,
                            emacs_value spec)
    EMACS_ATTRIBUTE_NONNULL (1);

  /* Create a unibyte Lisp string from a string.  */
  emacs_value (*make_unibyte_string) (emacs_env *env,
				      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);



};

struct emacs_env_30
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Processes pending input events and returns whether the module
     function should quit.  */
  enum emacs_process_input_result (*process_input) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL (1);

  struct timespec (*extract_time) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_time) (emacs_env *env, struct timespec time)
    EMACS_ATTRIBUTE_NONNULL (1);

  bool (*extract_big_integer) (emacs_env *env, emacs_value arg, int *sign,
                               ptrdiff_t *count, emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_big_integer) (emacs_env *env, int sign, ptrdiff_t count,
                                   const emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);


  void (*(*EMACS_ATTRIBUTE_NONNULL (1)
            get_function_finalizer) (emacs_env *env,
                                     emacs_value arg)) (void *) EMACS_NOEXCEPT;

  void (*set_function_finalizer) (emacs_env *env, emacs_value arg,
                                  void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL (1);

  int (*open_channel) (emacs_env *env, emacs_value pipe_process)
    EMACS_ATTRIBUTE_NONNULL (1);

  void (*make_interactive) (emacs_env *env, emacs_value function,
                            emacs_value spec)
    EMACS_ATTRIBUTE_NONNULL (1);

  /* Create a unibyte Lisp string from a string.  */
  emacs_value (*make_unibyte_string) (emacs_env *env,
				      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);





};

struct emacs_env_31
{
  /* Structure size (for version checking).  */
  ptrdiff_t size;

  /* Private data; users should not touch this.  */
  struct emacs_env_private *private_members;

  /* Memory management.  */

  emacs_value (*make_global_ref) (emacs_env *env, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*free_global_ref) (emacs_env *env, emacs_value global_value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Non-local exit handling.  */

  enum emacs_funcall_exit (*non_local_exit_check) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_clear) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);

  enum emacs_funcall_exit (*non_local_exit_get)
    (emacs_env *env, emacs_value *symbol, emacs_value *data)
    EMACS_ATTRIBUTE_NONNULL(1, 2, 3);

  void (*non_local_exit_signal) (emacs_env *env,
				 emacs_value symbol, emacs_value data)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*non_local_exit_throw) (emacs_env *env,
				emacs_value tag, emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Function registration.  */

  emacs_value (*make_function) (emacs_env *env,
				ptrdiff_t min_arity,
				ptrdiff_t max_arity,
				emacs_value (*func) (emacs_env *env,
                                                     ptrdiff_t nargs,
                                                     emacs_value* args,
                                                     void *data)
				  EMACS_NOEXCEPT
                                  EMACS_ATTRIBUTE_NONNULL(1),
				const char *docstring,
				void *data)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  emacs_value (*funcall) (emacs_env *env,
                          emacs_value func,
                          ptrdiff_t nargs,
                          emacs_value* args)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*intern) (emacs_env *env, const char *name)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Type conversion.  */

  emacs_value (*type_of) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*is_not_nil) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  bool (*eq) (emacs_env *env, emacs_value a, emacs_value b)
    EMACS_ATTRIBUTE_NONNULL(1);

  intmax_t (*extract_integer) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_integer) (emacs_env *env, intmax_t n)
    EMACS_ATTRIBUTE_NONNULL(1);

  double (*extract_float) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);

  emacs_value (*make_float) (emacs_env *env, double d)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Copy the content of the Lisp string VALUE to BUFFER as an utf8
     null-terminated string.

     SIZE must point to the total size of the buffer.  If BUFFER is
     NULL or if SIZE is not big enough, write the required buffer size
     to SIZE and return true.

     Note that SIZE must include the last null byte (e.g. "abc" needs
     a buffer of size 4).

     Return true if the string was successfully copied.  */

  bool (*copy_string_contents) (emacs_env *env,
                                emacs_value value,
                                char *buf,
                                ptrdiff_t *len)
    EMACS_ATTRIBUTE_NONNULL(1, 4);

  /* Create a Lisp string from a utf8 encoded string.  */
  emacs_value (*make_string) (emacs_env *env,
			      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);

  /* Embedded pointer type.  */
  emacs_value (*make_user_ptr) (emacs_env *env,
				void (*fin) (void *) EMACS_NOEXCEPT,
				void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void *(*get_user_ptr) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_ptr) (emacs_env *env, emacs_value arg, void *ptr)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*(*get_user_finalizer) (emacs_env *env, emacs_value uptr))
    (void *) EMACS_NOEXCEPT EMACS_ATTRIBUTE_NONNULL(1);
  void (*set_user_finalizer) (emacs_env *env, emacs_value arg,
			      void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL(1);

  /* Vector functions.  */
  emacs_value (*vec_get) (emacs_env *env, emacs_value vector, ptrdiff_t index)
    EMACS_ATTRIBUTE_NONNULL(1);

  void (*vec_set) (emacs_env *env, emacs_value vector, ptrdiff_t index,
		   emacs_value value)
    EMACS_ATTRIBUTE_NONNULL(1);

  ptrdiff_t (*vec_size) (emacs_env *env, emacs_value vector)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Returns whether a quit is pending.  */
  bool (*should_quit) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL(1);


  /* Processes pending input events and returns whether the module
     function should quit.  */
  enum emacs_process_input_result (*process_input) (emacs_env *env)
    EMACS_ATTRIBUTE_NONNULL (1);

  struct timespec (*extract_time) (emacs_env *env, emacs_value arg)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_time) (emacs_env *env, struct timespec time)
    EMACS_ATTRIBUTE_NONNULL (1);

  bool (*extract_big_integer) (emacs_env *env, emacs_value arg, int *sign,
                               ptrdiff_t *count, emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);

  emacs_value (*make_big_integer) (emacs_env *env, int sign, ptrdiff_t count,
                                   const emacs_limb_t *magnitude)
    EMACS_ATTRIBUTE_NONNULL (1);


  void (*(*EMACS_ATTRIBUTE_NONNULL (1)
            get_function_finalizer) (emacs_env *env,
                                     emacs_value arg)) (void *) EMACS_NOEXCEPT;

  void (*set_function_finalizer) (emacs_env *env, emacs_value arg,
                                  void (*fin) (void *) EMACS_NOEXCEPT)
    EMACS_ATTRIBUTE_NONNULL (1);

  int (*open_channel) (emacs_env *env, emacs_value pipe_process)
    EMACS_ATTRIBUTE_NONNULL (1);

  void (*make_interactive) (emacs_env *env, emacs_value function,
                            emacs_value spec)
    EMACS_ATTRIBUTE_NONNULL (1);

  /* Create a unibyte Lisp string from a string.  */
  emacs_value (*make_unibyte_string) (emacs_env *env,
				      const char *str, ptrdiff_t len)
    EMACS_ATTRIBUTE_NONNULL(1, 2);






  /* Add module environment functions newly added in Emacs 31 here.
     Before Emacs 31 is released, remove this comment and start
     module-env-32.h on the master branch.  */

};

/* Every module should define a function as follows.  */
extern int emacs_module_init (struct emacs_runtime *runtime)
  EMACS_NOEXCEPT
  EMACS_ATTRIBUTE_NONNULL (1);

#ifdef __cplusplus
}
#endif

#endif /* EMACS_MODULE_H */
