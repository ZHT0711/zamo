# -*- coding: utf-8 -*-
"""librime per-key latency benchmark (Windows / Weasel's rime.dll).

Drives the real engine through the plain exported C functions
(RimeSetup / RimeProcessKey / ...), simulates typing pinyin for a set of
sentences, times every process_key + get_context/get_commit call, and writes
results to JSON for report generation.

Usage:
  python rime_bench.py bench  <user_data_dir> <out.json> [schema_id]
  python rime_bench.py deploy <user_data_dir> <out.json>   # full redeploy timing
"""
import ctypes
import gc
import json
import os
import sys
import time
from ctypes import CFUNCTYPE, POINTER, Structure, byref, c_char_p, c_int, c_size_t, c_void_p

WEASEL_DIR = r"D:\Program Files\Rime\weasel-0.17.4"
SHARED_DATA_DIR = os.path.join(WEASEL_DIR, "data")
Bool = c_int
US = 1_000  # ns -> us

# ---------------------------------------------------------------- structures
# layouts copied from librime 1.17.0 src/rime_api.h
class RimeTraits(Structure):
    _fields_ = [
        ("data_size", c_int),
        ("shared_data_dir", c_char_p),
        ("user_data_dir", c_char_p),
        ("distribution_name", c_char_p),
        ("distribution_code_name", c_char_p),
        ("distribution_version", c_char_p),
        ("app_name", c_char_p),
        ("modules", c_void_p),          # const char**
        ("min_log_level", c_int),
        ("log_dir", c_char_p),
        ("prebuilt_data_dir", c_char_p),
        ("staging_dir", c_char_p),
    ]

class RimeComposition(Structure):
    _fields_ = [("length", c_int), ("cursor_pos", c_int),
                ("sel_start", c_int), ("sel_end", c_int), ("preedit", c_char_p)]

class RimeCandidate(Structure):
    _fields_ = [("text", c_char_p), ("comment", c_char_p), ("reserved", c_void_p)]

class RimeMenu(Structure):
    _fields_ = [("page_size", c_int), ("page_no", c_int), ("is_last_page", Bool),
                ("highlighted_candidate_index", c_int), ("num_candidates", c_int),
                ("candidates", POINTER(RimeCandidate)), ("select_keys", c_char_p)]

class RimeCommit(Structure):
    _fields_ = [("data_size", c_int), ("text", c_char_p)]

class RimeContext(Structure):
    _fields_ = [("data_size", c_int), ("composition", RimeComposition),
                ("menu", RimeMenu), ("commit_text_preview", c_char_p),
                ("select_labels", c_void_p)]   # char**

def init_struct(s):
    # RIME_STRUCT_INIT: data_size = sizeof(Type) - sizeof(data_size)
    s.data_size = ctypes.sizeof(type(s)) - ctypes.sizeof(c_int)
    return s

# ---------------------------------------------------------------- battery
# key sequences are 万象's verified 小鹤双拼 spellings (prism-verified):
#   initial: zh->v ch->i sh->u; finals: ao->c iao->n ing/uai->k ou->z
#            iu->q ei->w uan->r ue->t un->y uo->o ie->p ong->s ai->d
#            en->f eng->g iang/uang->l ang->h ian->m an->j ia/ua->x
#            ui->v in->b; plain a/e/i/o/u/v unchanged
SENTENCES = [
    ("nihcuijp", "你好世界"),                                   # ni hao shi jie
    ("jbtmtmqizfmeyh", "今天天气怎么样"),                        # jin tian tian qi zen me yang
    ("xkngceuivgzdjbxkvs", "性能测试正在进行中"),                # xing neng ce shi zheng zai jin xing zhong
    ("womfyiqiquiuwufjba", "我们一起去吃午饭吧"),                # wo men yi qi qu chi wu fan ba
    ("uurufaybqkfuzefjyihegolvhzxrci", "输入法引擎负责翻译和过滤候选词"),
    ("mktmzcuhbadmzgskidhvtnlyxbxlmu", "明天早上八点在公司开会讨论新项目"),
    ("jmpjdazisuduytkkgszoxnlvjqytgc", "键盘打字速度越快工作效率就越高"),
    ("vegewftixuynzdxiffxicdngvcdcyryb", "这个问题需要仔细分析才能找到原因"),
]
LONG_SENT = ("jbtmxxwusjdmvsqkdcsjlzhvyiuicjjxqrtiyrgsdahv",
             "今天下午三点钟请到三楼会议室参加全体员工大会")

