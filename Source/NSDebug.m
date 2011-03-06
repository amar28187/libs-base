/** Debugging utilities for GNUStep and OpenStep
   Copyright (C) 1997,1999,2000,2001 Free Software Foundation, Inc.

   Written by:  Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: August 1997
   Extended by: Nicola Pero <n.pero@mi.flashnet.it>
   Date: December 2000, April 2001

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   <title>NSDebug utilities reference</title>
   $Date$ $Revision$
   */

#import "common.h"
#include <stdio.h>
#import "GSPrivate.h"
#import "GNUstepBase/GSLock.h"
#import "Foundation/NSArray.h"
#import "Foundation/NSData.h"
#import "Foundation/NSDictionary.h"
#import "Foundation/NSLock.h"
#import "Foundation/NSNotification.h"
#import "Foundation/NSNotificationQueue.h"
#import "Foundation/NSThread.h"
#import "Foundation/NSValue.h"

#if     HAVE_EXECINFO_H
#include        <execinfo.h>
#endif

typedef struct {
  Class	class;
  /* The following are used for statistical info */
  unsigned int	count;
  unsigned int	lastc;
  unsigned int	total;
  unsigned int   peak;
  /* The following are used to record actual objects */
  BOOL  is_recording;
  id    *recorded_objects;
  id    *recorded_tags;
  unsigned int   num_recorded_objects;
  unsigned int   stack_size;
} table_entry;

static	unsigned int	num_classes = 0;
static	unsigned int	table_size = 0;

static table_entry*	the_table = 0;

static BOOL	debug_allocation = NO;

static NSLock	*uniqueLock = nil;

static const char*	_GSDebugAllocationList(BOOL difference);
static const char*	_GSDebugAllocationListAll(void);

static void _GSDebugAllocationAdd(Class c, id o);
static void _GSDebugAllocationRemove(Class c, id o);

static void (*_GSDebugAllocationAddFunc)(Class c, id o)
  = _GSDebugAllocationAdd;
static void (*_GSDebugAllocationRemoveFunc)(Class c, id o)
  = _GSDebugAllocationRemove;

@interface GSDebugAlloc : NSObject
+ (void) initialize;
@end

@implementation GSDebugAlloc
+ (void) initialize
{
  uniqueLock = [GSLazyRecursiveLock new];
}
@end

/**
 * This functions allows to set own function callbacks for debugging allocation
 * of objects. Useful if you intend to write your own object allocation code.
 */
void
GSSetDebugAllocationFunctions(void (*newAddObjectFunc)(Class c, id o),
  void (*newRemoveObjectFunc)(Class c, id o))
{
  [uniqueLock lock];

  if (newAddObjectFunc && newRemoveObjectFunc)
    {	   	
      _GSDebugAllocationAddFunc = newAddObjectFunc;
      _GSDebugAllocationRemoveFunc = newRemoveObjectFunc;
    }
  else
    {
      // Back to default
      _GSDebugAllocationAddFunc = _GSDebugAllocationAdd;
      _GSDebugAllocationRemoveFunc = _GSDebugAllocationRemove;
    }

  [uniqueLock unlock];
}

/**
 * This function activates or deactivates object allocation debugging.<br />
 * Returns the previous state.<br />
 * You should call this function to activate
 * allocation debugging before using any of the other allocation
 * debugging functions such as GSDebugAllocationList() or
 * GSDebugAllocationTotal().<br />
 * Object allocation debugging
 * should not affect performance too much, and is very useful
 * as it allows you to monitor how many objects of each class
 * your application has allocated.
 */
BOOL
GSDebugAllocationActive(BOOL active)
{
  BOOL	old = debug_allocation;

  [GSDebugAlloc class];		/* Ensure thread support is working */
  debug_allocation = active ? YES : NO;
  return old;
}

/**
 * This function activates tracking all allocated instances of
 * the specified class c.<br />
 * This tracking can slow your
 * application down, so you should use it only when you are
 * into serious debugging.  Usually, you will monitor your
 * application by using the functions GSDebugAllocationList()
 * and similar, which do not slow things down much and return
 * the number of allocated instances; when
 * (if) by studying the reports generated by these functions
 * you have found a leak of objects of a certain class, and
 * if you can't figure out how to fix it by looking at the
 * code, you can use this function to start tracking
 * allocated instances of that class, and the following one
 * can sometime allow you to list the leaked objects directly.
 */
void
GSDebugAllocationActiveRecordingObjects(Class c)
{
  unsigned int i;

  GSDebugAllocationActive(YES);

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
	{
	  [uniqueLock lock];
	  the_table[i].is_recording = YES;
	  [uniqueLock unlock];
	  return;
	}
    }
  [uniqueLock lock];
  if (num_classes >= table_size)
    {
      int		more = table_size + 128;
      table_entry	*tmp;

      tmp = NSZoneMalloc(NSDefaultMallocZone(), more * sizeof(table_entry));

      if (tmp == 0)
	{
	  [uniqueLock unlock];
	  return;
	}
      if (the_table)
	{
	  memcpy(tmp, the_table, num_classes * sizeof(table_entry));
	  NSZoneFree(NSDefaultMallocZone(), the_table);
	}
      the_table = tmp;
      table_size = more;
    }
  the_table[num_classes].class = c;
  the_table[num_classes].count = 0;
  the_table[num_classes].lastc = 0;
  the_table[num_classes].total = 0;
  the_table[num_classes].peak = 0;
  the_table[num_classes].is_recording = YES;
  the_table[num_classes].recorded_objects = NULL;
  the_table[num_classes].recorded_tags = NULL;
  the_table[num_classes].num_recorded_objects = 0;
  the_table[num_classes].stack_size = 0;
  num_classes++;
  [uniqueLock unlock];
}

