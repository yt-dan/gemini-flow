#!/usr/bin/env python3
"""GeminiFlow automated test suite (used by the autonomous improvement loop).

Runs offline and unattended against a candidate binary BEFORE it is installed:
  T1 unit       - built-in `--test` text-polish suite must pass
  T2 analyzer   - clang static analyzer warning count must not exceed baseline
  T3 e2e        - TTS-generated speech (several voices/rates/lengths) through the real
                  on-device pipeline via `--e2e-file`; checks word recall, filler removal,
                  trailing-space paste contract, and release->result latency
  T4 silence    - silent audio must yield <NO SPEECH> cleanly (no crash/hang)
  T5 fallback   - Gemini mode with no network must still return the dictation
                  (the "never lose a dictation" guarantee)
  T13 wav-fallback privacy - the on-device WAV fallback (forced by a test-only hook that ignores streaming on-device
                  results) must still deliver the dictation, and no dictated audio may be left behind: its private temp
                  file is deleted (speech and no-speech runs), nothing new is written to /tmp, and a stale legacy
                  /tmp/geminiflow_last.wav is removed at launch (backlog 8)
  T15 bounded-wait - the REST safety net is slow (test-only hook: a canned HTTP 200 after 5 s, no network): the on-device text
                  must be delivered early, ~3 s after release, and the REST text reported as the final result after it. A fast
                  REST (1 s) must not trigger the early delivery, nor may a no-speech press (user-approved 2026-11-10)
  T16 mic-unavailable - the microphone can't be used (test-only hook --e2e-mic-fail): a start failure (after one automatic
                  engine rebuild) or a denied mic permission must end the press within 1 s as <MIC UNAVAILABLE> with the right notice,
                  without opening Live or calling REST; a mic that starts but sends no audio must end the same way after the watchdog
                  + one rebuild (3.0-4.5 s, never earlier), with no REST call; a mic that fails only once must still deliver the
                  dictation after the rebuild (backlog 7)
  T17 wav-watchdog - the WAV fallback's recognizer never ends (test-only hook --e2e-wav-hang): "final" = it transcribes but
                  never sends its final result, "all" = it never calls back. The dictation must end at the app's watchdog limit
                  (5 s + 0.5 s per audio second; never earlier, at most 1 s later), with the partial text (recall >= the on-device
                  floor) or <NO SPEECH>, and no temp WAV left behind. A normal WAV fallback (T13) must never hit the watchdog (backlog 9)
  T20 hedge-keep - a meaningful "kind of" / "sort of" ("What kind of car...", "I sort of like...") spoken through the real
                  on-device pipeline must survive the polish (rules.json extraFillers used to strip them everywhere; backlog 0i)
  T21 last-sentence - the final "?" / "." is judged on the LAST sentence only (backlog 0j): "What kind of car do you drive? I sort
                  of like the blue one" through the real on-device pipeline must end with ".", and "I fixed the bug. Can you check it"
                  must end with "?". Judged only when the recognizer itself puts a sentence break inside the text (it decides that)
  --online mode (needs network; run ONLY via run_online_tests.sh, which is pre-approved):
  T6 live       - Gemini Live streaming path must succeed WITHOUT falling back; recall, fillers, latency
  T7 rest       - Gemini REST path (default fallback model) must succeed directly; recall, latency
  T8 user       - per Live case, what the user gets by any path: recall >= 0.85 and release->text <= 3 s
  T9 rest503    - test-only injected fast HTTP 503 on the first REST attempt: the retry must still deliver via REST
                  (recall >= 0.85, release->text within the T8 limit, no on-device fallback)
  T9 rest503-slow - the same, but the injected 503 arrives after 6 s (the real 2026-11-06 "high demand" 503 took 5.97 s): the
                  slow-503 retry (backlog 0f) must still deliver via REST; overhead <= delay + 1.5 s, total <= the app's own
                  slow-retry deadline (REST budget for the clip + 4 s)
  T10 nospeech  - Live presses with no speech (0.4 s tap, 1.7 s hold of room noise) must end within the T8 limit,
                  as <NO SPEECH> with nothing pasted and no REST call (backlog 0e, user-approved 2026-11-06)
  T27 live-room-noise (online, backlog 0u, user-reported + user-approved 2026-11-12) - silent presses in an ordinary quiet room
                  (synthesised noise, frame RMS ~80-200 with ~240-RMS clicks, like the real 2026-11-12 16:01 log: max RMS 133-239,
                  1.82 s above the old RMS-60 level): a 0.4 s tap and a 2.3 s hold must end as <NO SPEECH> within the T8 limit,
                  nothing pasted, no REST call (REST invented "00:00 ..." sentences for these)
  T11 live-empty guard - real speech (quiet, short words) while Live is forced to return nothing (test-only hook): the
                  no-speech check must NOT fire; the dictation must still come back via REST with full recall
  T12 second-press - a second press starts while the first dictation is still finishing (test-only hook): during its Live
                  final turn (release), while its REST call is in flight (rest), or before its REST call fails (restfail).
                  BOTH dictations must be delivered: the first via REST on its own recording (or its saved on-device text
                  when REST fails), the second on Live within the T8 limit (backlog 6: never lose the previous dictation)
  T18 live-reconnect - the Live socket is force-closed mid-press (test-only hook --e2e-live-drop-at, like the real 2026-11-10
                  close code 1011 19 s into a hands-free press): the app must reconnect while still recording, resend from the last
                  covered byte and deliver ON LIVE (no REST), recall >= 0.85, no phrase duplicated at the seam, within the T8 limit
  T15 bounded-wait (online) - Live returns nothing (test-only hook) and the real REST call is held 4 s (test-only hook): the
                  on-device text must come early (~3 s after release, recall >= the on-device floor), then the REST text as the
                  final result with full recall, in that order (user-approved 2026-11-10)
  T22 live-release-between-turns - >= 9 s of speech, then 2.2 s of silence before release (backlog 26): the split turn is
                 answered while "Fn" is still held, so the release must finish ON LIVE at once ("released between turns"), not at
                 the old 0.45 s grace timer: recall >= 0.85, no fallback, release->text <= 350 ms (includes the 120 ms cushion)
  T14 live-server-turn-end - the Live server ends the open turn on its own while Fn is still held (test-only hook: a raw
                  activityEnd with no client bookkeeping, its echo hidden), in the pause between two sentences. The speech
                  after it must still be transcribed ON LIVE (no REST fallback), full recall, within the T8 limit (backlog 0c)
  T25 live-rotation - planned Live session rotation (backlog 0p) forced early (test-only hook --e2e-live-rotate-age 10, e2e only;
                  the app rotates at 8.5 min of session age): four ~6 s sentences with 1.8 s pauses (~32 s, deterministic split
                  points); at the first split point (no activity open, no turn pending) after 10 s the app opens a fresh session
                  and continues from there. Must deliver ON LIVE (no REST, no fallback), recall >= 0.95, no phrase duplicated,
                  >= 1 rotation logged, 0 reconnects used, within the T8 limit
  T26 live-lifetime-close - the server's ~10-min session-lifetime close (2026-11-11: close code 1008 at ~590 s) simulated every 8 s
                  of session age (test-only hook --e2e-live-lifetime 8): >= 3 closes, more than the 2 per-press reconnects. Each
                  must be handled as a planned rotation (not counted): ON LIVE, recall >= 0.99 (0.95 until backlog 0r fixed the
                  slow-split seam), no duplicated phrase, 0 reconnects used, within the T8 limit (backlog 0p)
  T23 long-dictation (online, OPT-IN; backlog 0m, user-approved 2026-11-11) - runs ONLY when the flag file
                  .autoimprove/tests/RUN_LONG exists (gitignored; run_online_tests.sh is protected and passes no extra args). It is
                  appended AFTER all the regular online gates, which run unchanged. Two hands-free sessions (~5 and ~10 min, one TTS
                  clip per sentence, 0.6-1.2 s pauses, a 2 s pause every third paragraph) must finish ON LIVE (no REST, no
                  fallback) with recall >= 0.95, no phrase duplicated at a split/reconnect seam and release->text <= 3 s; reconnects,
                  Live session age at release, split activities and the app's peak RSS are reported. Adds ~16 min (+ a few min
                  of one-time TTS). The coordinator runs it at most once a day: touch RUN_LONG, run_online_tests.sh --installed, rm RUN_LONG.
  Offline T23 long-mode selection - the long cases are selected only with the flag (pure check, no TTS, no network).
  T27 rest-plausibility (offline, backlog 0u) - a silent press in an ordinary quiet room (synthesised noise, frame RMS ~80-200 with
                  ~240-RMS clicks, 2.3 s hold) on the REST engine, whose REST answer is a canned 60+ char sentence (test-only hook,
                  no network): on-device hears nothing, so the REST output can't fit the audio and the press must end as <NO SPEECH>
                  (the REST plausibility net logs "rejected"), never paste invented text
  T24 dup-phrase check self-test (offline, backlog 0o) - duplicated_phrases (used by T18/T23) reports a 4-word phrase only when it
                  occurs >= 2 times in the result AND more often than in the expected text: a real seam repeat is caught; recognizer
                  variants, dropped words at a sentence join and phrases repeated in the expected text the same number of times are not.
  --long-dry-run (offline, no network) - builds the two long clips and prints their durations, the case selection with the flag
                  absent/present and the harness timeouts; exit 0 when both clips are within ~5/~10 min.

Usage: run_tests.py --bin /path/to/GeminiFlow [--update-baseline] [--quick] [--online] [--long-dry-run]
Exit 0 = all gates pass, 1 = failure, 5 = inconclusive (machine overloaded; treat as "try later", never as pass). Report JSON is written to .autoimprove/logs/.
"""
import argparse, glob, hashlib, json, os, re, statistics, subprocess, sys, time, wave

# HERE = this file's folder; ROOT = the nearest parent folder that contains main.m. Works from a git worktree
# (e.g. ~/GeminiFlow-build, .autoimprove/tests/) and from the shared repo layout (tests/).
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
while not os.path.exists(os.path.join(ROOT, "main.m")) and os.path.dirname(ROOT) != ROOT:
    ROOT = os.path.dirname(ROOT)
CACHE = os.path.join(HERE, "audio_cache")
BASELINE = os.path.join(HERE, "baseline.json")
LOGS = os.path.join(ROOT, ".autoimprove", "logs") if os.path.isdir(os.path.join(ROOT, ".autoimprove")) else os.path.join(HERE, "logs")

FILLERS = ["um", "uh", "you know", "i mean"]

# (id, voice or None, rate or None, spoken text, expected polished text)
CORPUS = [
    ("fillers", None, None,
     "Um, so like I was thinking we should ship the new build on Friday, you know, after the review.",
     "So I was thinking we should ship the new build on Friday after the review."),
    ("short", None, None, "Hello.", "Hello."),
    ("question", None, None,
     "Can you send me the link to the design doc before the meeting?",
     "Can you send me the link to the design doc before the meeting?"),
    ("keep_like", None, None,
     "I like the new design and I would like to schedule a call with the team tomorrow.",
     "I like the new design and I would like to schedule a call with the team tomorrow."),
    ("long", None, None,
     "The quarterly planning session went well. We agreed to focus on reliability first, then on speed. "
     "The design team will share new mockups next week, and engineering will review the backlog on Monday. "
     "Please make sure every open bug has an owner before the end of the sprint, and flag anything that is blocked.",
     "The quarterly planning session went well. We agreed to focus on reliability first, then on speed. "
     "The design team will share new mockups next week, and engineering will review the backlog on Monday. "
     "Please make sure every open bug has an owner before the end of the sprint, and flag anything that is blocked."),
    ("uk_voice", "Daniel", None,
     "Uh, the latency is much better now, and the app feels really responsive.",
     "The latency is much better now, and the app feels really responsive."),
    ("fast_rate", "Eddy (English (US))", 230,
     "Please remind me to call Sarah this afternoon about the contract.",
     "Please remind me to call Sarah this afternoon about the contract."),
    ("uk_female", "Flo (English (UK))", None,
     "We need to fix the bug where the microphone stops working after the laptop wakes from sleep.",
     "We need to fix the bug where the microphone stops working after the laptop wakes from sleep."),
]
QUICK_IDS = {"fillers", "short", "uk_voice"}

MIN_CASE_RECALL = 0.80
MAX_RECALL_DROP = 0.05
OFFLINE_RECALL_FLOOR = 0.60
LATENCY_FLOOR_MS = 1500


def words(s):
    return [w for w in re.split(r"[^a-z0-9']+", s.lower()) if w]


def recall(expected, actual):
    pool = words(actual)
    exp = words(expected)
    hit = 0
    for w in exp:
        if w in pool:
            hit += 1
            pool.remove(w)
    return hit / len(exp) if exp else 1.0