def load_api():
    os.add_dll_directory(WEASEL_DIR)
    dll = ctypes.WinDLL(os.path.join(WEASEL_DIR, "rime.dll"))

    def bind(name, restype, *argtypes):
        f = getattr(dll, name)
        f.restype = restype
        f.argtypes = list(argtypes)
        return f

    api = {
        "setup": bind("RimeSetup", None, POINTER(RimeTraits)),
        "initialize": bind("RimeInitialize", None, POINTER(RimeTraits)),
        "finalize": bind("RimeFinalize", None),
        "start_maintenance": bind("RimeStartMaintenance", Bool, Bool),
        "join_maintenance": bind("RimeJoinMaintenanceThread", None),
        "create_session": bind("RimeCreateSession", c_size_t),
        "destroy_session": bind("RimeDestroySession", Bool, c_size_t),
        "process_key": bind("RimeProcessKey", Bool, c_size_t, c_int, c_int),
        "get_commit": bind("RimeGetCommit", Bool, c_size_t, POINTER(RimeCommit)),
        "free_commit": bind("RimeFreeCommit", Bool, POINTER(RimeCommit)),
        "get_context": bind("RimeGetContext", Bool, c_size_t, POINTER(RimeContext)),
        "free_context": bind("RimeFreeContext", Bool, POINTER(RimeContext)),
        "current_schema": bind("RimeGetCurrentSchema", Bool, c_size_t, c_char_p, c_size_t),
        "select_schema": bind("RimeSelectSchema", Bool, c_size_t, c_char_p),
        "clear": bind("RimeClearComposition", None, c_size_t),
    }
    try:
        api["version"] = bind("RimeGetVersion", None, c_char_p, c_size_t)
    except AttributeError:
        api["version"] = None
    return api

def make_traits(user_dir, log_dir):
    t = init_struct(RimeTraits())
    t.shared_data_dir = SHARED_DATA_DIR.encode()
    t.user_data_dir = user_dir.encode()
    t.distribution_name = b"Weasel benchmark"
    t.distribution_code_name = b"rime-bench"
    t.distribution_version = b"0.1"
    t.app_name = b"rime.zcode-bench"
    t.min_log_level = 1  # WARNING, keep log I/O from skewing timings
    t.log_dir = log_dir.encode()
    return t