void
GSDebugAllocationAdd(Class c, id o)
{
  (*_GSDebugAllocationAddFunc)(c,o);
}

void
_GSDebugAllocationAdd(Class c, id o)
{
  if (debug_allocation == YES)
    {
      unsigned int	i;

      for (i = 0; i < num_classes; i++)
	{
	  if (the_table[i].class == c)
	    {
	      [uniqueLock lock];
	      the_table[i].count++;
	      the_table[i].total++;
	      if (the_table[i].count > the_table[i].peak)
		{
		  the_table[i].peak = the_table[i].count;
		}
	      if (the_table[i].is_recording == YES)
		{
		  if (the_table[i].num_recorded_objects
		    >= the_table[i].stack_size)
		    {
		      int	more = the_table[i].stack_size + 128;
		      id	*tmp;
		      id	*tmp1;

		      tmp = NSZoneMalloc(NSDefaultMallocZone(),
					 more * sizeof(id));
		      if (tmp == 0)
			{
			  [uniqueLock unlock];
			  return;
			}

		      tmp1 = NSZoneMalloc(NSDefaultMallocZone(),
					 more * sizeof(id));
		      if (tmp1 == 0)
			{
			  NSZoneFree(NSDefaultMallocZone(),  tmp);
			  [uniqueLock unlock];
			  return;
			}


		      if (the_table[i].recorded_objects != NULL)
			{
			  memcpy(tmp, the_table[i].recorded_objects,
				 the_table[i].num_recorded_objects
				 * sizeof(id));
			  NSZoneFree(NSDefaultMallocZone(),
				     the_table[i].recorded_objects);
			  memcpy(tmp1, the_table[i].recorded_tags,
				 the_table[i].num_recorded_objects
				 * sizeof(id));
			  NSZoneFree(NSDefaultMallocZone(),
				     the_table[i].recorded_tags);
			}
		      the_table[i].recorded_objects = tmp;
		      the_table[i].recorded_tags = tmp1;
		      the_table[i].stack_size = more;
		    }
		
		  (the_table[i].recorded_objects)
		    [the_table[i].num_recorded_objects] = o;
		  (the_table[i].recorded_tags)
		    [the_table[i].num_recorded_objects] = nil;
		  the_table[i].num_recorded_objects++;
		}
	      [uniqueLock unlock];
	      return;
	    }
	}
      [uniqueLock lock];
      if (num_classes >= table_size)
	{
	  unsigned int	more = table_size + 128;
	  table_entry	*tmp;
	
	  tmp = NSZoneMalloc(NSDefaultMallocZone(), more * sizeof(table_entry));
	
	  if (tmp == 0)
	    {
	      [uniqueLock unlock];
	      return;		/* Argh	*/
	    }
	  if (the_table)
	    {
	      memcpy(tmp, the_table, num_classes * sizeof(table_entry));
	      NSZoneFree(NSDefaultMallocZone(), the_table);
	    }
	  the_table = tmp;
	  table_size = more;
	}
      the_table[num_classes].class = c;
      the_table[num_classes].count = 1;
      the_table[num_classes].lastc = 0;
      the_table[num_classes].total = 1;
      the_table[num_classes].peak = 1;
      the_table[num_classes].is_recording = NO;
      the_table[num_classes].recorded_objects = NULL;
      the_table[num_classes].recorded_tags = NULL;
      the_table[num_classes].num_recorded_objects = 0;
      the_table[num_classes].stack_size = 0;
      num_classes++;
      [uniqueLock unlock];
    }
}

/**
 * <p>
 *   Returns the number
 *   of instances of the specified class which are currently
 *   allocated.  This number is very important to detect memory
 *   leaks.  If you notice that this number is constantly
 *   increasing without apparent reason, it is very likely a
 *   memory leak - you need to check that you are correctly
 *   releasing objects of this class, otherwise when your
 *   application runs for a long time, it will eventually
 *   allocate so many objects as to eat up all your system's
 *   memory ...
 * </p>
 * <p>
 *   This function, like the ones below, returns the number of
 *   objects allocated/released from the time when
 *   GSDebugAllocationActive() was first called.  A negative
 *   number means that in total, there are less objects of this
 *   class allocated now than there were when you called
 *   GSDebugAllocationActive(); a positive one means there are
 *   more.
 * </p>
 */
int
GSDebugAllocationCount(Class c)
{
  unsigned int	i;

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
	{
	  return the_table[i].count;
	}
    }
  return 0;
}

/**
 * Returns the total
 * number of instances of the specified class c which have been
 * allocated - basically the number of times you have
 * allocated an object of this class.  If this number is very
 * high, it means you are creating a lot of objects of this
 * class; even if you are releasing them correctly, you must
 * not forget that allocating and deallocating objects is
 * usually one of the slowest things you can do, so you might
 * want to consider whether you can reduce the number of
 * allocations and deallocations that you are doing - for
 * example, by recycling objects of this class, uniquing
 * them, and/or using some sort of flyweight pattern.  It
 * might also be possible that you are unnecessarily creating
 * too many objects of this class.  Well - of course some times
 * there is nothing you can do about it.
 */
