# -*- coding: utf-8 -*-
"""Minimal probe: type 'nihao', dump all candidates + highlight + commit."""
import ctypes, os, sys, time
from ctypes import POINTER, Structure, byref, c_char_p, c_int, c_size_t
from rime_bench import (RimeContext, RimeCommit, RimeTraits, WEASEL_DIR,
                        init_struct, load_api, make_traits)

user_dir, label = sys.argv[1], sys.argv[2]
do_maint = len(sys.argv) < 4 or sys.argv[3] != "nomaint"

api = load_api()
log_dir = r"C:\rime-perf\logs"
os.makedirs(log_dir, exist_ok=True)
t = make_traits(user_dir, log_dir)
api["setup"](byref(t))
api["initialize"](byref(t))
if do_maint:
    api["start_maintenance"](False)
    api["join_maintenance"]()
sid = api["create_session"]()
for kc in [ord(c) for c in "nihao"]:
    api["process_key"](sid, kc, 0)
ctx = init_struct(RimeContext())
if api["get_context"](sid, byref(ctx)):
    print(f'[{label}] preedit={ctx.composition.preedit.decode("utf-8","replace") if ctx.composition.preedit else ""!r} '
          f'hl={ctx.menu.highlighted_candidate_index} n={ctx.menu.num_candidates}')
    for i in range(ctx.menu.num_candidates):
        cd = ctx.menu.candidates[i]
        print(f'  [{i}] {cd.text.decode("utf-8","replace") if cd.text else ""!r}')
    api["free_context"](byref(ctx))
api["process_key"](sid, 0x20, 0)
c = init_struct(RimeCommit())
if api["get_commit"](sid, byref(c)):
    print(f'[{label}] committed={c.text.decode("utf-8","replace") if c.text else ""!r}')
    api["free_commit"](byref(c))
api["destroy_session"](sid)
api["finalize"]()