def wav_complete(path):
    """True if `path` is a complete RIFF/WAVE file: the RIFF size matches the file size and a data chunk (after fmt) ends inside
    the file. A `say` that is killed mid-write leaves its placeholder header (RIFF size 4088, data size 0) on a long file, which a
    later run would silently reuse (backlog 0l, seen 2026-11-11 13:19). Cheap: reads only the chunk headers."""
    import struct
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(12)
            if len(head) < 12 or head[:4] != b"RIFF" or head[8:12] != b"WAVE":
                return False
            if struct.unpack("<I", head[4:8])[0] + 8 != size:
                return False
            off, have_fmt = 12, False
            while off + 8 <= size:
                f.seek(off)
                cid, clen = struct.unpack("<4sI", f.read(8))
                if cid == b"fmt ":
                    have_fmt = True
                elif cid == b"data":
                    return have_fmt and clen > 0 and off + 8 + clen <= size
                off += 8 + clen + (clen & 1)
    except (OSError, struct.error):
        return False
    return False


def _cached_wav(path):
    """True if a usable cached WAV exists at `path`; an incomplete one is deleted so the caller regenerates it."""
    if not os.path.exists(path):
        return False
    if wav_complete(path):
        return True
    print(f"  (audio cache: {os.path.basename(path)} is incomplete; regenerating it)", flush=True)
    try:
        os.remove(path)
    except OSError:
        pass
    return False


def _tmp_beside(path):
    """Temp file next to `path` (same directory, so os.replace is atomic). Keeps the .wav suffix: `say` picks the file type from it."""
    return f"{path[:-4]}.partial-{os.getpid()}.wav"


def tts(case_id, voice, rate, text):
    os.makedirs(CACHE, exist_ok=True)
    key = hashlib.sha1(f"{voice}|{rate}|{text}".encode()).hexdigest()[:12]
    path = os.path.join(CACHE, f"{case_id}-{key}.wav")
    if not _cached_wav(path):
        # `say` writes to a temp file that is renamed into the cache only when complete (a hung/killed `say` used to leave a
        # truncated WAV in the cache for later runs). One retry with a longer timeout; the temp file is always removed.
        args = ["--data-format=LEI16@16000"] + (["-v", voice] if voice else []) + (["-r", str(rate)] if rate else [])
        last_err = None
        for limit in (60, 180):
            tmp = _tmp_beside(path)
            try:
                subprocess.run(["/usr/bin/say", "-o", tmp] + args + [text], check=True, timeout=limit)
                if not wav_complete(tmp):
                    raise RuntimeError(f"say wrote an incomplete WAV for {case_id}")
                os.replace(tmp, path)
                last_err = None
                break
            except (subprocess.TimeoutExpired, subprocess.CalledProcessError, RuntimeError) as e:
                last_err = e
                print(f"  (TTS for {case_id} failed: {type(e).__name__}; " + ("retrying with a longer timeout)" if limit == 60 else "giving up)"),
                      flush=True)
            finally:
                if os.path.exists(tmp):
                    try:
                        os.remove(tmp)
                    except OSError:
                        pass
        if last_err is not None:
            raise last_err
    return path


def silence_wav():
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, "silence-2s.wav")
    if not _cached_wav(path):
        import array
        _write_pcm(path, array.array("h", [0] * 32000))
    return path


def _run_with_rusage(cmd, timeout):
    """Like subprocess.run(capture_output=True, text=True, timeout=...) but also returns the child's peak RSS (ru_maxrss from wait4;
    bytes on macOS). On timeout the child is killed and code is "timeout". Output = stdout + stderr, as in run_e2e."""
    import threading
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
    bufs = {"out": [], "err": []}

    def pump(stream, key):
        for chunk in iter(lambda: stream.read(65536), ""):
            bufs[key].append(chunk)
    threads = [threading.Thread(target=pump, args=(p.stdout, "out"), daemon=True),
               threading.Thread(target=pump, args=(p.stderr, "err"), daemon=True)]
    for t in threads:
        t.start()
    deadline = time.time() + timeout
    while True:
        pid, status, ru = os.wait4(p.pid, os.WNOHANG)
        if pid == p.pid:
            code = os.waitstatus_to_exitcode(status)
            break
        if time.time() > deadline:
            p.kill()
            _, status, ru = os.wait4(p.pid, 0)
            code = "timeout"
            break
        time.sleep(0.25)
    p.returncode = code if isinstance(code, int) else -9  # reaped here; keep Popen from waiting on it again
    for t in threads:
        t.join(10)
    for f in (p.stdout, p.stderr):
        try:
            f.close()
        except Exception:
            pass
    return "".join(bufs["out"]) + "".join(bufs["err"]), code, ru.ru_maxrss


def run_e2e(binary, wav, model=None, timeout=90, extra=None, rusage=False):
    cmd = [binary, "--e2e-file", wav] + ([model] if model else []) + (list(extra) if extra else [])
    t0 = time.time()
    peak_rss = None
    if rusage:  # long-dictation mode only (backlog 0m): the regular cases keep the plain subprocess.run path below
        out, code, peak_rss = _run_with_rusage(cmd, timeout)
    else:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            out, code = p.stdout + p.stderr, p.returncode
        except subprocess.TimeoutExpired as e:
            out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            code = "timeout"
    stats = re.findall(r"Press stats: ([\d.]+) s of audio; Live session age at release (n/a|[\d.]+ s); reconnects (\d+); "
                       r"Live activities (\d+)", out)
    m = re.search(r'E2E RESULT: "(.*)"', out, re.S)
    lat = re.search(r"release->result latency: (\d+) ms", out)
    early = re.search(r'E2E EARLY DELIVERY: "(.*?)"\nE2E early delivery latency: (\d+) ms', out, re.S)
    return {
        "early": early.group(1) if early else None,
        "early_latency_ms": int(early.group(2)) if early else None,
        "early_first": bool(early) and bool(m) and early.start() < m.start(),
        "early_not_used": "Early paste: not used" in out,
        "exit": code,
        "result": m.group(1) if m else None,
        "latency_ms": int(lat.group(1)) if lat else None,
        "wall_s": round(time.time() - t0, 1),
        "fell_back": bool(re.search(r"Live: failed|falling back|Falling back|Gemini \S+ failed", out)),
        "live_ok": bool(re.search(r"Live: done in", out)),
        "rest_ok": bool(re.search(r"Gemini \S+ ok in", out)),
        "retried_call_s": _retried_call_seconds(out),
        "injected_503": "E2E: injecting HTTP 503" in out,
        "rest_retried": bool(re.search(r"Gemini: transient HTTP \d+ after [\d.]+s; retrying", out)),
        "ondevice_fallback": "Falling back to on-device" in out,
        "rest_called": bool(re.search(r"falling back to REST|using REST\.|Gemini \S+ (ok in|failed after)|Gemini: transient HTTP", out)),
        "nospeech_check": "No-speech check:" in out,
        "nospeech_skip": bool(re.search(r"Live: no speech in [\d.]+s after release", out)),
        "rest_net_rejected": bool(re.search(r"REST plausibility \(dictation #\d+\): .*-> rejected", out)),
        "fired": "E2E: simulating a server-initiated turn end" in out,
        "reopened": bool(re.search(r"Live: activityStart #2 at", out)),
        "dropped": "E2E: force-closing the Live socket" in out,
        "reconnected": bool(re.search(r"Live: reconnected \(#\d+\)", out)),
        "between_turns": bool(re.search(r"Live: done in [\d.]+s after release \(released between turns", out)),
        "mic_unavailable_ms": (lambda m: int(m.group(1)) if m else None)(re.search(r"E2E MIC UNAVAILABLE after (\d+) ms", out)),
        "mic_notice": (lambda m: m.group(1) if m else None)(re.search(r'E2E MIC UNAVAILABLE after \d+ ms \(.*?, notice "(.*?)"\)', out)),
        "mic_rebuilt": "rebuilding the audio engine once" in out,
        "mic_restarted": "Mic: started after the rebuild" in out,
        "live_connect": "Live: connecting" in out,
        "wav_watchdog": (lambda m: (float(m.group(1)), float(m.group(2)), float(m.group(3)), int(m.group(4)))
                         if m else None)(re.search(r"WAV fallback: no final result after ([\d.]+)s \(limit ([\d.]+)s for ([\d.]+)s audio, "
                                                   r"\d+ partial results\); ending with (\d+) chars", out)),
        "wav_paths": re.findall(r"WAV fallback: recognizing [\d.]+s of audio from a private temp file: (\S+\.wav)", out),
        # backlog 0m: numbers-only per-press stats line (last press), split activities and reconnects, peak RSS (rusage runs only)
        "press_audio_s": float(stats[-1][0]) if stats else None,
        "live_session_age_s": (float(stats[-1][1][:-2]) if stats[-1][1] != "n/a" else None) if stats else None,
        "live_activities": int(stats[-1][3]) if stats else None,
        "split_count": len(re.findall(r"Live: split activity #\d+", out)),
        "reconnect_count": len(re.findall(r"Live: reconnected \(#\d+\)", out)),
        # backlog 0p: planned session rotations (never counted against the reconnect budget)
        "press_reconnects": int(stats[-1][2]) if stats else None,
        "press_rotations": (lambda m: int(m[-1]) if m else 0)(re.findall(r"Press stats: .*?; planned rotations (\d+)", out)),
        "rotation_count": len(re.findall(r"Live: planned session rotation #\d+", out)),
        "planned_close_count": len(re.findall(r"Live: session closed at session age [\d.]+s while recording .*?; planned rotation #\d+", out)),
        "rotated_ready_count": len(re.findall(r"Live: rotated session ready \(rotation #\d+", out)),
        "lifetime_closes": len(re.findall(r"E2E: simulating the Live session-lifetime close #\d+", out)),
        "reconnect_scheduled": len(re.findall(r"Live: connection lost at [\d.]+s sent while recording", out)),
        "peak_rss_mb": round(peak_rss / 1048576.0, 1) if peak_rss else None,
        "tail": "\n".join(out.strip().splitlines()[-8:]),
    }


def run_e2e_two(binary, wav_a, wav_b, phase, model, timeout=150, extra=None):
    """Two presses (--e2e-second-press): press #2 starts while press #1 is still finishing. Per-press results and latencies."""
    cmd = [binary, "--e2e-file", wav_a, model, "--e2e-second-press", wav_b, phase] + (list(extra) if extra else [])
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        out, code = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        code = "timeout"
    res = {int(m.group(1)): m.group(2) for m in re.finditer(r'^E2E RESULT #(\d+): "(.*)"$', out, re.M)}
    lat = {int(m.group(1)): (int(m.group(2)), m.group(3) == "1")
           for m in re.finditer(r"^E2E #(\d+) release->result latency: (\d+) ms \(superseded=(\d)\)", out, re.M)}
    return {
        "exit": code, "results": res, "latencies": lat, "wall_s": round(time.time() - t0, 1),
        "both": "E2E BOTH DELIVERED" in out,
        "second_started": "E2E second press starts" in out,
        "live_ok": bool(re.search(r"Live: done in", out)),
        "rest_ok": bool(re.search(r"Gemini \S+ ok in", out)),
        "ondevice_fallback": "Falling back to on-device" in out,
        "snapshot_ondevice": "on-device fallback from its snapshot" in out,
        "tail": "\n".join(out.strip().splitlines()[-12:]),
    }


def _retried_call_seconds(out):
    """Server time of the RETRIED REST call: log timestamp of the success line minus the 'retrying ... in 0.5s' line, minus the
    0.5 s backoff. None if either line is missing."""
    ts = lambda line: (lambda m: (int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))) if m else None)(
        re.search(r"\d{4}-\d\d-\d\d (\d\d):(\d\d):(\d\d\.\d+)", line))
    t_retry = t_ok = None
    for line in out.splitlines():
        if "retrying" in line and "transient HTTP" in line:
            t_retry = ts(line)
        elif re.search(r"Gemini \S+ ok in", line):
            t_ok = ts(line)
    if t_retry is None or t_ok is None:
        return None
    return max(0.0, t_ok - t_retry - 0.5)