int
GSDebugAllocationTotal(Class c)
{
  unsigned int	i;

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
	{
	  return the_table[i].total;
	}
    }
  return 0;
}

/**
 * Returns the peak
 * number of instances of the specified class which have been
 * concurrently allocated.  If this number is very high, it
 * means at some point in time you had a situation with a
 * huge number of objects of this class allocated - this is
 * an indicator that probably at some point in time your
 * application was using a lot of memory - so you might want
 * to investigate whether you can prevent this problem by
 * inserting autorelease pools in your application's
 * processing loops.
 */
int
GSDebugAllocationPeak(Class c)
{
  unsigned int	i;

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
	{
	  return the_table[i].peak;
	}
    }
  return 0;
}

/**
 * This function returns a NULL
 * terminated array listing all the classes for which
 * statistical information has been collected.  Usually, you
 * call this function, and then loop on all the classes returned,
 * and for each one you get current, peak and total count by
 * using GSDebugAllocationCount(), GSDebugAllocationPeak() and
 * GSDebugAllocationTotal().
 */
Class *
GSDebugAllocationClassList()
{
  Class *ans;
  size_t siz;
  unsigned int	i;

  [uniqueLock lock];

  siz = sizeof(Class) * (num_classes + 1);
  ans = NSZoneMalloc(NSDefaultMallocZone(), siz);

  for (i = 0; i < num_classes; i++)
    {
      ans[i] = the_table[i].class;
    }
  ans[num_classes] = NULL;

  [uniqueLock unlock];

  return ans;
}

/**
 * This function returns a newline
 * separated list of the classes which have instances
 * allocated, and the instance counts.  If the 'changeFlag'
 * argument is YES then the list gives the number of
 * instances allocated/deallocated since the function was
 * last called.  This function only returns the current count
 * of instances (not the peak or total count), but its output
 * is ready to be displayed or logged.
 */
const char*
GSDebugAllocationList(BOOL changeFlag)
{
  const char	*ans;
  NSData	*d;

  if (debug_allocation == NO)
    {
      return "Debug allocation system is not active!\n";
    }
  [uniqueLock lock];
  ans = _GSDebugAllocationList(changeFlag);
  d = [NSData dataWithBytes: ans length: strlen(ans) + 1];
  [uniqueLock unlock];
  return (const char*)[d bytes];
}

static const char*
_GSDebugAllocationList(BOOL difference)
{
  unsigned int	pos = 0;
  unsigned int	i;
  static unsigned int	siz = 0;
  static char	*buf = 0;

  for (i = 0; i < num_classes; i++)
    {
      int	val = the_table[i].count;

      if (difference)
	{
	  val -= the_table[i].lastc;
	}
      if (val != 0)
	{
	  pos += 11 + strlen(class_getName(the_table[i].class));
	}
    }
  if (pos == 0)
    {
      if (difference)
	{
	  return "There are NO newly allocated or deallocated object!\n";
	}
      else
	{
	  return "I can find NO allocated object!\n";
	}
    }

  pos++;

  if (pos > siz)
    {
      if (pos & 0xff)
	{
	  pos = ((pos >> 8) + 1) << 8;
	}
      siz = pos;
      if (buf)
	{
	  NSZoneFree(NSDefaultMallocZone(), buf);
	}
      buf = NSZoneMalloc(NSDefaultMallocZone(), siz);
    }

  if (buf)
    {
      pos = 0;
      for (i = 0; i < num_classes; i++)
	{
	  int	val = the_table[i].count;

	  if (difference)
	    {
	      val -= the_table[i].lastc;
	    }
	  the_table[i].lastc = the_table[i].count;

	  if (val != 0)
	    {
	      sprintf(&buf[pos], "%d\t%s\n", val, class_getName(the_table[i].class));
	      pos += strlen(&buf[pos]);
	    }
	}
    }
  return buf;
}

/**
 * This function returns a newline
 * separated list of the classes which have had instances
 * allocated at any point, and the total count of the number
 * of instances allocated for each class.  The difference with
 * GSDebugAllocationList() is that this function returns also
 * classes which have no objects allocated at the moment, but
 * which had in the past.
 */
const char*
GSDebugAllocationListAll()
{
  const char	*ans;
  NSData	*d;

  if (debug_allocation == NO)
    {
      return "Debug allocation system is not active!\n";
    }
  [uniqueLock lock];
  ans = _GSDebugAllocationListAll();
  d = [NSData dataWithBytes: ans length: strlen(ans)+1];
  [uniqueLock unlock];
  return (const char*)[d bytes];
}

static const char*
_GSDebugAllocationListAll(void)
{
  unsigned int	pos = 0;
  unsigned int	i;
  static unsigned int	siz = 0;
  static char	*buf = 0;

  for (i = 0; i < num_classes; i++)
    {
      int	val = the_table[i].total;

      if (val != 0)
	{
	  pos += 11 + strlen(class_getName(the_table[i].class));
	}
    }
  if (pos == 0)
    {
      return "I can find NO allocated object!\n";
    }
  pos++;

  if (pos > siz)
    {
      if (pos & 0xff)
	{
	  pos = ((pos >> 8) + 1) << 8;
	}
      siz = pos;
      if (buf)
	{
	  NSZoneFree(NSDefaultMallocZone(), buf);
	}
      buf = NSZoneMalloc(NSDefaultMallocZone(), siz);
    }

  if (buf)
    {
      pos = 0;
      for (i = 0; i < num_classes; i++)
	{
	  int	val = the_table[i].total;

	  if (val != 0)
	    {
	      sprintf(&buf[pos], "%d\t%s\n", val, class_getName(the_table[i].class));
	      pos += strlen(&buf[pos]);
	    }
	}
    }
  return buf;
}