def bench(user_dir, out_json, schema_id="wanxiang_pro", rounds=4):
    api = load_api()
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    log_dir = os.path.join(os.path.dirname(out_json), "logs")
    os.makedirs(log_dir, exist_ok=True)

    # stable timings: high process priority, no python gc pauses
    ctypes.windll.kernel32.SetPriorityClass(
        ctypes.windll.kernel32.GetCurrentProcess(), 0x00000080)

    if api["version"]:
        ver_buf = ctypes.create_string_buffer(64)
        api["version"](ver_buf, 64)
        version = ver_buf.value.decode() if ver_buf.value else "?"
    else:
        version = "1.17.0 (from installation.yaml)"

    t = make_traits(user_dir, log_dir)
    gc.disable()
    t0 = time.perf_counter_ns()
    api["setup"](byref(t))
    api["initialize"](byref(t))
    started = api["start_maintenance"](False)   # workspace-change check
    api["join_maintenance"]()
    warm_start_ms = (time.perf_counter_ns() - t0) / 1e6

    sid = api["create_session"]()
    assert sid, "create_session failed"
    buf = ctypes.create_string_buffer(64)
    api["current_schema"](sid, buf, 64)
    cur = buf.value.decode() if buf.value else "?"
    if cur != schema_id:
        assert api["select_schema"](sid, schema_id.encode()), f"select {schema_id} failed"
        time.sleep(0.3)

    f_pk = api["process_key"]
    f_gc = api["get_commit"]
    f_fc = api["free_commit"]
    f_gx = api["get_context"]
    f_fx = api["free_context"]

    def fetch_commit():
        c = init_struct(RimeCommit())
        text = None
        if f_gc(sid, byref(c)):
            text = c.text.decode("utf-8", "replace") if c.text else ""
            f_fc(byref(c))
        return text

    def type_and_commit(keys):
        for kc in keys:
            f_pk(sid, kc, 0)
        f_pk(sid, 0x20, 0)
        text = fetch_commit()
        api["clear"](sid)
        return text

    # warmup: primes dict mmap, opencc, lua, grammar caches
    type_and_commit([ord(c) for c in "nihc"])

    rows, commits = [], []

    def type_sentence(keys, sent_id, expected, round_no):
        typed = ""
        for ch in keys:
            typed += ch
            t0 = time.perf_counter_ns()
            f_pk(sid, ord(ch), 0)
            t1 = time.perf_counter_ns()
            ctx = init_struct(RimeContext())
            n_cand, first, preedit_len = -1, "", len(typed)
            ok = f_gx(sid, byref(ctx))
            t2 = time.perf_counter_ns()
            if ok:
                n_cand = ctx.menu.num_candidates
                preedit_len = ctx.composition.length
                if n_cand > 0 and ctx.menu.candidates:
                    ft = ctx.menu.candidates[0].text
                    first = ft.decode("utf-8", "replace") if ft else ""
                f_fx(byref(ctx))
            rows.append({
                "sent": sent_id, "round": round_no, "key": ch,
                "inlen": len(typed), "process_us": (t1 - t0) / US,
                "context_us": (t2 - t1) / US, "cand": n_cand,
                "first": first, "preedit_len": preedit_len,
            })
        t0 = time.perf_counter_ns()
        f_pk(sid, 0x20, 0)   # space commits the composition
        t1 = time.perf_counter_ns()
        got = fetch_commit()
        t2 = time.perf_counter_ns()
        commits.append({
            "sent": sent_id, "round": round_no, "expected": expected,
            "committed": got, "match": got == expected,
            "space_us": (t1 - t0) / US, "commit_fetch_us": (t2 - t1) / US,
        })
        api["clear"](sid)

    for rnd in range(rounds):
        for i, (keys, expected) in enumerate(SENTENCES):
            type_sentence(keys, f"s{i}", expected, rnd)
        type_sentence(LONG_SENT[0], "long", LONG_SENT[1], rnd)
    gc.enable()

    out = {
        "meta": {
            "user_dir": user_dir, "rime_version": version,
            "warm_start_ms": round(warm_start_ms, 1),
            "maintenance_started": bool(started),
            "default_schema": cur, "schema": schema_id, "rounds": rounds,
        },
        "keys": rows, "commits": commits,
    }
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)

    tot = sorted(a + b for a, b in zip((r["process_us"] for r in rows),
                                       (r["context_us"] for r in rows)))
    def pct(a, p):
        return a[min(len(a) - 1, int(len(a) * p / 100))]
    match = sum(1 for c in commits if c["match"])
    print(f"[bench] rime={version} warm_start={warm_start_ms:.0f}ms keys={len(rows)}")
    print(f"[bench] key total(us): P50={pct(tot,50):.0f} P95={pct(tot,95):.0f} "
          f"P99={pct(tot,99):.0f} max={tot[-1]:.0f}")
    print(f"[bench] sentences={len(commits)} exact-top1={match}/{len(commits)}")
    api["destroy_session"](sid)
    api["finalize"]()

def deploy(user_dir, out_json):
    api = load_api()
    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    log_dir = os.path.join(os.path.dirname(out_json), "logs")
    os.makedirs(log_dir, exist_ok=True)
    t = make_traits(user_dir, log_dir)
    t0 = time.perf_counter_ns()
    api["setup"](byref(t))
    api["initialize"](byref(t))
    api["start_maintenance"](True)   # full check = full redeploy
    api["join_maintenance"]()
    full_deploy_s = (time.perf_counter_ns() - t0) / 1e9
    t0 = time.perf_counter_ns()
    api["start_maintenance"](False)
    api["join_maintenance"]()
    noop_ms = (time.perf_counter_ns() - t0) / 1e6
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump({"user_dir": user_dir,
                   "full_deploy_s": round(full_deploy_s, 2),
                   "noop_deploy_ms": round(noop_ms)}, f)
    print(f"[deploy] full={full_deploy_s:.2f}s noop={noop_ms:.0f}ms")
    api["finalize"]()

if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "bench":
        bench(sys.argv[2], sys.argv[3], *(sys.argv[4:5] or ["wanxiang_pro"]))
    elif mode == "deploy":
        deploy(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(f"unknown mode {mode}")