def analyzer_count():
    srcs = [os.path.join(ROOT, "main.m")] + sorted(glob.glob(os.path.join(ROOT, "src", "*.m")))
    n = 0
    for s in srcs:
        p = subprocess.run(["/usr/bin/clang", "--analyze", "-fobjc-arc", s, "-o", "/dev/null"],
                           capture_output=True, text=True, timeout=600)
        n += len(re.findall(r"warning:", p.stderr))
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--update-baseline", action="store_true",
                    help="ratchet baseline to current results where they improved (or initialise it)")
    ap.add_argument("--quick", action="store_true", help="subset of e2e cases, no analyzer")
    ap.add_argument("--online", action="store_true", help="run ONLY the online Gemini tests (T6/T7)")
    ap.add_argument("--long-dry-run", action="store_true",
                    help="offline: build the long-dictation clips and print the long-mode case selection (no network)")
    a = ap.parse_args()
    if a.long_dry_run:
        return long_dry_run()
    # Keep the Mac from idle/maintenance-sleeping mid-run (2026-11-06 14:26: the Mac slept 16 min during a T9 retry, which read as a
    # 960 s "hang"). caffeinate exits with this process; failure to start it is harmless.
    try:
        subprocess.Popen(["/usr/bin/caffeinate", "-i", "-w", str(os.getpid())],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    if "/Contents/MacOS/" not in os.path.realpath(a.bin):
        print("ERROR: --bin must be inside a .app bundle (use .autoimprove/build_candidate.sh). "
              "A bare binary can't read the app's preferences/API key and silently tests on-device only.")
        return 2
    if not wait_for_sane_load():
        return 5
    if a.online:
        return online_main(a)

    base = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    report = {"bin": a.bin, "time": time.strftime("%Y-%m-%d %H:%M:%S"), "tests": [], "gates": []}
    fails = []

    def gate(name, ok, detail):
        report["gates"].append({"gate": name, "ok": bool(ok), "detail": detail})
        print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}")
        if not ok:
            fails.append(name)

    # T1 unit
    p = subprocess.run([a.bin, "--test"], capture_output=True, text=True, timeout=60)
    summ = re.search(r"Summary: (\d+) passed, (\d+) failed", p.stdout)
    gate("T1 unit (--test)", p.returncode == 0, summ.group(0) if summ else p.stdout[-300:])

    # T19 API key never in a URL (backlog 15): every Gemini request the binary builds (REST generateContent, the pre-warm HEAD,
    # the API-key check, the Live upgrade with header auth) carries the key in the x-goog-api-key header and has no key= in its
    # URL (checked with a dummy key via --dump-gemini-requests), and the binary holds no key-in-URL format string
    # (grep of its bytes; the Live key-in-URL auth fallback builds its query item with NSURLComponents, not a format string).
    p = subprocess.run([a.bin, "--dump-gemini-requests"], capture_output=True, text=True, timeout=30)
    dk = re.search(r"DUMMY KEY: (\S+)", p.stdout)
    reqs = re.findall(r"REQUEST (\S+) url=(\S+) header=(\S+)", p.stdout)
    bad = [n for n, u, h in reqs if h != "set" or re.search(r"key(=|%3D)", u, re.I) or (dk and dk.group(1) in u)]
    blob = open(a.bin, "rb").read()
    lits = [l.decode() for l in (b"key=%@", b"generateContent?key", b"pageSize=1&key", b"BidiGenerateContent?key") if l in blob]
    names = sorted(n for n, _, _ in reqs)
    want = sorted(["rest-generateContent", "rest-prewarm", "api-key-check", "live-header-auth"])
    gate("T19 api-key-not-in-urls", p.returncode == 0 and dk is not None and names == want and not bad and not lits,
         f"requests={names} bad={bad} key-in-URL literals in binary={lits}")

    # T23 long-mode selection (backlog 0m): the 5/10 min online cases are added ONLY while RUN_LONG exists (and RUN_LONG is
    # gitignored); without it the online case list is unchanged. Pure check: no TTS, no network.
    try:
        ignored = os.path.relpath(os.path.join(HERE, "RUN_LONG"), ROOT) in open(os.path.join(ROOT, ".gitignore")).read().split()
    except OSError:
        ignored = False
    off, on = online_long_ids(False), online_long_ids(True)
    t_ok = all(long_e2e_timeout_s(s) >= s + 8 + 0.25 * s + 4 + 5 + 0.5 * s + 60 for s in (300.0, 600.0))
    gate("T23 long-mode selection", off == [] and on == ["handsfree_5min", "handsfree_10min"] and ignored and t_ok,
         f"without flag={off} with flag={on} RUN_LONG gitignored={ignored} timeouts ok={t_ok} (flag present now: {long_mode_enabled()})")

    # T24 duplicate-phrase check self-test (backlog 0o): the T18/T23 "no phrase duplicated at a seam" check must catch a real seam
    # repeat (also one more repeat of a phrase the expected text already repeats) and must NOT report recognizer variants, dropped words at a
    # sentence join, or a phrase repeated in the expected text the same number of times. Pure Python: no TTS, no network.
    dup_bad = dup_check_selftest()
    gate("T24 dup-phrase check self-test", not dup_bad,
         f"{len(DUP_SELFTEST_CASES) - len(dup_bad)}/{len(DUP_SELFTEST_CASES)} cases ok" + (f"; failed: {dup_bad}" if dup_bad else ""))

    report["loadavg_start"] = os.getloadavg()[0]
    if report["loadavg_start"] > 2 * os.cpu_count():
        print(f"WARNING: high load average {report['loadavg_start']:.0f}; e2e recall/latency may be degraded")

    # T3 e2e on-device corpus
    recalls, lats = [], []
    for cid, voice, rate, text, expected in CORPUS:
        if a.quick and cid not in QUICK_IDS:
            continue
        r = run_e2e(a.bin, tts(cid, voice, rate, text))
        res = r["result"] or ""
        rc = recall(expected, res)
        lower = " " + " ".join(words(res)) + " "
        leaked = [f for f in FILLERS if f" {f} " in lower]
        if rc < MIN_CASE_RECALL and r["exit"] == 0:  # retry once: recognizer is noisy under CPU load
            r2 = run_e2e(a.bin, tts(cid, voice, rate, text))
            rc2 = recall(expected, r2["result"] or "")
            if rc2 > rc:
                r, res, rc = r2, (r2["result"] or ""), rc2
                lower = " " + " ".join(words(res)) + " "
                leaked = [f for f in FILLERS if f" {f} " in lower]
        ok = (r["exit"] == 0 and r["result"] is not None and not leaked and res.endswith(" "))
        if rc < MIN_CASE_RECALL:
            report.setdefault("quality_warnings", []).append(f"{cid}: recall {rc:.2f} < {MIN_CASE_RECALL}")
        r.update({"id": cid, "recall": round(rc, 3), "leaked_fillers": leaked, "expected": expected})
        report["tests"].append(r)
        if r["latency_ms"] is not None:
            lats.append(r["latency_ms"])
        recalls.append(rc)
        gate(f"T3 e2e/{cid}", ok,
             ("" if rc >= MIN_CASE_RECALL else "[LOW RECALL] ") + f"recall={rc:.2f} lat={r['latency_ms']}ms exit={r['exit']} leaked={leaked} -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    mean_recall = statistics.mean(recalls) if recalls else 0
    med_lat = statistics.median(lats) if lats else None
    report.update({"mean_recall": round(mean_recall, 4), "median_latency_ms": med_lat})
    if not a.quick:
        # On-device is a fallback-only engine and its recall swings ~0.2 with CPU load, so it is gated on a
        # fixed floor rather than a ratcheting baseline (Live quality is ratcheted in the online suite).
        gate("T3 on-device mean recall floor", mean_recall >= OFFLINE_RECALL_FLOOR,
             f"{mean_recall:.3f} (floor {OFFLINE_RECALL_FLOOR}; best seen {base.get('mean_recall', 0):.3f})")
        bl = base.get("median_latency_ms", med_lat)
        if med_lat is not None and bl is not None:
            limit = max(LATENCY_FLOOR_MS, 2 * bl)
            gate("T3 median latency", med_lat <= limit, f"{med_lat}ms (baseline {bl}ms, limit {limit}ms)")

    # T20 meaningful "kind of" / "sort of" are kept (backlog 0i): before, the blind extraFillers regex turned this into
    # "What car do you drive? I like the blue one." The phrases are checked word-for-word; recognizer noise gets one retry.
    hedge_text = "What kind of car do you drive? I sort of like the blue one."
    hedge_want = ["what kind of car", "sort of like"]
    for _ in range(2):
        r = run_e2e(a.bin, tts("hedge_keep", None, None, hedge_text))
        res = r["result"] or ""
        joined = " " + " ".join(words(res)) + " "
        missing = [p for p in hedge_want if f" {p} " not in joined]
        if r["exit"] == 0 and not missing:
            break
    gate("T20 hedge-keep", r["exit"] == 0 and not missing and res.endswith(" "),
         f"missing={missing} exit={r['exit']} -> {res!r}" + ("" if not missing else f"\n      tail: {r['tail']}"))

    # T21 the terminal punctuation is judged on the last sentence only (backlog 0j): before, the first word of the whole text
    # decided it, so T20's text came back as "... I sort of like the blue one? ". Judged only when the recognizer itself
    # put a sentence break inside the text (otherwise it's one sentence and the old rule applies); one retry for recognizer noise.
    t21_bad, t21_seen = [], []
    for cid, text, want in (("hedge_keep", hedge_text, "."), ("last_sentence_q", "I fixed the bug. Can you check it?", "?")):
        for _ in range(2):
            r = run_e2e(a.bin, tts(cid, None, None, text))
            res = (r["result"] or "")
            body = res.strip()
            judged = r["exit"] == 0 and re.search(r"[.!?]\s+\S", body[:-1]) is not None
            ok = r["exit"] == 0 and res.endswith(" ") and (not judged or body.endswith(want))
            if ok:
                break
        t21_seen.append(f"{cid}: {res!r}" + ("" if judged else " (no sentence break recognized; not judged)"))
        if not ok:
            t21_bad.append(f"{cid} want {want!r} exit={r['exit']}")
    gate("T21 last-sentence", not t21_bad, f"bad={t21_bad} " + "; ".join(t21_seen))

    # T4 silence
    r = run_e2e(a.bin, silence_wav(), timeout=60)
    gate("T4 silence", r["exit"] == 0 and (r["result"] or "").strip() in ("<NO SPEECH>", ""),
         f"exit={r['exit']} result={r['result']!r}")

    # T13 WAV fallback privacy (backlog 8): dictated audio never stays on disk; the fallback still delivers
    legacy = "/tmp/geminiflow_last.wav"
    t13_watchdog = []
    for cid, wav_path, want_speech in (("speech", tts(*CORPUS[0][:4]), True), ("nospeech", silence_wav(), False)):
        try:  # a stale world-readable file left by older builds must be swept at launch
            with open(legacy, "wb") as f:
                f.write(b"RIFF-stale-test")
            os.utime(legacy, (time.time() - 3600, time.time() - 3600))
        except OSError:
            pass
        t0 = time.time()
        r = run_e2e(a.bin, wav_path, timeout=90, extra=["--e2e-wav-fallback"])
        if want_speech and r["exit"] == 0 and recall(CORPUS[0][4], r["result"] or "") < MIN_CASE_RECALL:
            r = run_e2e(a.bin, wav_path, timeout=90, extra=["--e2e-wav-fallback"])  # retry once (load-sensitive)
        paths = r["wav_paths"]
        t13_watchdog.append((cid, r["wav_watchdog"]))
        tmp_dirs = {os.path.dirname(p) for p in paths}
        left = [p for p in paths if os.path.exists(p)]
        new_in_tmp = [p for d in tmp_dirs | {"/tmp"} for p in glob.glob(os.path.join(d, "geminiflow*.wav"))
                      if os.path.exists(p) and os.path.getmtime(p) >= t0 - 1]
        private_dir = bool(paths) and all(not os.path.realpath(d).startswith(("/tmp", "/private/tmp")) for d in tmp_dirs)
        res = r["result"] or ""
        if want_speech:
            rc = recall(CORPUS[0][4], res)
            delivered, detail = rc >= MIN_CASE_RECALL, f"recall={rc:.2f}"
        else:
            delivered, detail = res.strip() == "<NO SPEECH>", "no speech"
        ok = (r["exit"] == 0 and len(paths) == 1 and private_dir and not left and not new_in_tmp
              and not os.path.exists(legacy) and delivered)
        gate(f"T13 wav-fallback-privacy/{cid}", ok,
             f"{detail} exit={r['exit']} temp_files={len(paths)} private_dir={private_dir} left={left} new_in_tmp={new_in_tmp} "
             f"legacy_removed={not os.path.exists(legacy)} -> {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T17 WAV fallback watchdog (backlog 9): a WAV recognizer that never ends no longer leaves the dictation in "Thinking".
    hit = [c for c, w in t13_watchdog if w]
    gate("T17 wav-watchdog/normal-not-fired", len(t13_watchdog) == 2 and not hit, f"watchdog fired in T13 runs: {hit}")
    cid, voice, rate, text, expected = CORPUS[0]
    wav = tts(cid, voice, rate, text)
    audio_s = wav_seconds(wav)
    for kind in ("final", "all"):
        t0 = time.time()
        for _ in range(2):  # retry once: the on-device recall is load-sensitive
            r = run_e2e(a.bin, wav, timeout=60, extra=["--e2e-wav-hang", kind])
            res = r["result"] or ""
            rc = recall(expected, res)
            if kind == "all" or rc >= MIN_CASE_RECALL:
                break
        w = r["wav_watchdog"]
        paths = r["wav_paths"]
        left = [p for p in paths if os.path.exists(p)]
        new_tmp = [p for d in {os.path.dirname(p) for p in paths} for p in glob.glob(os.path.join(d, "geminiflow-*.wav"))
                   if os.path.exists(p) and os.path.getmtime(p) >= t0 - 1]
        limit = 5.0 + 0.5 * (w[2] if w else audio_s)
        timing_ok = bool(w) and abs(w[1] - limit) < 0.06 and limit - 0.05 <= w[0] <= limit + 1.0
        if kind == "final":
            delivered = rc >= MIN_CASE_RECALL and res.endswith(" ") and w is not None and w[3] > 0
            detail = f"recall={rc:.2f}"
        else:
            delivered = res == "<NO SPEECH>" and w is not None and w[3] == 0
            detail = "no speech"
        lat_ok = r["latency_ms"] is not None and r["latency_ms"] <= (limit + 3.0) * 1000
        ok = r["exit"] == 0 and timing_ok and delivered and lat_ok and len(paths) == 1 and not left and not new_tmp
        gate(f"T17 wav-watchdog/{kind}", ok,
             f"{detail} watchdog={w} (want limit {limit:.2f}s, fired within +1 s) lat={r['latency_ms']}ms temp_files={len(paths)} "
             f"left={left} new_tmp={new_tmp} -> {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T5 offline fallback through the Gemini path
    if not a.quick:
        cid, voice, rate, text, expected = CORPUS[0]
        r = run_e2e(a.bin, tts(cid, voice, rate, text), model="gemini-3.5-transcribe-live", timeout=120)
        rc = recall(expected, r["result"] or "")
        gate("T5 gemini->fallback never loses dictation",
             r["exit"] == 0 and rc >= MIN_CASE_RECALL,
             f"recall={rc:.2f} lat={r['latency_ms']}ms exit={r['exit']} -> {r['result']!r}")
        report["fallback_latency_ms"] = r["latency_ms"]

    # T15 bounded wait (user-approved 2026-11-10): a slow REST answer (test-only canned HTTP 200, no network) must not hold the
    # dictation: the on-device text comes ~3 s after release, then the REST text as the final result. A fast REST, or a press
    # with no speech, must not get an early delivery.
    BW_EARLY_MIN_MS, BW_EARLY_MAX_MS = 2700, 3700
    cid, voice, rate, text, expected = CORPUS[0]
    wav = tts(cid, voice, rate, text)
    for _ in range(2):  # retry once: the on-device recall is load-sensitive
        r = run_e2e(a.bin, wav, model="gemini-3.5-flash-lite", timeout=60, extra=["--e2e-rest-fake-ok", "5"])
        erc = recall(expected, r["early"] or "")
        if erc >= MIN_CASE_RECALL:
            break
    res = r["result"] or ""
    el = r["early_latency_ms"]
    ok = (r["exit"] == 0 and el is not None and BW_EARLY_MIN_MS <= el <= BW_EARLY_MAX_MS and erc >= MIN_CASE_RECALL
          and r["early_first"] and "canned gemini transcript" in res.lower() and res.endswith(" ")
          and (r["latency_ms"] or 0) >= 4500)
    gate("T15 bounded-wait/slow-rest", ok,
         f"early at {el}ms (want {BW_EARLY_MIN_MS}-{BW_EARLY_MAX_MS}) recall={erc:.2f} early_first={r['early_first']} "
         f"final lat={r['latency_ms']}ms -> early {r['early']!r} / final {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))
    r = run_e2e(a.bin, wav, model="gemini-3.5-flash-lite", timeout=60, extra=["--e2e-rest-fake-ok", "1"])
    res = r["result"] or ""
    ok = r["exit"] == 0 and r["early"] is None and "canned gemini transcript" in res.lower()
    gate("T15 bounded-wait/fast-rest", ok, f"early={r['early']!r} final lat={r['latency_ms']}ms -> {res!r}"
         + ("" if ok else f"\n      tail: {r['tail']}"))
    r = run_e2e(a.bin, silence_wav(), model="gemini-3.5-flash-lite", timeout=60, extra=["--e2e-rest-fake-ok", "5"])
    ok = r["exit"] == 0 and r["early"] is None and r["early_not_used"]
    gate("T15 bounded-wait/no-speech", ok, f"early={r['early']!r} not_used_logged={r['early_not_used']} -> {r['result']!r}"
         + ("" if ok else f"\n      tail: {r['tail']}"))

    # T27 REST plausibility (backlog 0u): a silent quiet-room press on the REST engine, REST answering a canned sentence or echoing the
    # REST prompt (test-only, no network). Must be rejected -> <NO SPEECH>.
    for sub, extra in (("room-noise", ["--e2e-rest-fake-ok", "1"]),
                       ("prompt-echo", ["--e2e-rest-fake-ok", "1", "--e2e-rest-fake-text", "Transcribe and clean up this audio dictation."])):
        r = run_e2e(a.bin, room_noise_wav("room_hold", 2.30), model="gemini-3.5-flash-lite", timeout=60, extra=extra)
        res = (r["result"] or "")
        ok = r["exit"] == 0 and res.strip() == "<NO SPEECH>" and r["rest_net_rejected"] and r["early"] is None
        gate(f"T27 rest-plausibility/{sub}", ok, f"net_rejected={r['rest_net_rejected']} early={r['early']!r} -> {res[:60]!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T16 mic unavailable (backlog 7): a press whose microphone can't be used ends at once with a clear marker/notice; it never
    # opens Live (start failure / denied permission are known before Live starts) and never calls REST. A mic that sends nothing
    # is caught by the no-buffer watchdog (2.0 s + one rebuild + 1.5 s), never earlier. A one-off start failure is fixed by the rebuild.
    cid, voice, rate, text, expected = CORPUS[0]
    wav = tts(cid, voice, rate, text)
    for kind, notice, rebuild, lo_ms, hi_ms, live_ok in (("start", "Mic unavailable", True, 0, 1000, False),
                                                         ("denied", "Mic access needed", False, 0, 1000, False),
                                                         ("nobuffers", "Mic unavailable", True, 3000, 4500, True)):
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=30, extra=["--e2e-mic-fail", kind])
        ms = r["mic_unavailable_ms"]
        ok = (r["exit"] == 0 and r["result"] == "<MIC UNAVAILABLE>" and ms is not None and lo_ms <= ms <= hi_ms
              and r["mic_notice"] == notice and r["mic_rebuilt"] == rebuild and not r["rest_called"] and not r["live_ok"]
              and (live_ok or not r["live_connect"]) and r["wall_s"] <= 15)
        gate(f"T16 mic-unavailable/{kind}", ok,
             f"marker after {ms}ms (want {lo_ms}-{hi_ms}) notice={r['mic_notice']!r} rebuilt={r['mic_rebuilt']} "
             f"live_connect={r['live_connect']} rest_called={r['rest_called']} wall={r['wall_s']}s -> {r['result']!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))
    for _ in range(2):  # retry once: the on-device recall is load-sensitive
        r = run_e2e(a.bin, wav, timeout=60, extra=["--e2e-mic-fail", "start-once"])
        rc = recall(expected, r["result"] or "")
        if rc >= MIN_CASE_RECALL:
            break
    res = r["result"] or ""
    ok = (r["exit"] == 0 and r["mic_rebuilt"] and r["mic_restarted"] and r["mic_unavailable_ms"] is None
          and rc >= MIN_CASE_RECALL and res.endswith(" "))
    gate("T16 mic-unavailable/start-once", ok, f"rebuilt={r['mic_rebuilt']} restarted={r['mic_restarted']} recall={rc:.2f} "
         f"lat={r['latency_ms']}ms -> {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T2 analyzer (last: CPU heavy)
    if not a.quick:
        n = analyzer_count()
        report["analyzer_warnings"] = n
        limit = base.get("analyzer_warnings", n)
        gate("T2 static analyzer", n <= limit, f"{n} warnings (baseline {limit})")

    for w in report.get("quality_warnings", []):
        print(f"QUALITY WARNING: {w}")
    os.makedirs(LOGS, exist_ok=True)
    rpath = os.path.join(LOGS, f"test-{time.strftime('%Y%m%d-%H%M%S')}.json")
    json.dump(report, open(rpath, "w"), indent=2)
    print(f"\n{len(report['gates']) - len(fails)}/{len(report['gates'])} gates passed. "
          f"mean_recall={mean_recall:.3f} median_latency={med_lat}ms. Report: {rpath}")

    if a.update_baseline and not fails and not a.quick:
        nb = dict(base)
        nb["analyzer_warnings"] = min(base.get("analyzer_warnings", 10**9), report["analyzer_warnings"])
        nb["mean_recall"] = max(base.get("mean_recall", 0), mean_recall)
        if med_lat is not None:
            nb["median_latency_ms"] = min(base.get("median_latency_ms", 10**9), med_lat)
        nb["updated"] = report["time"]
        json.dump(nb, open(BASELINE, "w"), indent=2)
        print(f"Baseline updated: {nb}")

    if fails:
        print("FAILED gates: " + ", ".join(fails))
        return 1
    return 0


def _read_pcm(path):
    import array
    with wave.open(path, "rb") as w:
        a = array.array("h"); a.frombytes(w.readframes(w.getnframes()))
        return a


def _write_pcm(path, a):
    """Write 16 kHz mono int16 PCM as a WAV, atomically (temp file + rename) so an interrupted run never leaves a partial cache file."""
    tmp = _tmp_beside(path)
    try:
        with wave.open(tmp, "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
            w.writeframes(a.tobytes())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def wav_seconds(path):
    with wave.open(path, "rb") as w:
        return w.getnframes() / float(w.getframerate())


def derived_wav(kind, src_id, texts):
    """Harder Live cases built from TTS audio: noise, pauses, quiet speech."""
    import array, random
    os.makedirs(CACHE, exist_ok=True)
    key = hashlib.sha1(f"{kind}|{'|'.join(texts)}".encode()).hexdigest()[:12]
    path = os.path.join(CACHE, f"{kind}-{key}.wav")
    if _cached_wav(path):
        return path
    if kind == "long_session":     # backlog 0m: ~5/10 min hands-free session built sentence by sentence
        _write_pcm(path, _long_session_pcm(src_id, texts))
        return path
    clips = [_read_pcm(tts(f"{src_id}{i}", None, None, t)) for i, t in enumerate(texts)]
    if kind == "noisy":            # white noise at roughly 10 dB SNR
        a = clips[0]; rms = (sum(x * x for x in a) / len(a)) ** 0.5; rnd = random.Random(7)
        out = array.array("h", (max(-32768, min(32767, int(x + rnd.gauss(0, rms / 3.16)))) for x in a))
    elif kind == "quiet":          # -18 dB
        out = array.array("h", (int(x * 0.125) for x in clips[0]))
    elif kind == "pause":          # 1.8 s of silence between sentences
        out = array.array("h"); gap = array.array("h", [0] * int(16000 * 1.8))
        for i, c in enumerate(clips):
            if i: out.extend(gap)
            out.extend(c)
    elif kind == "marathon":       # multi-minute hands-free session: paragraphs with natural ~0.8 s pauses
        out = array.array("h"); gap = array.array("h", [0] * int(16000 * 0.8))
        for i, c in enumerate(clips):
            if i: out.extend(gap)
            out.extend(c)
    elif kind == "quiet_long":     # soft speaker in a long session: ~1 s pauses (triggers Live splitting), speech RMS ~220
        joined = array.array("h"); gap = array.array("h", [0] * int(16000 * 1.0))
        for i, c in enumerate(clips):
            if i: joined.extend(gap)
            joined.extend(c)
        voiced = [x for x in joined if abs(x) > 300] or [1]
        rms = (sum(x * x for x in voiced) / len(voiced)) ** 0.5
        k = 220.0 / rms
        out = array.array("h", (int(x * k) for x in joined))
    elif kind == "trailing_silence":  # one long sentence, then 2.2 s of silence before the release (pause, then let go of Fn)
        out = array.array("h", clips[0]); out.extend(array.array("h", [0] * int(16000 * 2.2)))
    else:
        raise ValueError(kind)
    _write_pcm(path, out)
    return path


def _sentences(paragraph):
    return [x for x in re.split(r"(?<=[.!?])\s+", paragraph.strip()) if x]


def _trim_silence(a, level=200, margin_s=0.06):
    """TTS clip without its leading/trailing silence (keeps margin_s of it), so the pauses between sentences are what we set."""
    import array
    loud = [i for i, x in enumerate(a) if abs(x) > level]
    if not loud:
        return array.array("h", a)
    m = int(16000 * margin_s)
    return array.array("h", a[max(0, loud[0] - m):min(len(a), loud[-1] + m)])


def _long_session_pcm(src_id, paragraphs):
    """Backlog 0m: a long hands-free session from TTS paragraphs, one TTS clip per sentence (cached through tts(), shared across
    the clips by text): natural 0.6-1.2 s pauses between sentences and paragraphs, and a 2 s pause before every third paragraph
    (thinking pauses). Deterministic (seeded), so the cached clip is stable."""
    import array, random
    rnd = random.Random(sum(len(t) for t in paragraphs))
    out = array.array("h")
    for p_i, para in enumerate(paragraphs):
        for s_i, sent in enumerate(_sentences(para)):
            clip = _trim_silence(_read_pcm(tts(src_id, None, None, sent)))
            if len(out):
                gap = 2.0 if (s_i == 0 and p_i % 3 == 0) else rnd.uniform(0.6, 1.2)
                out.extend(array.array("h", [0] * int(16000 * gap)))
            out.extend(clip)
    return out


def short_wav(case_id, text, rate=None, voice=None):
    """Very short dictation (single word / short phrase): TTS with the trailing silence trimmed to 40 ms, like a quick Fn tap
    that is released right after the word (2026-11-06 09:27: a 0.4 s real clip waited out the 2.5 s Live cap, then REST)."""
    import array
    os.makedirs(CACHE, exist_ok=True)
    key = hashlib.sha1(f"short|{voice}|{rate}|{text}".encode()).hexdigest()[:12]
    path = os.path.join(CACHE, f"{case_id}-{key}.wav")
    if _cached_wav(path):
        return path
    a = _read_pcm(tts(f"{case_id}_src", voice, rate, text))
    voiced = [i for i, x in enumerate(a) if abs(x) > 500] or [len(a) - 1]
    end = min(len(a), voiced[-1] + int(16000 * 0.04))
    _write_pcm(path, array.array("h", a[:end]))
    return path


def nospeech_wav(case_id, seconds, sigma=40.0):
    """Press with no speech (accidental tap / Fn+key shortcut): low room-noise level, no voice."""
    import array, random
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, f"{case_id}-{seconds:.2f}-{sigma:.0f}.wav")
    if not _cached_wav(path):
        rnd = random.Random(11)
        _write_pcm(path, array.array("h", (int(max(-32768, min(32767, rnd.gauss(0, sigma)))) for _ in range(int(16000 * seconds)))))
    return path


def room_noise_wav(case_id, seconds):
    """Backlog 0u: a silent press in an ordinary quiet room (real 2026-11-12 16:01: max frame RMS 133-239, 1.82 s of a 2.3 s hold
    above the old RMS-60 level). Gaussian noise whose 20 ms frame level wanders between RMS ~80 and ~200, plus a few 20 ms
    ~240-RMS clicks. Deterministic (seeded), so the cached clip is stable."""
    import array, math, random
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, f"{case_id}-{seconds:.2f}-room.wav")
    if _cached_wav(path):
        return path
    rnd = random.Random(23)
    n = int(16000 * seconds)
    a = array.array("h")
    for i in range(n):
        lvl = 80 + 120 * (0.5 + 0.5 * math.sin((i // 320) / 7.0))
        a.append(int(max(-32768, min(32767, rnd.gauss(0, lvl)))))
    for t in [x * 0.8 + 0.1 for x in range(int(seconds / 0.8) + 1)]:  # a click every 0.8 s
        s0 = int(t * 16000)
        for i in range(s0, min(n, s0 + 320)):
            a[i] = int(max(-32768, min(32767, rnd.gauss(0, 240))))
    _write_pcm(path, a)
    return path


_FILLERS_TEXT = CORPUS[0][3]
_FILLERS_EXP = CORPUS[0][4]
_HF_TEXT = (CORPUS[4][3] + " " +
            "After that, we will run a short retrospective to look at what slowed us down. "
            "I want everyone to bring one concrete suggestion, ideally something we can try in the very next sprint. "
            "Finally, remember that the offsite is moving to the second week of the month, so update your calendars.")
# ~2.1 min (124 s) hands-free session (one long Fn double-tap): tests release->text latency and server limits on long activities.
_MARATHON_PARAS = [
    "Good morning everyone, here is the weekly update for the mobile team. The new onboarding flow shipped to all users "
    "on Tuesday, and the early feedback has been very positive. Sign up completion went up noticeably, and support tickets "
    "about account creation dropped. Thanks to everyone who stayed late to get the release over the line.",
    "On the reliability side, we finally tracked down the crash that happened when the app resumed from the background. "
    "It turned out to be a race between the network layer and the cache cleanup task. The fix is small, but we added a "
    "regression test and a new alert so we will notice right away if it ever comes back.",
    "Next, a few words about performance. Cold start time is still slower than we would like, especially on older phones. "
    "The plan is to defer loading the settings screen and the analytics library until after the first frame is drawn. "
    "We expect this to save a noticeable amount of time, and we will measure it carefully before and after the change.",
    "For the design review on Thursday, please bring your questions about the new navigation bar. The designers have "
    "prepared two alternatives, one with a floating button and one with a simple tab layout. We would like to pick one by "
    "the end of the week, so that engineering can start building it in the following sprint.",
    "There are also some changes to the on call rotation. Starting next month, each shift will last one week instead of "
    "two, and the handoff will happen on Monday afternoon. If you have a conflict with your assigned week, please swap "
    "with a teammate and update the shared calendar as soon as possible.",
    "One more thing before we wrap up. The documentation site has moved to a new address, and the old links will redirect "
    "for a few more weeks. If you find a broken page or an outdated example, please open a ticket so we can fix it "
    "quickly. Good documentation saves everyone time, so every small correction really helps.",
    "Finally, a reminder that the team offsite is coming up soon. We will spend the first morning on planning and the "
    "afternoon on a hands on workshop about accessibility. Please fill out the travel form by Friday and let the "
    "organizers know about any dietary restrictions. That is everything for today, thank you all for listening.",
]
_QUIET_LONG = [CORPUS[4][3].split(" Please make sure")[0],
               "Please make sure every open bug has an owner before the end of the sprint.",
               "Flag anything that is blocked, and send me a short summary tonight.",
               "Thanks everyone, that is all for today."]
# (id, audio builder, expected)
ONLINE_EXTRA = [
    ("noisy", lambda: derived_wav("noisy", "noisy_src", [_FILLERS_TEXT]), _FILLERS_EXP),
    ("quiet", lambda: derived_wav("quiet", "quiet_src", [CORPUS[2][3]]), CORPUS[2][4]),
    ("pause", lambda: derived_wav("pause", "pause_src", ["We should ship the update on Friday.",
                                                         "Then we can start planning the next sprint."]),
     "We should ship the update on Friday. Then we can start planning the next sprint."),
    ("handsfree_long", lambda: tts("handsfree_long", None, None, _HF_TEXT), _HF_TEXT),
    ("handsfree_marathon", lambda: derived_wav("marathon", "marathon_src", _MARATHON_PARAS), " ".join(_MARATHON_PARAS)),
    # Soft speaker + pauses after 10 s: guards against Live splitting treating quiet speech as silence and never sending it.
    ("quiet_long", lambda: derived_wav("quiet_long", "quiet_long_src", _QUIET_LONG), " ".join(_QUIET_LONG)),
    # Very short clips (0.4-1 s, released right after the last word): must finish on Live, not wait out the 2.5 s cap.
    ("short_yes", lambda: short_wav("short_yes", "Yes."), "Yes."),
    ("short_thanks", lambda: short_wav("short_thanks", "Thanks.", rate=230), "Thanks."),
    ("short_phrase", lambda: short_wav("short_phrase", "Call me back."), "Call me back."),
]

# Backlog 0m (user-approved 2026-11-11): daily long-dictation test, OPT-IN via the RUN_LONG flag file (see the docstring).
# Paragraph text avoids digits-vs-words ambiguity, contractions, fillers, "like", "kind of"/"sort of", spoken commands and
# repeated adjacent words, so recall measures Live (not the polish rules).
_LONG_A = [
    "Let me start with a quick summary of the customer interviews from last week. We spoke with a dozen people who use the "
    "product every day, mostly small business owners and freelancers. Almost all of them said the app saves them time, but many "
    "found the export screen confusing. Several people asked for a simpler way to share reports with their accountant.",
    "The most common complaint was about notifications. People feel that the app sends too many reminders, and some of them "
    "turned notifications off completely. That means they also miss the important alerts, such as failed payments. We should "
    "group the minor reminders into a daily digest and keep instant alerts only for things that need action.",
    "Another theme was search. Users often remember a client name or an amount, but not the date of an invoice. Right now search "
    "only looks at titles, so they scroll through long lists instead. Extending search to notes and amounts looks cheap, and it "
    "would make a real difference for heavy users.",
    "On the marketing side, the spring campaign is ready to launch. The landing page has been translated, the videos are edited, "
    "and the email sequence is scheduled. We still need final approval from legal on the pricing table, which should arrive by "
    "Wednesday. After that, the campaign can go live the same afternoon.",
    "I also want to mention hiring. We have open positions on the platform team and in customer support. Please share the job "
    "posts with anyone you think would be a good fit. Referrals have worked very well for us in the past, and the people who "
    "joined that way tend to stay longer.",
    "Before the next meeting, please read the short proposal about the new billing system. It explains why the current setup is "
    "hard to maintain and how a gradual migration would work. Leave your comments directly in the document, so the authors can "
    "answer them in a single place. We will make a decision together at the end of the month.",
    "One last point from the interviews. A few customers mentioned that the mobile app logs them out too often, especially when "
    "they switch between devices during the day. The security team agreed to review the session rules, as long as sensitive "
    "actions still ask for a password. We will share their recommendation in the next update.",
]
_LONG_B = [
    "Hi everyone, thanks for joining the product review today. I would like to walk through the main results from this quarter, "
    "then talk about the roadmap, and finish with a few open questions. Please hold your questions until the end of each "
    "section, and feel free to add notes in the shared document while I speak.",
    "Overall, the quarter went better than expected. Active users grew steadily every month, and retention improved after we "
    "redesigned the welcome screens. Revenue is slightly ahead of the plan, mostly because more teams upgraded to the business "
    "tier. Churn is still higher than we want among very small teams, and we will come back to that later.",
    "The mobile apps had a strong quarter as well. Crash rates dropped after the memory fixes, and the average rating in both app "
    "stores went up. The offline mode we released in February is now used by a large share of field workers, which is exactly "
    "the audience we built it for.",
    "Now let us turn to the roadmap. The top priority for the next quarter is collaboration. Customers keep asking to edit "
    "documents together in real time, with comments and simple approvals. This is a big project, so we plan to ship it in "
    "stages, starting with shared comments and presence indicators.",
    "The second priority is performance on large accounts. Some of our biggest customers have an enormous number of records, and "
    "loading their dashboards can take far too long. The data team has a plan to precompute the most common reports overnight "
    "and to cache them close to the user.",
    "The third area is accessibility. An external audit found several problems with keyboard navigation and screen reader "
    "labels. None of them are hard to fix, but together they make the product frustrating for some people. We have reserved "
    "time in every sprint to work through the list until it is done.",
    "Let me also share a few lessons from the last launch. We underestimated how much time the documentation would need, and "
    "support was flooded with questions during the first week. Next time, the help articles should be written alongside the "
    "feature, and support should get a preview at least a week before release.",
    "There is another risk I want to flag. Our main cloud contract renews in the summer, and the price will probably go up. The "
    "infrastructure team is comparing offers from other providers and looking at ways to reduce our storage costs. They will "
    "present their findings at the planning meeting next month.",
    "Let me say a few words about the support team. Response times improved this quarter, even though the number of tickets "
    "grew. Much of that came from the new help center, which answers the most frequent questions before people contact us. The "
    "team would like to add short videos to the most popular articles next.",
    "Our partner program is also growing. More agencies now resell the product to their own clients, and they ask for better "
    "tools to manage many accounts at once. A simple partner dashboard is on the list for the second half of the year, and we "
    "will invite a few agencies to test early designs.",
    "Now for the open questions. Should we keep investing in the desktop app, or focus entirely on the web version? Desktop "
    "usage is small but very loyal, and those users pay for the premium plan more often. I do not have a strong opinion yet, so "
    "I would love to hear what you think.",
    "Before we close, a short note about the office move. The new building is closer to the train station and has much better "
    "meeting rooms. Movers will pack the shared equipment on Friday evening, so please take your personal items home before "
    "then. Desks will be assigned by team, and the floor plan will be posted on the intranet.",
    "A last reminder about security training. Everyone must complete the online course before the end of the quarter, and it "
    "takes less than an hour. The course covers phishing, password managers, and how to report a lost laptop. Managers will "
    "receive a list of people who have not finished it yet, so please do not leave it until the last day.",
    "Finally, a big thank you to everyone who helped with the customer conference. The feedback was excellent, and many "
    "attendees told us it was the most useful event they went to this year. The recordings will be published on the website "
    "soon, and the slides are already in the shared folder. That is all from me, thank you for your time.",
]
# ~5 min: interview summary around the weekly update; ~10 min: product review around both (no paragraph twice in one clip).
_LONG_5MIN = _LONG_A[:3] + _MARATHON_PARAS + _LONG_A[3:]
_LONG_10MIN = _LONG_B[:6] + _LONG_A + _MARATHON_PARAS + _LONG_B[6:]
# (id, audio builder, expected)
ONLINE_LONG = [
    ("handsfree_5min", lambda: derived_wav("long_session", "long_s", _LONG_5MIN), " ".join(_LONG_5MIN)),
    ("handsfree_10min", lambda: derived_wav("long_session", "long_s", _LONG_10MIN), " ".join(_LONG_10MIN)),
]
RUN_LONG_FLAG = os.path.join(HERE, "RUN_LONG")
LONG_MIN_RECALL = 0.95
LONG_CLIP_RANGES_S = {"handsfree_5min": (270, 330), "handsfree_10min": (540, 660)}


def long_mode_enabled():
    """Long-dictation mode is on ONLY while the flag file exists (the protected launcher passes no extra args)."""
    return os.path.exists(RUN_LONG_FLAG)


def online_long_ids(flag_present):
    """The T23 long-dictation cases the online run adds: none without the flag, so the regular run is unchanged."""
    return [c[0] for c in ONLINE_LONG] if flag_present else []


def long_e2e_timeout_s(audio_s):
    """Harness timeout for a long case: the app's own e2e watchdog (GFE2EWatchdogSeconds in main.m: real-time feed + REST budget +
    slow-retry grace + WAV fallback watchdog + 30 s) + 60 s, so the app's watchdog always reports first."""
    rest = 8.0 + 0.25 * audio_s
    app = max(120.0, audio_s + 60.0 + (rest - 8.0), audio_s + rest + 4.0 + (5.0 + 0.5 * audio_s) + 30.0)
    return int(app + 60)


def long_dry_run():
    """Offline check of the long mode (no network, no app run): case selection, clip build and duration, harness timeouts."""
    ok = online_long_ids(False) == [] and online_long_ids(True) == ["handsfree_5min", "handsfree_10min"]
    print(f"RUN_LONG flag ({RUN_LONG_FLAG}) present now: {long_mode_enabled()}")
    print(f"long cases without the flag: {online_long_ids(False)}; with the flag: {online_long_ids(True)}")
    total = 0.0
    for cid, build, expected in ONLINE_LONG:
        t0 = time.time()
        wav = build()
        secs = wav_seconds(wav)
        total += secs
        lo, hi = LONG_CLIP_RANGES_S[cid]
        good = lo <= secs <= hi and wav_complete(wav)
        ok = ok and good
        n_sent = sum(len(_sentences(p)) for p in (_LONG_5MIN if cid == "handsfree_5min" else _LONG_10MIN))
        print(f"[{'OK' if good else 'BAD'}] {cid}: {secs:.1f}s audio (want {lo}-{hi}s), {n_sent} sentences, {len(words(expected))} words, "
              f"harness timeout {long_e2e_timeout_s(secs)}s, built/cached in {time.time() - t0:.1f}s -> {os.path.basename(wav)}")
    print(f"long mode adds ~{total / 60:.1f} min of real-time audio to the online run (plus ~5-10 s per case)")
    return 0 if ok else 1


LIVE_MODEL = "gemini-3.5-transcribe-live"
REST_MODEL = "gemini-3.5-flash-lite"
ONLINE_LIVE_IDS = ["fillers", "question", "keep_like", "long", "uk_voice", "fast_rate", "uk_female",
                   "noisy", "quiet", "pause", "handsfree_long", "handsfree_marathon", "quiet_long",
                   "short", "short_yes", "short_thanks", "short_phrase"]
# handsfree_marathon on REST: the never-lose-dictation safety net must handle a multi-minute recording when Live fails
# (cycle 4: 124 s of audio timed out on REST -> on-device partials, recall 0.32). Same T7 gates incl. recall >= 0.85.
ONLINE_REST_IDS = ["fillers", "question", "handsfree_marathon"]
# T9: REST retry on a fast transient 503 (cycle 5 saw HTTP 503 "high demand" in 1.7 s and the user got on-device text).
ONLINE_REST_RETRY_IDS = ["fillers", "question"]
# T9 slow (backlog 0f): (case, injected 503 delay in s). "question" is the same 2.6 s audio as the real 2026-11-06 clip (quiet).
ONLINE_REST_SLOW_RETRY = [("question", 6.0)]
ONLINE_MIN_RECALL = 0.85
USER_MAX_LATENCY_MS = 3000
REST_MEDIAN_LIMIT_MS = 4500  # user-approved 2026-11-10
# T10: Live presses with NO speech (2026-11-05/06: 0.4 s and 1.7 s presses with on-device "No speech detected" got no Live transcript,
# waited out the 2.5 s cap, then REST: ~4.1 s). Whatever the outcome text, the user must get it within the T8 limit.
ONLINE_LIVE_NOSPEECH = [("nospeech_tap", 0.40), ("nospeech_hold", 1.70)]
# T27 (backlog 0u, user-reported 2026-11-12): silent presses in an ordinary quiet room (louder noise than T10's sigma 40).
ONLINE_LIVE_ROOM_NOISE = [("room_tap", 0.40), ("room_hold", 2.30)]
# T11: the no-speech check must never eat real speech. Live is forced to return nothing (--e2e-live-drop-output, e2e only), so
# its final turn closes empty exactly like a no-speech press; quiet speech and very short words must still reach REST.
ONLINE_LIVE_EMPTY_GUARD_IDS = ["quiet", "short", "short_thanks"]
# T12 (backlog 6): press #2 ("question") starts while press #1 ("fillers") is still finishing. (phase, extra flags for press #1)
ONLINE_SECOND_PRESS = [("release", []), ("rest", ["--e2e-live-drop-output"]), ("restfail", ["--e2e-live-drop-output"])]
# T14 (backlog 0c): cases whose audio has a >= 1.5 s pause; the simulated server turn end fires this long into the first pause.
ONLINE_SERVER_TURN_END_IDS = ["pause"]
# T15 bounded wait (user-approved 2026-11-10): Live returns nothing (test-only) and the real REST call is held this long (test-only)
ONLINE_BOUNDED_WAIT = [("question", 4.0)]
SERVER_TURN_END_INTO_PAUSE_S = 0.25
# T18 (backlog 0h): (case, seconds of audio sent when the Live socket is force-closed). handsfree_long is 32.5 s; 14 s is mid-press,
# after the first split turn (>= 8 s) has been covered, so the reconnect must keep that text and resend only the rest.
ONLINE_LIVE_DROP = [("handsfree_long", 14.0)]
# T22 (backlog 26): (id, text). One ~13 s sentence (no pause >= 0.6 s inside, so the only split is at its end), then 2.2 s of silence.
_RELEASE_SILENCE_TEXT = ("We should ship the update on Friday, after the last round of testing is finished and the release notes "
                         "are reviewed by the whole team, and then we can start planning the next sprint together on Monday morning.")
ONLINE_RELEASE_BETWEEN_TURNS = [("release_silence", _RELEASE_SILENCE_TEXT)]
RELEASE_BETWEEN_TURNS_MAX_MS = 350
# T25 (backlog 0p): (id, audio builder, expected, rotation age in s; e2e-only override of the app's 8.5 min). Not handsfree_long:
# its only pause >= 0.6 s is 0.64 s long, so whether it splits at all depends on the 128 ms send phase (~50/50). Four sentences
# with 1.8 s pauses split for sure (activity >= 8 s by the 2nd or 3rd pause), and the split turn is answered inside the pause.
_ROTATE_SENTENCES = [
    "Good morning everyone, this is the weekly status update for the platform team and the people who depend on it.",
    "The new billing service went live on Tuesday, and so far the error rate has stayed well below our target.",
    "Next week we will focus on the search migration, which needs careful testing before we switch any traffic over.",
    "Please add your questions to the shared document by Thursday so that we can answer them in the next meeting.",
]
ONLINE_LIVE_ROTATE = [("rotate_pauses", lambda: derived_wav("pause", "rotate_src", _ROTATE_SENTENCES), " ".join(_ROTATE_SENTENCES), 10.0)]
# T26 (backlog 0p): (case, simulated session lifetime in s). At 8 s, handsfree_long sees ~3 lifetime closes (> kLiveMaxReconnects = 2).
ONLINE_LIVE_LIFETIME = [("handsfree_long", 8.0)]
ROTATION_MIN_RECALL = 0.95
# T26 only (backlog 0r): a seam after a long resend + slow split turn lost 4 words (recall 0.96 on 2026-11-12 11:25); fixed, so
# T26 must now deliver every word (stricter than T25's ROTATION_MIN_RECALL).
LIFETIME_MIN_RECALL = 0.99


def duplicated_phrases(expected, actual, n=4):
    """n-word phrases repeated in actual (text repeated at a reconnect/split seam): a phrase counts only when it occurs at least
    twice in actual AND more often than in expected. A phrase seen once can't be a repeat: recognizer variants ("road map" for
    roadmap, "team of sight" for offsite, "updated" for outdated) and dropped words at a sentence join make 4-grams that are absent
    from expected but occur once (2026-11-11 long run: 6 and 18 such false positives, all count 1). Backlog 0o."""
    def grams(ws):
        c = {}
        for i in range(len(ws) - n + 1):
            g = " ".join(ws[i:i + n]); c[g] = c.get(g, 0) + 1
        return c
    e, a = grams(words(expected)), grams(words(actual))
    return sorted(g for g, k in a.items() if k >= 2 and k > e.get(g, 0))


# T24 (backlog 0o): offline self-test of duplicated_phrases (pure Python). (name, expected, actual, phrases that MUST be reported
# (None = the result must be empty)). The variants are the recognizer outputs seen in the 2026-11-11 long run.
_DUP_SEAM_EXPECTED = ("The quarterly planning session went well. The design team will share new mockups next week, and engineering "
                      "will start on the backend changes right after.")
DUP_SELFTEST_CASES = [
    ("seam-repeat", _DUP_SEAM_EXPECTED,
     "The quarterly planning session went well. The design team will share the design team will share new mockups next week, "
     "and engineering will start on the backend changes right after.",
     ["design team will share", "the design team will"]),
    ("seam-repeat-of-repeated-phrase", "We will ship it soon. Then we will ship it again next month.",
     "We will ship it soon. Then we will ship it we will ship it again next month.", ["we will ship it"]),
    ("variant-road-map", "Now let us turn to the roadmap. The top priority for the next quarter is collaboration.",
     "Now let us turn to the road map. The top priority for the next quarter is collaboration.", None),
    ("variant-team-of-sight", "Finally, a reminder that the team offsite is coming up soon. We will spend the first morning on planning.",
     "Finally, a reminder that the team of sight is coming up soon. We will spend the first morning on planning.", None),
    ("variant-updated", "If you find a broken page or an outdated example, please open a ticket so we can fix it quickly.",
     "If you find a broken page or an updated example, please open a ticket so we can fix it quickly.", None),
    ("variant-articles", "Next time, the help articles should be written alongside the feature.",
     "Next time, the help article should be written alongside the feature.", None),
    ("join-dropped-words", "People who joined that way tend to stay longer. Before the next meeting, please read the short proposal.",
     "People who joined that way tend to stay longer. Please read the short proposal.", None),
    ("join-dropped-we", "They also miss the important alerts, such as failed payments. We should group the minor reminders.",
     "They also miss the important alerts such as failed payments. Should group the minor reminders.", None),
    ("expected-repeat-same-count", "At the end of the day we ship. At the end of the day we also test.",
     "At the end of the day we ship. At the end of the day we also test.", None),
    ("identical", _DUP_SEAM_EXPECTED, _DUP_SEAM_EXPECTED, None),
]


def dup_check_selftest():
    """Run DUP_SELFTEST_CASES; returns a list of 'name: got [...]' strings for the cases that failed (empty = all pass)."""
    bad = []
    for name, expected, actual, must in DUP_SELFTEST_CASES:
        got = duplicated_phrases(expected, actual)
        ok = (got == []) if must is None else (bool(got) and all(m in got for m in must))
        if not ok:
            bad.append(f"{name}: got {got}")
    return bad


def first_pause_start(path, min_gap=1.5, level=150):
    """Seconds at which the first silent stretch (20 ms frames with RMS <= level) of at least min_gap s after speech begins."""
    a = _read_pcm(path); frame = 320; run = 0; spoke = False
    for f in range(len(a) // frame):
        seg = a[f * frame:(f + 1) * frame]
        loud = (sum(x * x for x in seg) / frame) ** 0.5 > level
        if loud:
            spoke = True; run = 0
        elif spoke:
            run += 1
            if run * 0.02 >= min_gap:
                return (f + 1 - run) * 0.02
    return None


MAX_LOAD_PER_CPU = 3.0
LOAD_WAIT_S = 600


def wait_for_sane_load():
    """E2E speech results are meaningless on a massively oversubscribed machine (seen: load 705 on 12 cores).
    Wait up to LOAD_WAIT_S for the 1-min load average to fall below MAX_LOAD_PER_CPU x cores.
    Returns True if OK; False means the run is INCONCLUSIVE (exit 5)."""
    limit = MAX_LOAD_PER_CPU * os.cpu_count()
    deadline = time.time() + LOAD_WAIT_S
    while True:
        load = os.getloadavg()[0]
        if load <= limit:
            return True
        if time.time() > deadline:
            print(f"INCONCLUSIVE: load average {load:.0f} > {limit:.0f} for {LOAD_WAIT_S}s; not running speech tests")
            return False
        print(f"waiting for load to drop: {load:.0f} > {limit:.0f}", flush=True)
        time.sleep(30)


def network_ok():
    import socket
    try:
        socket.create_connection(("generativelanguage.googleapis.com", 443), timeout=4).close()
        return True
    except OSError:
        return False


def online_main(a):
    if not network_ok():
        print("SKIPPED: no network (run via run_online_tests.sh with network access)")
        return 4
    base = json.load(open(BASELINE)) if os.path.exists(BASELINE) else {}
    report = {"bin": a.bin, "time": time.strftime("%Y-%m-%d %H:%M:%S"), "mode": "online", "tests": [], "gates": []}
    fails = []

    known = set(base.get("known_failures", []))
    long_mode = long_mode_enabled()
    if long_mode:
        print(f"LONG MODE: {RUN_LONG_FLAG} exists; T23 long-dictation cases {online_long_ids(True)} run after the regular gates "
              f"(~16 min more). Delete RUN_LONG afterwards.", flush=True)

    def gate(name, ok, detail):
        # known_failures: pre-existing failures recorded by the coordinator. Reported, not blocking.
        # Agents may REMOVE entries once fixed (XPASS) but must never add new ones.
        tag = "PASS" if ok else ("XFAIL" if name in known else "FAIL")
        if ok and name in known:
            tag = "XPASS (fixed! remove from known_failures)"
        report["gates"].append({"gate": name, "ok": bool(ok), "tag": tag, "detail": detail})
        print(f"[{tag}] {name}: {detail}")
        if not ok and name not in known:
            fails.append(name)

    corpus = {c[0]: c for c in CORPUS}
    extra = {c[0]: c for c in ONLINE_EXTRA}
    stats = {}
    for label, model, ids, ok_key in (("T6 live", LIVE_MODEL, ONLINE_LIVE_IDS, "live_ok"),
                                     ("T7 rest", REST_MODEL, ONLINE_REST_IDS, "rest_ok")):
        recalls, lats = [], []
        for cid in ids:
            if cid in corpus:
                _, voice, rate, text, expected = corpus[cid]
                wav = tts(cid, voice, rate, text)
            else:
                _, build, expected = extra[cid]
                wav = build()
            r = run_e2e(a.bin, wav, model=model, timeout=max(150, int(wav_seconds(wav)) + 90))
            res = r["result"] or ""
            rc = recall(expected, res)
            lower = " " + " ".join(words(res)) + " "
            leaked = [f for f in FILLERS if f" {f} " in lower]
            ok = (r["exit"] == 0 and r[ok_key] and not r["fell_back"] and rc >= ONLINE_MIN_RECALL
                  and not leaked and res.endswith(" "))
            r.update({"id": cid, "model": model, "recall": round(rc, 3), "leaked_fillers": leaked})
            report["tests"].append(r)
            recalls.append(rc)
            if r["latency_ms"] is not None:
                lats.append(r["latency_ms"])
            gate(f"{label}/{cid}", ok,
                 f"recall={rc:.2f} lat={r['latency_ms']}ms fell_back={r['fell_back']} leaked={leaked} -> {res!r}"
                 + ("" if ok else f"\n      tail: {r['tail']}"))
        key = label.split()[1]
        if key == "live":
            # T8: what the user experiences in Live mode, regardless of which path produced the text:
            # no dropped words and a bounded wait. (T6 separately tracks whether Live itself handled it.)
            for t in [t for t in report["tests"] if t.get("model") == model]:
                lat = t["latency_ms"] if t["latency_ms"] is not None else 10**9
                ok8 = t["exit"] == 0 and t["recall"] >= ONLINE_MIN_RECALL and lat <= USER_MAX_LATENCY_MS
                gate(f"T8 user/{t['id']}", ok8,
                     f"recall={t['recall']:.2f} lat={t['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) via={'fallback' if t['fell_back'] else 'live'}")
        med = statistics.median(lats) if lats else None
        stats[key] = {"mean_recall": statistics.mean(recalls), "median_latency_ms": med}
        bl = base.get(f"online_{key}_median_latency_ms")
        if med is not None and bl is not None:
            # REST (the backup service) swings 1.3-4 s on normal days, so a ratcheting 2x-best-ever limit flaked constantly.
            # USER-APPROVED 2026-11-10: fixed 4.5 s limit for REST. Live keeps the ratcheting limit.
            limit = REST_MEDIAN_LIMIT_MS if key == "rest" else max(LATENCY_FLOOR_MS, 2 * bl)
            gate(f"{label} median latency", med <= limit, f"{med}ms (baseline {bl}ms, limit {limit}ms)")
        br = base.get(f"online_{key}_mean_recall")
        if br is not None:
            gate(f"{label} mean recall", stats[key]["mean_recall"] >= br - MAX_RECALL_DROP,
                 f"{stats[key]['mean_recall']:.3f} (baseline {br:.3f})")

    # T10: no-speech presses on Live must end (any outcome: <NO SPEECH> or REST/on-device text) within the T8 limit.
    for cid, secs in ONLINE_LIVE_NOSPEECH:
        wav = nospeech_wav(cid, secs)
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = r["exit"] == 0 and r["result"] is not None and lat <= USER_MAX_LATENCY_MS
        # Tightened (backlog 0e): REST hallucinates on noise, so the outcome must be <NO SPEECH>, nothing pasted, no REST call.
        ok = ok and (r["result"] or "").strip() == "<NO SPEECH>" and r["nospeech_skip"] and not r["rest_called"]
        r.update({"id": f"nospeech/{cid}", "model": LIVE_MODEL + "+nospeech", "recall": None})
        report["tests"].append(r)
        gate(f"T10 live-nospeech/{cid}", ok,
             f"lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) exit={r['exit']} live_ok={r['live_ok']} fell_back={r['fell_back']} "
             f"nospeech_skip={r['nospeech_skip']} rest_called={r['rest_called']} "
             f"-> {(r['result'] or '')[:60]!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T27 (backlog 0u): silent presses in an ordinary quiet room (noise above the old RMS-60 level) must end as <NO SPEECH> too,
    # with no REST call (REST invents text for room noise), within the T8 limit.
    for cid, secs in ONLINE_LIVE_ROOM_NOISE:
        wav = room_noise_wav(cid, secs)
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and (r["result"] or "").strip() == "<NO SPEECH>" and r["nospeech_skip"] and not r["rest_called"]
              and lat <= USER_MAX_LATENCY_MS)
        r.update({"id": f"room_noise/{cid}", "model": LIVE_MODEL + "+roomnoise", "recall": None})
        report["tests"].append(r)
        gate(f"T27 live-room-noise/{cid}", ok,
             f"lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) exit={r['exit']} nospeech_skip={r['nospeech_skip']} "
             f"rest_called={r['rest_called']} -> {(r['result'] or '')[:60]!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T11: Live returns nothing (test-only hook) but the audio HAS speech: the no-speech check must run, must not fire, and the
    # REST safety net must deliver the dictation with full recall (never lose a dictation).
    for cid in ONLINE_LIVE_EMPTY_GUARD_IDS:
        if cid in corpus:
            _, voice, rate, text, expected = corpus[cid]
            wav = tts(cid, voice, rate, text)
        else:
            _, build, expected = extra[cid]
            wav = build()
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150, extra=["--e2e-live-drop-output"])
        res = r["result"] or ""
        rc = recall(expected, res)
        ok = (r["exit"] == 0 and r["nospeech_check"] and not r["nospeech_skip"] and res.strip() != "<NO SPEECH>"
              and r["rest_ok"] and not r["ondevice_fallback"] and rc >= ONLINE_MIN_RECALL and res.endswith(" "))
        r.update({"id": f"live_empty_guard/{cid}", "model": LIVE_MODEL + "+drop", "recall": round(rc, 3)})
        report["tests"].append(r)
        gate(f"T11 live-empty-guard/{cid}", ok,
             f"check_ran={r['nospeech_check']} nospeech_skip={r['nospeech_skip']} rest_ok={r['rest_ok']} ondevice={r['ondevice_fallback']} "
             f"recall={rc:.2f} lat={r['latency_ms']}ms -> {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T12: a new press must never lose the previous dictation, and must itself be unaffected (backlog 6). Press #1 must come back
    # after press #2 started (superseded) via REST on its own recording ("restfail": its saved on-device text, a coarser safety
    # net, so the offline per-case recall floor applies); press #2 must finish on Live within the T8 limit with full recall.
    _, _, _, text_a, exp_a = corpus["fillers"]
    _, _, _, text_b, exp_b = corpus["question"]
    wav_a, wav_b = tts("fillers", None, None, text_a), tts("question", None, None, text_b)
    for phase, flags in ONLINE_SECOND_PRESS:
        r = run_e2e_two(a.bin, wav_a, wav_b, phase, LIVE_MODEL, timeout=150, extra=flags)
        ra, rb = r["results"].get(1) or "", r["results"].get(2) or ""
        la, lb = r["latencies"].get(1, (None, False)), r["latencies"].get(2, (None, False))
        rca, rcb = recall(exp_a, ra), recall(exp_b, rb)
        if phase == "restfail":
            ok_a = r["ondevice_fallback"] and r["snapshot_ondevice"] and rca >= MIN_CASE_RECALL
        else:
            ok_a = r["rest_ok"] and not r["ondevice_fallback"] and rca >= ONLINE_MIN_RECALL
        ok_a = ok_a and la[1] and ra.endswith(" ") and ra.strip() != "<NO SPEECH>"
        ok_b = (r["live_ok"] and rcb >= ONLINE_MIN_RECALL and rb.endswith(" ") and not lb[1]
                and lb[0] is not None and lb[0] <= USER_MAX_LATENCY_MS)
        ok = r["exit"] == 0 and r["both"] and r["second_started"] and ok_a and ok_b
        report["tests"].append({"id": f"second_press/{phase}", "model": LIVE_MODEL + "+2press", "exit": r["exit"],
                                "recall_a": round(rca, 3), "recall_b": round(rcb, 3), "latency_a_ms": la[0],
                                "latency_b_ms": lb[0], "wall_s": r["wall_s"]})
        gate(f"T12 second-press/{phase}", ok,
             f"#1 superseded={la[1]} recall={rca:.2f} lat={la[0]}ms rest_ok={r['rest_ok']} ondevice={r['ondevice_fallback']} | "
             f"#2 recall={rcb:.2f} lat={lb[0]}ms (limit {USER_MAX_LATENCY_MS}ms) live_ok={r['live_ok']} -> {ra!r} / {rb!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T14 (backlog 0c): the server ends the open turn on its own mid-press (test-only hook, e2e only), in the pause between two
    # sentences. The second sentence must still come back on Live (the app re-opens the activity), not through the REST safety net.
    for cid in ONLINE_SERVER_TURN_END_IDS:
        _, build, expected = extra[cid]
        wav = build()
        pause = first_pause_start(wav)
        at = round((pause or 0) + SERVER_TURN_END_INTO_PAUSE_S, 2)
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150, extra=["--e2e-live-server-turn-end", str(at)])
        res = r["result"] or ""
        rc = recall(expected, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (pause is not None and r["exit"] == 0 and r["fired"] and r["live_ok"] and not r["fell_back"]
              and rc >= ONLINE_MIN_RECALL and lat <= USER_MAX_LATENCY_MS and res.endswith(" "))
        r.update({"id": f"server_turn_end/{cid}", "model": LIVE_MODEL + "+server-turn-end", "recall": round(rc, 3)})
        report["tests"].append(r)
        gate(f"T14 live-server-turn-end/{cid}", ok,
             f"turn end at {at:.2f}s (pause at {pause}) fired={r['fired']} reopened={r['reopened']} live_ok={r['live_ok']} "
             f"fell_back={r['fell_back']} recall={rc:.2f} lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T18 (backlog 0h): the Live socket dies mid-press (test-only hook). The app must reconnect while still recording, resend from
    # the last covered byte, and deliver on Live: no REST fallback, full recall, no duplicated phrase at the seam, within the T8 limit.
    for cid, at in ONLINE_LIVE_DROP:
        _, build, expected = extra[cid]
        wav = build()
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=max(150, int(wav_seconds(wav)) + 90), extra=["--e2e-live-drop-at", str(at)])
        res = r["result"] or ""
        rc = recall(expected, res)
        dups = duplicated_phrases(expected, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["dropped"] and r["reconnected"] and r["live_ok"] and not r["fell_back"] and not r["rest_called"]
              and rc >= ONLINE_MIN_RECALL and not dups and lat <= USER_MAX_LATENCY_MS and res.endswith(" "))
        r.update({"id": f"live_drop/{cid}", "model": LIVE_MODEL + f"+drop@{at:g}s", "recall": round(rc, 3), "duplicated": dups})
        report["tests"].append(r)
        gate(f"T18 live-reconnect/{cid}", ok,
             f"drop at {at:g}s dropped={r['dropped']} reconnected={r['reconnected']} live_ok={r['live_ok']} fell_back={r['fell_back']} "
             f"rest_called={r['rest_called']} recall={rc:.2f} duplicated={dups[:3]} lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) "
             f"-> {res!r}" + ("" if ok else f"\n      tail: {r['tail']}"))

    # T22 (backlog 26): released in silence after the split turn was already answered. Nothing is pending, so the app must finish
    # on Live right away ("released between turns"), not at the 0.45 s grace timer (old: ~570 ms incl. the 120 ms cushion).
    for cid, text in ONLINE_RELEASE_BETWEEN_TURNS:
        wav = derived_wav("trailing_silence", f"{cid}_src", [text])
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150)
        res = r["result"] or ""
        rc = recall(text, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["live_ok"] and r["between_turns"] and not r["fell_back"] and not r["rest_called"]
              and rc >= ONLINE_MIN_RECALL and lat <= RELEASE_BETWEEN_TURNS_MAX_MS and res.endswith(" "))
        r.update({"id": f"release_between_turns/{cid}", "model": LIVE_MODEL + "+trailing-silence", "recall": round(rc, 3)})
        report["tests"].append(r)
        gate(f"T22 live-release-between-turns/{cid}", ok,
             f"between_turns={r['between_turns']} live_ok={r['live_ok']} fell_back={r['fell_back']} rest_called={r['rest_called']} "
             f"recall={rc:.2f} lat={r['latency_ms']}ms (limit {RELEASE_BETWEEN_TURNS_MAX_MS}ms) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T25 (backlog 0p (a)): planned rotation at a split point, forced at 10 s of session age (test-only hook). The fresh session
    # continues from the held-back position: on Live, nothing lost or repeated, no reconnect used.
    for cid, build, expected, age in ONLINE_LIVE_ROTATE:
        wav = build()
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=max(150, int(wav_seconds(wav)) + 90), extra=["--e2e-live-rotate-age", str(age)])
        res = r["result"] or ""
        rc = recall(expected, res)
        dups = duplicated_phrases(expected, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["rotation_count"] >= 1 and r["rotated_ready_count"] >= 1 and r["press_rotations"] >= 1
              and r["reconnect_count"] == 0 and r["reconnect_scheduled"] == 0 and r["press_reconnects"] == 0
              and r["live_ok"] and not r["fell_back"] and not r["rest_called"]
              and rc >= ROTATION_MIN_RECALL and not dups and lat <= USER_MAX_LATENCY_MS and res.endswith(" "))
        r.update({"id": f"live_rotate/{cid}", "model": LIVE_MODEL + f"+rotate@{age:g}s", "recall": round(rc, 3), "duplicated": dups})
        report["tests"].append(r)
        gate(f"T25 live-rotation/{cid}", ok,
             f"rotate age {age:g}s rotations={r['rotation_count']} ready={r['rotated_ready_count']} stats_rotations={r['press_rotations']} "
             f"reconnects={r['reconnect_count']}/{r['reconnect_scheduled']}/{r['press_reconnects']} live_ok={r['live_ok']} "
             f"fell_back={r['fell_back']} rest_called={r['rest_called']} recall={rc:.2f} (min {ROTATION_MIN_RECALL}) "
             f"duplicated={dups[:3]} lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T26 (backlog 0p (b)): the server's session-lifetime close, simulated every 8 s of session age (test-only hook): every close
    # must be a planned rotation (not counted), even past the 2-reconnect budget, and the dictation must stay on Live, complete.
    for cid, life in ONLINE_LIVE_LIFETIME:
        _, build, expected = extra[cid]
        wav = build()
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=max(150, int(wav_seconds(wav)) + 90), extra=["--e2e-live-lifetime", str(life)])
        res = r["result"] or ""
        rc = recall(expected, res)
        dups = duplicated_phrases(expected, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["lifetime_closes"] >= 3 and r["planned_close_count"] == r["lifetime_closes"]
              and r["rotated_ready_count"] >= 3 and r["reconnect_count"] == 0 and r["reconnect_scheduled"] == 0
              and r["press_reconnects"] == 0 and r["live_ok"] and not r["fell_back"] and not r["rest_called"]
              and rc >= LIFETIME_MIN_RECALL and not dups and lat <= USER_MAX_LATENCY_MS and res.endswith(" "))
        r.update({"id": f"live_lifetime/{cid}", "model": LIVE_MODEL + f"+lifetime@{life:g}s", "recall": round(rc, 3), "duplicated": dups})
        report["tests"].append(r)
        gate(f"T26 live-lifetime-close/{cid}", ok,
             f"lifetime {life:g}s closes={r['lifetime_closes']} planned={r['planned_close_count']} ready={r['rotated_ready_count']} "
             f"reconnects={r['reconnect_count']}/{r['reconnect_scheduled']}/{r['press_reconnects']} live_ok={r['live_ok']} "
             f"fell_back={r['fell_back']} rest_called={r['rest_called']} recall={rc:.2f} (min {LIFETIME_MIN_RECALL}) "
             f"duplicated={dups[:3]} lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T15 (user-approved 2026-11-10): Live fails (its output is dropped, test-only) and the real REST answer is held 4 s
    # (test-only), so REST can't answer within ~3 s of release. The on-device text must be delivered early (2.7-4.0 s after
    # release: 3 s, or 1 s into a late-starting REST call), then the REST text as the final result with full recall.
    for cid, hold in ONLINE_BOUNDED_WAIT:
        _, voice, rate, text, expected = corpus[cid]
        wav = tts(cid, voice, rate, text)
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=150, extra=["--e2e-live-drop-output", "--e2e-rest-delay", str(hold)])
        res, early, el = r["result"] or "", r["early"] or "", r["early_latency_ms"]
        rc, erc = recall(expected, res), recall(expected, early)
        ok = (r["exit"] == 0 and el is not None and 2700 <= el <= 4000 and erc >= MIN_CASE_RECALL and r["early_first"]
              and r["rest_ok"] and not r["ondevice_fallback"] and rc >= ONLINE_MIN_RECALL and res.endswith(" "))
        r.update({"id": f"bounded_wait/{cid}", "model": LIVE_MODEL + f"+drop+rest-hold-{hold:g}s", "recall": round(rc, 3)})
        report["tests"].append(r)
        gate(f"T15 bounded-wait/{cid}", ok,
             f"early at {el}ms (want 2700-4000) early_recall={erc:.2f} early_first={r['early_first']} rest_ok={r['rest_ok']} "
             f"ondevice={r['ondevice_fallback']} recall={rc:.2f} final lat={r['latency_ms']}ms -> early {early!r} / final {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T9: inject a fast HTTP 503 on the first REST attempt (test-only hook, e2e mode only). The same-model retry must bring the
    # dictation back via REST (not on-device), with full recall, within the user latency limit.
    # T9 measures what the RETRY adds (fast failure + 0.5 s backoff + local work = total latency minus the retried REST call's own
    # server time, taken from app-log timestamps), not how fast the REST service is that minute. T7 already gates REST speed, and server-side REST latency swung
    # 1.5-8 s on 2026-11-04, which made a fixed total limit flaky. Overall cap = the short-clip REST budget (~9.25 s) + margin.
    RETRY_OVERHEAD_LIMIT_MS = 1500
    RETRY_TOTAL_CAP_MS = 10000
    for cid in ONLINE_REST_RETRY_IDS:
        _, voice, rate, text, expected = corpus[cid]
        wav = tts(cid, voice, rate, text)
        r = run_e2e(a.bin, wav, model=REST_MODEL, timeout=150, extra=["--e2e-rest-503-once"])
        res = r["result"] or ""
        rc = recall(expected, res)
        lower = " " + " ".join(words(res)) + " "
        leaked = [f for f in FILLERS if f" {f} " in lower]
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["injected_503"] and r["rest_retried"] and r["rest_ok"] and not r["ondevice_fallback"]
              and rc >= ONLINE_MIN_RECALL and r["retried_call_s"] is not None
              and lat - r["retried_call_s"] * 1000 <= RETRY_OVERHEAD_LIMIT_MS and lat <= RETRY_TOTAL_CAP_MS
              and not leaked and res.endswith(" "))
        r.update({"id": f"rest503/{cid}", "model": REST_MODEL + "+503", "recall": round(rc, 3), "leaked_fillers": leaked})
        report["tests"].append(r)
        gate(f"T9 rest503/{cid}", ok,
             f"injected={r['injected_503']} retried={r['rest_retried']} rest_ok={r['rest_ok']} ondevice={r['ondevice_fallback']} "
             f"recall={rc:.2f} lat={r['latency_ms']}ms retried_call={(r['retried_call_s'] or 0):.2f}s retry_overhead={(lat - (r['retried_call_s'] or 0) * 1000):.0f}ms "
             f"(limits: overhead {RETRY_OVERHEAD_LIMIT_MS}ms, total {RETRY_TOTAL_CAP_MS}ms) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T9 slow (backlog 0f): the injected 503 arrives after `delay` s, past the cycle-6 fast window (a quarter of the budget), as the
    # real 2026-11-06 503 did (5.97 s). The slow-retry policy must still bring the dictation back via REST. The existing T9 gates
    # above are untouched; this case gets its own limits because the injected delay is deliberate server slowness, not retry cost:
    #   overhead (latency minus the retried call's server time) <= delay + 1.5 s: the same 1.5 s retry-overhead allowance as T9,
    #     on top of the simulated slow failure;
    #   total <= the app's slow-retry deadline for this clip: REST budget (8 s + 0.25 s per audio second) + 4 s grace, + 0.25 s for
    #     the release->REST hop. The app can't exceed it by design (the retry's idle timeout is what is left of that deadline).
    for cid, delay in ONLINE_REST_SLOW_RETRY:
        _, voice, rate, text, expected = corpus[cid]
        wav = tts(cid, voice, rate, text)
        with wave.open(wav) as w:
            dur = w.getnframes() / float(w.getframerate())
        overhead_limit_ms = int(delay * 1000) + RETRY_OVERHEAD_LIMIT_MS
        total_cap_ms = int((8.0 + 0.25 * dur + 4.0) * 1000) + 250
        r = run_e2e(a.bin, wav, model=REST_MODEL, timeout=150, extra=["--e2e-rest-503-once", "--e2e-rest-503-delay", str(delay)])
        res = r["result"] or ""
        rc = recall(expected, res)
        lower = " " + " ".join(words(res)) + " "
        leaked = [f for f in FILLERS if f" {f} " in lower]
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        overhead = lat - (r["retried_call_s"] or 0) * 1000
        ok = (r["exit"] == 0 and r["injected_503"] and r["rest_retried"] and r["rest_ok"] and not r["ondevice_fallback"]
              and rc >= ONLINE_MIN_RECALL and r["retried_call_s"] is not None
              and lat >= delay * 1000 and overhead <= overhead_limit_ms and lat <= total_cap_ms
              and not leaked and res.endswith(" "))
        r.update({"id": f"rest503slow/{cid}", "model": REST_MODEL + f"+503@{delay:g}s", "recall": round(rc, 3), "leaked_fillers": leaked})
        report["tests"].append(r)
        gate(f"T9 rest503-slow/{cid}", ok,
             f"delay={delay:g}s injected={r['injected_503']} retried={r['rest_retried']} rest_ok={r['rest_ok']} ondevice={r['ondevice_fallback']} "
             f"recall={rc:.2f} lat={r['latency_ms']}ms retried_call={(r['retried_call_s'] or 0):.2f}s retry_overhead={overhead:.0f}ms "
             f"(limits: overhead {overhead_limit_ms}ms, total {total_cap_ms}ms for {dur:.2f}s audio) -> {res!r}"
             + ("" if ok else f"\n      tail: {r['tail']}"))

    # T23 (backlog 0m, OPT-IN: only while RUN_LONG exists): ~5 and ~10 min hands-free sessions must finish ON LIVE (no REST, no
    # fallback) with recall >= 0.95, no phrase duplicated at a split/reconnect seam, release->text within the T8 limit. Reported
    # (not gated): reconnects, Live session age at release, split activities, the app's peak RSS. Not part of the T6/T8 stats.
    long_ids = online_long_ids(long_mode)
    for cid, build, expected in [c for c in ONLINE_LONG if c[0] in long_ids]:
        wav = build()
        secs = wav_seconds(wav)
        r = run_e2e(a.bin, wav, model=LIVE_MODEL, timeout=long_e2e_timeout_s(secs), rusage=True)
        res = r["result"] or ""
        rc = recall(expected, res)
        dups = duplicated_phrases(expected, res)
        lat = r["latency_ms"] if r["latency_ms"] is not None else 10**9
        ok = (r["exit"] == 0 and r["live_ok"] and not r["fell_back"] and not r["rest_called"] and rc >= LONG_MIN_RECALL
              and not dups and lat <= USER_MAX_LATENCY_MS and res.endswith(" "))
        r.update({"id": f"long/{cid}", "model": LIVE_MODEL + "+long", "recall": round(rc, 3), "duplicated": dups,
                  "audio_s": round(secs, 1)})
        report["tests"].append(r)
        report.setdefault("long_mode", []).append({k: r[k] for k in ("id", "audio_s", "recall", "latency_ms", "split_count",
                                                                     "reconnect_count", "live_session_age_s", "live_activities",
                                                                     "peak_rss_mb", "wall_s", "exit", "rotation_count",
                                                                     "planned_close_count")})
        gate(f"T23 long-dictation/{cid}", ok,
             f"audio={secs:.0f}s recall={rc:.3f} (min {LONG_MIN_RECALL}) lat={r['latency_ms']}ms (limit {USER_MAX_LATENCY_MS}ms) "
             f"live_ok={r['live_ok']} fell_back={r['fell_back']} rest_called={r['rest_called']} duplicated={dups[:3]} | "
             f"splits={r['split_count']} reconnects={r['reconnect_count']} rotations={r['rotation_count']}+{r['planned_close_count']} "
             f"live_session_age={r['live_session_age_s']}s "
             f"activities={r['live_activities']} peak_rss={r['peak_rss_mb']}MB wall={r['wall_s']}s exit={r['exit']} "
             f"-> {len(res)} chars {res[:60]!r}..." + ("" if ok else f"\n      tail: {r['tail']}"))

    report["stats"] = stats
    os.makedirs(LOGS, exist_ok=True)
    rpath = os.path.join(LOGS, f"online-{time.strftime('%Y%m%d-%H%M%S')}.json")
    json.dump(report, open(rpath, "w"), indent=2)
    print(f"\n{len(report['gates']) - len(fails)}/{len(report['gates'])} online gates passed. "
          f"stats={json.dumps(stats)} Report: {rpath}")
    if a.update_baseline and not fails:
        nb = dict(base)
        for key, st in stats.items():
            nb[f"online_{key}_mean_recall"] = max(base.get(f"online_{key}_mean_recall", 0), st["mean_recall"])
            if st["median_latency_ms"] is not None:
                nb[f"online_{key}_median_latency_ms"] = min(base.get(f"online_{key}_median_latency_ms", 10**9),
                                                            st["median_latency_ms"])
        json.dump(nb, open(BASELINE, "w"), indent=2)
        print("Online baseline updated.")
    if fails:
        print("FAILED online gates: " + ", ".join(fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