void
GSDebugAllocationRemove(Class c, id o)
{
  (*_GSDebugAllocationRemoveFunc)(c,o);
}

void
_GSDebugAllocationRemove(Class c, id o)
{
  if (debug_allocation == YES)
    {
      unsigned int	i;

      for (i = 0; i < num_classes; i++)
	{
	  if (the_table[i].class == c)
	    {
	      id	tag = nil;

	      [uniqueLock lock];
	      the_table[i].count--;
	      if (the_table[i].is_recording)
		{
		  unsigned j, k;

		  for (j = 0; j < the_table[i].num_recorded_objects; j++)
		    {
		      if ((the_table[i].recorded_objects)[j] == o)
			{
			  tag = (the_table[i].recorded_tags)[j];
			  break;
			}
		    }
		  if (j < the_table[i].num_recorded_objects)
		    {
		      for (k = j;
			   k + 1 < the_table[i].num_recorded_objects;
			   k++)
			{
			  (the_table[i].recorded_objects)[k] =
			    (the_table[i].recorded_objects)[k + 1];
			  (the_table[i].recorded_tags)[k] =
			    (the_table[i].recorded_tags)[k + 1];
			}
		      the_table[i].num_recorded_objects--;
		    }
		  else
		    {
		      /* Not found - no problem - this happens if the
                         object was allocated before we started
                         recording */
		      ;
		    }
		}
	      [uniqueLock unlock];
	      [tag release];
	      return;
	    }
	}
    }
}

/**
 * This function associates the supplied tag with a recorded
 * object and returns the tag which was previously associated
 * with it (if any).<br />
 * If the object was not recorded, the method returns nil<br />
 * The tag is retained while it is associated with the object.
 */
id
GSDebugAllocationTagRecordedObject(id object, id tag)
{
  Class c = [object class];
  id	o = nil;
  int	i;
  int	j;

  if (debug_allocation == NO)
    {
      return nil;
    }
  [uniqueLock lock];

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
      {
	  break;
	}
    }

  if (i == num_classes
    || the_table[i].is_recording == NO
    || the_table[i].num_recorded_objects == 0)
    {
      [uniqueLock unlock];
      return nil;
    }

  for (j = 0; j < the_table[i].num_recorded_objects; j++)
    {
      if (the_table[i].recorded_objects[j] == object)
	{
	  o = the_table[i].recorded_tags[j];
	  the_table[i].recorded_tags[j] = RETAIN(tag);
	  break;
	}
    }

  [uniqueLock unlock];
  return AUTORELEASE(o);
}

/**
 * This function returns an array
 * containing all the allocated objects of a certain class
 * which have been recorded ... to start the recording, you need
 * to invoke GSDebugAllocationActiveRecordingObjects().
 * Presumably, you will immediately call [NSObject-description] on them
 * to find out the objects you are leaking.  The objects are
 * returned in an array, so until the array is autoreleased,
 * the objects are not released.
 */
NSArray *
GSDebugAllocationListRecordedObjects(Class c)
{
  NSArray *answer;
  unsigned int i, k;
  id *tmp;

  if (debug_allocation == NO)
    {
      return nil;
    }

  [uniqueLock lock];

  for (i = 0; i < num_classes; i++)
    {
      if (the_table[i].class == c)
	{
	  break;
	}
    }

  if (i == num_classes)
    {
      [uniqueLock unlock];
      return nil;
    }

  if (the_table[i].is_recording == NO)
    {
      [uniqueLock unlock];
      return nil;
    }

  if (the_table[i].num_recorded_objects == 0)
    {
      [uniqueLock unlock];
      return [NSArray array];
    }

  tmp = NSZoneMalloc(NSDefaultMallocZone(),
		     the_table[i].num_recorded_objects * sizeof(id));
  if (tmp == 0)
    {
      [uniqueLock unlock];
      return nil;
    }

  /* First, we copy the objects into a temporary buffer */
  memcpy(tmp, the_table[i].recorded_objects,
	 the_table[i].num_recorded_objects * sizeof(id));

  /* Retain all the objects - NB: if retaining one of the objects as a
     side effect eleases another one of them , we are broken ... */
#if	!GS_WITH_GC
  for (k = 0; k < the_table[i].num_recorded_objects; k++)
    {
      [tmp[k] retain];
    }
#endif

  /* Then, we bravely unlock the lock */
  [uniqueLock unlock];

  /* Only then we create an array with them - this is now safe as we
     have copied the objects out, unlocked, and retained them. */
  answer = [NSArray arrayWithObjects: tmp
		    count: the_table[i].num_recorded_objects];

  /* Now we release all the objects to balance the retain */
  for (k = 0; k < the_table[i].num_recorded_objects; k++)
    {
      RELEASE (tmp[k]);
    }

  /* And free the space used by them */
  NSZoneFree(NSDefaultMallocZone(), tmp);

  return answer;
}

