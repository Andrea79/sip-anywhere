#!/usr/bin/env python3
"""Summarises `sample` files: CPU time per thread (samples whose top frame is not a
wait), as a share of one core, and where the main thread spends it."""
import collections
import re
import sys

WAIT = ('mach_msg2_trap', '__psynch_cvwait', '__select', 'kevent', '__workq_kernreturn',
        '__ulock_wait', 'semaphore_wait_trap', 'semaphore_timedwait_trap', '__semwait_signal',
        '__recvfrom', 'poll ', '__poll', 'read ', '__sigwait', 'semaphore_wait_signal_trap',
        'start_wqthread', 'kevent_id', '__recvmsg')
FRAME = re.compile(r'^(\s*[ +!:|]*)(\d+) (.*)$')


def analyse(path):
    lines = open(path).read().split('\n')
    start = next(i for i, l in enumerate(lines) if l.startswith('Call graph:'))
    end = next(i for i, l in enumerate(lines) if l.startswith('Total number in stack'))
    footprint = next((l.split(':', 1)[1].strip() for l in lines if l.startswith('Physical footprint:')), '?')
    rows = [(len(m.group(1)), int(m.group(2)), m.group(3)) for l in lines[start + 1:end] if (m := FRAME.match(l))]
    busy, wall = collections.Counter(), 0
    where = collections.defaultdict(collections.Counter)
    thread, stack = None, []
    for i, (depth, count, text) in enumerate(rows):
        if text.startswith('Thread_'):
            name = text.split('  ')[0]
            name = re.sub(r'^Thread_\d+:?\s*', '', name).strip() or 'unnamed'
            thread = name if 'Main Thread' not in text and 'main-thread' not in text else 'main'
            wall = max(wall, count)
            stack = []
            continue
        while stack and stack[-1][0] >= depth:
            stack.pop()
        stack.append((depth, text))
        leaf = i + 1 == len(rows) or rows[i + 1][0] <= depth
        if leaf and not text.startswith(WAIT):
            busy[thread] += count
            ours = [re.sub(r'\s+\(in .*', '', t) for _, t in stack if '(in SIPAnywhere)' in t]
            where[thread][(ours[-1] if ours else re.sub(r'\s+\(in .*', '', text))[:70]] += count
    return wall, busy, where, footprint


for path in sys.argv[1:]:
    wall, busy, where, footprint = analyse(path)
    total = sum(busy.values())
    name = path.rsplit('/', 1)[-1].replace('.sample', '')
    print(f"== {name}: {100 * total / wall:.1f}% CPU ({total} ms in {wall} ms), memory {footprint}")
    for t, ms in busy.most_common(6):
        if ms * 1000 / wall < 2:
            break
        print(f"   {100 * ms / wall:5.1f}%  {t}")
        if t == 'main':
            for f, c in where[t].most_common(4):
                print(f"            {100 * c / wall:5.1f}%  {f}")