#if	!defined(HAVE_BUILTIN_EXTRACT_RETURN_ADDRESS)
# define	__builtin_extract_return_address(X)	X
#endif

#define _NS_FRAME_HACK(a) \
case a: env->addr = __builtin_frame_address(a + 1); break;
#define _NS_RETURN_HACK(a) \
case a: env->addr = (__builtin_frame_address(a + 1) ? \
__builtin_extract_return_address(__builtin_return_address(a + 1)) : 0); break;

/*
 * The following horrible signal handling code is a workaround for the fact
 * that the __builtin_frame_address() and __builtin_return_address()
 * functions are not reliable (at least not on my EM64T based system) and
 * will sometimes walk off the stack and access illegal memory locations.
 * In order to prevent such an occurrance from crashing the application,
 * we use sigsetjmp() and siglongjmp() to ensure that we can recover, and
 * we keep the jump buffer in thread-local memory to avoid possible thread
 * safety issues.
 * Of course this will fail horribly if an exception occurs in one of the
 * few methods we use to manage the per-thread jump buffer.
 */
#include <signal.h>
#include <setjmp.h>

#if	defined(__MINGW__)
#ifndef SIGBUS
#define SIGBUS  SIGILL
#endif
#endif

/* sigsetjmp may be a function or a macro.  The test for the function is
 * done at configure time so we can tell here if either is available.
 */
#if	!defined(HAVE_SIGSETJMP) && !defined(sigsetjmp)
#define	siglongjmp(A,B)	longjmp(A,B)
#define	sigsetjmp(A,B)	setjmp(A)
#define	sigjmp_buf	jmp_buf
#endif

typedef struct {
  sigjmp_buf    buf;
  void          *addr;
  void          (*bus)(int);
  void          (*segv)(int);
} jbuf_type;

static jbuf_type *
jbuf()
{
  NSMutableData	*d;
  NSMutableDictionary	*dict;

  dict = [[NSThread currentThread] threadDictionary];
  d = [dict objectForKey: @"GSjbuf"];
  if (d == nil)
    {
      d = [[NSMutableData alloc] initWithLength: sizeof(jbuf_type)];
      [dict setObject: d forKey: @"GSjbuf"];
      RELEASE(d);
    }
  return (jbuf_type*)[d mutableBytes];
}

static void
recover(int sig)
{
  siglongjmp(jbuf()->buf, 1);
}

void *
NSFrameAddress(NSUInteger offset)
{
  jbuf_type     *env;

  env = jbuf();
  if (sigsetjmp(env->buf, 1) == 0)
    {
      env->segv = signal(SIGSEGV, recover);
      env->bus = signal(SIGBUS, recover);
      switch (offset)
	{
	  _NS_FRAME_HACK(0); _NS_FRAME_HACK(1); _NS_FRAME_HACK(2);
	  _NS_FRAME_HACK(3); _NS_FRAME_HACK(4); _NS_FRAME_HACK(5);
	  _NS_FRAME_HACK(6); _NS_FRAME_HACK(7); _NS_FRAME_HACK(8);
	  _NS_FRAME_HACK(9); _NS_FRAME_HACK(10); _NS_FRAME_HACK(11);
	  _NS_FRAME_HACK(12); _NS_FRAME_HACK(13); _NS_FRAME_HACK(14);
	  _NS_FRAME_HACK(15); _NS_FRAME_HACK(16); _NS_FRAME_HACK(17);
	  _NS_FRAME_HACK(18); _NS_FRAME_HACK(19); _NS_FRAME_HACK(20);
	  _NS_FRAME_HACK(21); _NS_FRAME_HACK(22); _NS_FRAME_HACK(23);
	  _NS_FRAME_HACK(24); _NS_FRAME_HACK(25); _NS_FRAME_HACK(26);
	  _NS_FRAME_HACK(27); _NS_FRAME_HACK(28); _NS_FRAME_HACK(29);
	  _NS_FRAME_HACK(30); _NS_FRAME_HACK(31); _NS_FRAME_HACK(32);
	  _NS_FRAME_HACK(33); _NS_FRAME_HACK(34); _NS_FRAME_HACK(35);
	  _NS_FRAME_HACK(36); _NS_FRAME_HACK(37); _NS_FRAME_HACK(38);
	  _NS_FRAME_HACK(39); _NS_FRAME_HACK(40); _NS_FRAME_HACK(41);
	  _NS_FRAME_HACK(42); _NS_FRAME_HACK(43); _NS_FRAME_HACK(44);
	  _NS_FRAME_HACK(45); _NS_FRAME_HACK(46); _NS_FRAME_HACK(47);
	  _NS_FRAME_HACK(48); _NS_FRAME_HACK(49); _NS_FRAME_HACK(50);
	  _NS_FRAME_HACK(51); _NS_FRAME_HACK(52); _NS_FRAME_HACK(53);
	  _NS_FRAME_HACK(54); _NS_FRAME_HACK(55); _NS_FRAME_HACK(56);
	  _NS_FRAME_HACK(57); _NS_FRAME_HACK(58); _NS_FRAME_HACK(59);
	  _NS_FRAME_HACK(60); _NS_FRAME_HACK(61); _NS_FRAME_HACK(62);
	  _NS_FRAME_HACK(63); _NS_FRAME_HACK(64); _NS_FRAME_HACK(65);
	  _NS_FRAME_HACK(66); _NS_FRAME_HACK(67); _NS_FRAME_HACK(68);
	  _NS_FRAME_HACK(69); _NS_FRAME_HACK(70); _NS_FRAME_HACK(71);
	  _NS_FRAME_HACK(72); _NS_FRAME_HACK(73); _NS_FRAME_HACK(74);
	  _NS_FRAME_HACK(75); _NS_FRAME_HACK(76); _NS_FRAME_HACK(77);
	  _NS_FRAME_HACK(78); _NS_FRAME_HACK(79); _NS_FRAME_HACK(80);
	  _NS_FRAME_HACK(81); _NS_FRAME_HACK(82); _NS_FRAME_HACK(83);
	  _NS_FRAME_HACK(84); _NS_FRAME_HACK(85); _NS_FRAME_HACK(86);
	  _NS_FRAME_HACK(87); _NS_FRAME_HACK(88); _NS_FRAME_HACK(89);
	  _NS_FRAME_HACK(90); _NS_FRAME_HACK(91); _NS_FRAME_HACK(92);
	  _NS_FRAME_HACK(93); _NS_FRAME_HACK(94); _NS_FRAME_HACK(95);
	  _NS_FRAME_HACK(96); _NS_FRAME_HACK(97); _NS_FRAME_HACK(98);
	  _NS_FRAME_HACK(99);
	  default: env->addr = NULL; break;
	}
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }
  else
    {
      env = jbuf();
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
      env->addr = NULL;
    }
  return env->addr;
}

NSUInteger NSCountFrames(void)
{
  jbuf_type	*env;

  env = jbuf();
  if (sigsetjmp(env->buf, 1) == 0)
    {
      env->segv = signal(SIGSEGV, recover);
      env->bus = signal(SIGBUS, recover);
      env->addr = 0;

#define _NS_COUNT_HACK(X) if (__builtin_frame_address(X + 1) == 0) \
        goto done; else env->addr = (void*)(X + 1);

      _NS_COUNT_HACK(0); _NS_COUNT_HACK(1); _NS_COUNT_HACK(2);
      _NS_COUNT_HACK(3); _NS_COUNT_HACK(4); _NS_COUNT_HACK(5);
      _NS_COUNT_HACK(6); _NS_COUNT_HACK(7); _NS_COUNT_HACK(8);
      _NS_COUNT_HACK(9); _NS_COUNT_HACK(10); _NS_COUNT_HACK(11);
      _NS_COUNT_HACK(12); _NS_COUNT_HACK(13); _NS_COUNT_HACK(14);
      _NS_COUNT_HACK(15); _NS_COUNT_HACK(16); _NS_COUNT_HACK(17);
      _NS_COUNT_HACK(18); _NS_COUNT_HACK(19); _NS_COUNT_HACK(20);
      _NS_COUNT_HACK(21); _NS_COUNT_HACK(22); _NS_COUNT_HACK(23);
      _NS_COUNT_HACK(24); _NS_COUNT_HACK(25); _NS_COUNT_HACK(26);
      _NS_COUNT_HACK(27); _NS_COUNT_HACK(28); _NS_COUNT_HACK(29);
      _NS_COUNT_HACK(30); _NS_COUNT_HACK(31); _NS_COUNT_HACK(32);
      _NS_COUNT_HACK(33); _NS_COUNT_HACK(34); _NS_COUNT_HACK(35);
      _NS_COUNT_HACK(36); _NS_COUNT_HACK(37); _NS_COUNT_HACK(38);
      _NS_COUNT_HACK(39); _NS_COUNT_HACK(40); _NS_COUNT_HACK(41);
      _NS_COUNT_HACK(42); _NS_COUNT_HACK(43); _NS_COUNT_HACK(44);
      _NS_COUNT_HACK(45); _NS_COUNT_HACK(46); _NS_COUNT_HACK(47);
      _NS_COUNT_HACK(48); _NS_COUNT_HACK(49); _NS_COUNT_HACK(50);
      _NS_COUNT_HACK(51); _NS_COUNT_HACK(52); _NS_COUNT_HACK(53);
      _NS_COUNT_HACK(54); _NS_COUNT_HACK(55); _NS_COUNT_HACK(56);
      _NS_COUNT_HACK(57); _NS_COUNT_HACK(58); _NS_COUNT_HACK(59);
      _NS_COUNT_HACK(60); _NS_COUNT_HACK(61); _NS_COUNT_HACK(62);
      _NS_COUNT_HACK(63); _NS_COUNT_HACK(64); _NS_COUNT_HACK(65);
      _NS_COUNT_HACK(66); _NS_COUNT_HACK(67); _NS_COUNT_HACK(68);
      _NS_COUNT_HACK(69); _NS_COUNT_HACK(70); _NS_COUNT_HACK(71);
      _NS_COUNT_HACK(72); _NS_COUNT_HACK(73); _NS_COUNT_HACK(74);
      _NS_COUNT_HACK(75); _NS_COUNT_HACK(76); _NS_COUNT_HACK(77);
      _NS_COUNT_HACK(78); _NS_COUNT_HACK(79); _NS_COUNT_HACK(80);
      _NS_COUNT_HACK(81); _NS_COUNT_HACK(82); _NS_COUNT_HACK(83);
      _NS_COUNT_HACK(84); _NS_COUNT_HACK(85); _NS_COUNT_HACK(86);
      _NS_COUNT_HACK(87); _NS_COUNT_HACK(88); _NS_COUNT_HACK(89);
      _NS_COUNT_HACK(90); _NS_COUNT_HACK(91); _NS_COUNT_HACK(92);
      _NS_COUNT_HACK(93); _NS_COUNT_HACK(94); _NS_COUNT_HACK(95);
      _NS_COUNT_HACK(96); _NS_COUNT_HACK(97); _NS_COUNT_HACK(98);
      _NS_COUNT_HACK(99);

done:
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }
  else
    {
      env = jbuf();
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }

  return (uintptr_t)env->addr;
}

void *
NSReturnAddress(NSUInteger offset)
{
  jbuf_type	*env;

  env = jbuf();
  if (sigsetjmp(env->buf, 1) == 0)
    {
      env->segv = signal(SIGSEGV, recover);
      env->bus = signal(SIGBUS, recover);
      switch (offset)
	{
	  _NS_RETURN_HACK(0); _NS_RETURN_HACK(1); _NS_RETURN_HACK(2);
	  _NS_RETURN_HACK(3); _NS_RETURN_HACK(4); _NS_RETURN_HACK(5);
	  _NS_RETURN_HACK(6); _NS_RETURN_HACK(7); _NS_RETURN_HACK(8);
	  _NS_RETURN_HACK(9); _NS_RETURN_HACK(10); _NS_RETURN_HACK(11);
	  _NS_RETURN_HACK(12); _NS_RETURN_HACK(13); _NS_RETURN_HACK(14);
	  _NS_RETURN_HACK(15); _NS_RETURN_HACK(16); _NS_RETURN_HACK(17);
	  _NS_RETURN_HACK(18); _NS_RETURN_HACK(19); _NS_RETURN_HACK(20);
	  _NS_RETURN_HACK(21); _NS_RETURN_HACK(22); _NS_RETURN_HACK(23);
	  _NS_RETURN_HACK(24); _NS_RETURN_HACK(25); _NS_RETURN_HACK(26);
	  _NS_RETURN_HACK(27); _NS_RETURN_HACK(28); _NS_RETURN_HACK(29);
	  _NS_RETURN_HACK(30); _NS_RETURN_HACK(31); _NS_RETURN_HACK(32);
	  _NS_RETURN_HACK(33); _NS_RETURN_HACK(34); _NS_RETURN_HACK(35);
	  _NS_RETURN_HACK(36); _NS_RETURN_HACK(37); _NS_RETURN_HACK(38);
	  _NS_RETURN_HACK(39); _NS_RETURN_HACK(40); _NS_RETURN_HACK(41);
	  _NS_RETURN_HACK(42); _NS_RETURN_HACK(43); _NS_RETURN_HACK(44);
	  _NS_RETURN_HACK(45); _NS_RETURN_HACK(46); _NS_RETURN_HACK(47);
	  _NS_RETURN_HACK(48); _NS_RETURN_HACK(49); _NS_RETURN_HACK(50);
	  _NS_RETURN_HACK(51); _NS_RETURN_HACK(52); _NS_RETURN_HACK(53);
	  _NS_RETURN_HACK(54); _NS_RETURN_HACK(55); _NS_RETURN_HACK(56);
	  _NS_RETURN_HACK(57); _NS_RETURN_HACK(58); _NS_RETURN_HACK(59);
	  _NS_RETURN_HACK(60); _NS_RETURN_HACK(61); _NS_RETURN_HACK(62);
	  _NS_RETURN_HACK(63); _NS_RETURN_HACK(64); _NS_RETURN_HACK(65);
	  _NS_RETURN_HACK(66); _NS_RETURN_HACK(67); _NS_RETURN_HACK(68);
	  _NS_RETURN_HACK(69); _NS_RETURN_HACK(70); _NS_RETURN_HACK(71);
	  _NS_RETURN_HACK(72); _NS_RETURN_HACK(73); _NS_RETURN_HACK(74);
	  _NS_RETURN_HACK(75); _NS_RETURN_HACK(76); _NS_RETURN_HACK(77);
	  _NS_RETURN_HACK(78); _NS_RETURN_HACK(79); _NS_RETURN_HACK(80);
	  _NS_RETURN_HACK(81); _NS_RETURN_HACK(82); _NS_RETURN_HACK(83);
	  _NS_RETURN_HACK(84); _NS_RETURN_HACK(85); _NS_RETURN_HACK(86);
	  _NS_RETURN_HACK(87); _NS_RETURN_HACK(88); _NS_RETURN_HACK(89);
	  _NS_RETURN_HACK(90); _NS_RETURN_HACK(91); _NS_RETURN_HACK(92);
	  _NS_RETURN_HACK(93); _NS_RETURN_HACK(94); _NS_RETURN_HACK(95);
	  _NS_RETURN_HACK(96); _NS_RETURN_HACK(97); _NS_RETURN_HACK(98);
	  _NS_RETURN_HACK(99);
	  default: env->addr = NULL; break;
	}
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }
  else
    {
      env = jbuf();
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
      env->addr = NULL;
    }

  return env->addr;
}

NSMutableArray *
GSPrivateStackAddresses(void)
{
  NSMutableArray        *stack;
  NSAutoreleasePool	*pool;

#if HAVE_BACKTRACE
  void                  *addresses[1024];
  int                   n = backtrace(addresses, 1024);
  int                   i;

  stack = [NSMutableArray arrayWithCapacity: n];
  pool = [NSAutoreleasePool new];
  for (i = 0; i < n; i++)
    {
      [stack addObject: [NSValue valueWithPointer: addresses[i]]];
    }

#else
  unsigned              n = NSCountFrames();
  unsigned              i;
  jbuf_type             *env;

  stack = [NSMutableArray arrayWithCapacity: n];
  pool = [NSAutoreleasePool new];
  /* There should be more frame addresses than return addresses.
   */
  if (n > 0)
    {
      n--;
    }
  if (n > 0)
    {
      n--;
    }

  env = jbuf();
  if (sigsetjmp(env->buf, 1) == 0)
    {
      env->segv = signal(SIGSEGV, recover);
      env->bus = signal(SIGBUS, recover);

      for (i = 0; i < n; i++)
        {
          switch (i)
            {
              _NS_RETURN_HACK(0); _NS_RETURN_HACK(1); _NS_RETURN_HACK(2);
              _NS_RETURN_HACK(3); _NS_RETURN_HACK(4); _NS_RETURN_HACK(5);
              _NS_RETURN_HACK(6); _NS_RETURN_HACK(7); _NS_RETURN_HACK(8);
              _NS_RETURN_HACK(9); _NS_RETURN_HACK(10); _NS_RETURN_HACK(11);
              _NS_RETURN_HACK(12); _NS_RETURN_HACK(13); _NS_RETURN_HACK(14);
              _NS_RETURN_HACK(15); _NS_RETURN_HACK(16); _NS_RETURN_HACK(17);
              _NS_RETURN_HACK(18); _NS_RETURN_HACK(19); _NS_RETURN_HACK(20);
              _NS_RETURN_HACK(21); _NS_RETURN_HACK(22); _NS_RETURN_HACK(23);
              _NS_RETURN_HACK(24); _NS_RETURN_HACK(25); _NS_RETURN_HACK(26);
              _NS_RETURN_HACK(27); _NS_RETURN_HACK(28); _NS_RETURN_HACK(29);
              _NS_RETURN_HACK(30); _NS_RETURN_HACK(31); _NS_RETURN_HACK(32);
              _NS_RETURN_HACK(33); _NS_RETURN_HACK(34); _NS_RETURN_HACK(35);
              _NS_RETURN_HACK(36); _NS_RETURN_HACK(37); _NS_RETURN_HACK(38);
              _NS_RETURN_HACK(39); _NS_RETURN_HACK(40); _NS_RETURN_HACK(41);
              _NS_RETURN_HACK(42); _NS_RETURN_HACK(43); _NS_RETURN_HACK(44);
              _NS_RETURN_HACK(45); _NS_RETURN_HACK(46); _NS_RETURN_HACK(47);
              _NS_RETURN_HACK(48); _NS_RETURN_HACK(49); _NS_RETURN_HACK(50);
              _NS_RETURN_HACK(51); _NS_RETURN_HACK(52); _NS_RETURN_HACK(53);
              _NS_RETURN_HACK(54); _NS_RETURN_HACK(55); _NS_RETURN_HACK(56);
              _NS_RETURN_HACK(57); _NS_RETURN_HACK(58); _NS_RETURN_HACK(59);
              _NS_RETURN_HACK(60); _NS_RETURN_HACK(61); _NS_RETURN_HACK(62);
              _NS_RETURN_HACK(63); _NS_RETURN_HACK(64); _NS_RETURN_HACK(65);
              _NS_RETURN_HACK(66); _NS_RETURN_HACK(67); _NS_RETURN_HACK(68);
              _NS_RETURN_HACK(69); _NS_RETURN_HACK(70); _NS_RETURN_HACK(71);
              _NS_RETURN_HACK(72); _NS_RETURN_HACK(73); _NS_RETURN_HACK(74);
              _NS_RETURN_HACK(75); _NS_RETURN_HACK(76); _NS_RETURN_HACK(77);
              _NS_RETURN_HACK(78); _NS_RETURN_HACK(79); _NS_RETURN_HACK(80);
              _NS_RETURN_HACK(81); _NS_RETURN_HACK(82); _NS_RETURN_HACK(83);
              _NS_RETURN_HACK(84); _NS_RETURN_HACK(85); _NS_RETURN_HACK(86);
              _NS_RETURN_HACK(87); _NS_RETURN_HACK(88); _NS_RETURN_HACK(89);
              _NS_RETURN_HACK(90); _NS_RETURN_HACK(91); _NS_RETURN_HACK(92);
              _NS_RETURN_HACK(93); _NS_RETURN_HACK(94); _NS_RETURN_HACK(95);
              _NS_RETURN_HACK(96); _NS_RETURN_HACK(97); _NS_RETURN_HACK(98);
              _NS_RETURN_HACK(99);
              default: env->addr = 0; break;
            }
          if (env->addr == 0)
            {
              break;
            }
          [stack addObject: [NSValue valueWithPointer: env->addr]];
        }
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }
  else
    {
      env = jbuf();
      signal(SIGSEGV, env->segv);
      signal(SIGBUS, env->bus);
    }
#endif
  [pool release];
  return stack;
}


const char *_NSPrintForDebugger(id object)
{
  if (object && [object respondsToSelector: @selector(description)])
    return [[object description] cString];

  return NULL;
}

NSString *_NSNewStringFromCString(const char *cstring)
{
  return [NSString stringWithCString: cstring
			    encoding: [NSString defaultCStringEncoding]];
}

