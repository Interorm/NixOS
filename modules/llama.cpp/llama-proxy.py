"""
Wake-on-demand inference proxy.

Runs on the homeserver.  Fronts the NInfer engine on the NixOS PC: wakes the
machine with WoL, starts `ninfer-serve.service` over SSH, forwards the request,
and puts everything back to sleep once nobody has asked for a token in a while.

Two facts about NInfer drive the whole design and are worth stating up front,
because they are what changed when the PC stopped being a Windows llama.cpp box:

  1. There is NO load/unload API.  The engine holds exactly one model, chosen on
     the command line at startup, for its entire lifetime.  So "unload the model
     but keep the server up" -- the middle rung of the old three-tier idle
     ladder -- is not a thing that exists.  The ladder is now two rungs: stop
     the service (frees the VRAM), then power the machine off.

  2. Control happens through `ninferctl`, a tiny wrapper installed by
     llama-server.nix and allowed for this user via a single NOPASSWD sudo rule.
     We invoke it by its /run/current-system/sw/bin path because sudo matches
     the rule against the string on the command line and does not resolve
     symlinks -- see the comment on security.sudo.extraRules over there.
"""

import asyncio, json, shlex, time
from contextlib import asynccontextmanager
from typing import Literal

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse


# --------------------------------------------------------------------------- #
#  Configuration
# --------------------------------------------------------------------------- #

PC_MAC = 'A0:AD:9F:B1:E5:DB'
PC_IP = '192.168.42.42'

# Lowercase: this is the NixOS user declared in hosts/PC/users.nix, not the old
# Windows "Karl".
PC_USER = 'karl'

# Must stay byte-identical to the Cmnd_Spec in llama-server.nix.
PC_CTL = '/run/current-system/sw/bin/ninferctl'

# `touch` this on the PC to make the proxy back off: it stops the engine and
# refuses requests until the file is gone.  POSIX path now, not
# C:\Users\Karl\.llama-proxy\.
DND_FLAG = f'/home/{PC_USER}/.llama-proxy/dnd.flag'

ENGINE_PORT = '8080'
ENGINE_URL = f'http://{PC_IP}:{ENGINE_PORT}'

# Idle ladder, in seconds.  Expressed as absolute idle time rather than as a
# tick counter: the old code mixed a 60-second poll counter with a 60-second
# grace period in the same comparison, printed them as if they shared a unit,
# and -- because it flipped PC_STATE to 'unknown' at the middle rung while the
# whole ladder was guarded by `PC_STATE == 'ready'` -- could never reach the
# poweroff rung at all.
STOP_ENGINE_AFTER = 10 * 60
POWEROFF_AFTER = 25 * 60

IDLE_POLL = 60          # how often the idle watchdog wakes up
AVAILABILITY_POLL = 30  # how often we re-check reachability / DND

# Boot and load budgets, as (attempts, seconds-between-attempts).
BOOT_POLL = (60, 2)     # 2 min for WoL -> ping answers
ENGINE_POLL = (150, 2)  # 5 min for ninfer-serve to map ~30 GB into VRAM

# NInfer answers to whatever model id it was started with.  We discover that id
# from /v1/models rather than hardcoding it, then reject requests that name a
# different one -- there is no load API, so a mismatch can only ever be a
# client misconfiguration, and failing loudly beats silently answering with the
# wrong model.  Flip to False if your client insists on sending e.g. "gpt-4".
STRICT_MODEL_CHECK = True


# --------------------------------------------------------------------------- #
#  State
# --------------------------------------------------------------------------- #

HTTP_CLIENT: httpx.AsyncClient | None = None
BOOT_LOCK: asyncio.Lock | None = None

LAST_REQUEST_TIME = time.time()
PC_STATE: Literal['unknown', 'ready', 'starting', 'do-not-disturb', 'off'] = 'unknown'

# The model id the running engine reports; None until we have asked it.
SERVED_MODEL: str | None = None

# Only power the machine off if *we* were the ones who woke it.  Without this
# the proxy would happily shut down a PC you booted yourself and are sitting in
# front of, 25 minutes after the last API call.  Lost on proxy restart, which
# fails safe (the machine stays up).
WE_BOOTED_PC = False


class ModelMismatch(Exception):
    """Client asked for a model this engine cannot serve.  A 400, not a 503."""


# --------------------------------------------------------------------------- #
#  Remote control primitives
# --------------------------------------------------------------------------- #

async def send_wol() -> None:
    proc = await asyncio.create_subprocess_exec(
        'wakeonlan', PC_MAC,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    # The original never awaited this, so the magic packet raced with the ping
    # loop that was supposed to observe its effect.
    await proc.wait()


async def ssh(*argv: str) -> tuple[int, str, str]:
    """Run a command on the PC.  Returns (returncode, stdout, stderr).

    BatchMode=yes is the load-bearing option: without it ssh will sit on a
    password prompt forever if key auth breaks, and this coroutine never
    returns.  accept-new (rather than the old `no`) still trusts a first-seen
    host but starts rejecting a changed key afterwards.
    """
    proc = await asyncio.create_subprocess_exec(
        'ssh',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=accept-new',
        f'{PC_USER}@{PC_IP}', *argv,
        stdin=asyncio.subprocess.DEVNULL,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate()
    return proc.returncode, out.decode().strip(), err.decode().strip()


async def ninferctl(verb: str) -> tuple[int, str, str]:
    # `sudo -n` fails immediately instead of prompting, so a broken NOPASSWD
    # rule surfaces as an error rather than a hang.
    return await ssh('sudo', '-n', PC_CTL, verb)


async def start_engine() -> None:
    rc, _, err = await ninferctl('start')
    if rc != 0:
        print(f'[ENGINE] start failed (rc={rc}): {err}')
        return
    # `systemctl start` on a Type=simple unit returns as soon as the process has
    # been forked -- long before ~30 GB of weights are in VRAM.  Readiness is
    # established by polling the HTTP surface, not by this call returning.
    print('[ENGINE] ninfer-serve started, waiting for it to become ready')


async def stop_engine() -> None:
    global SERVED_MODEL

    rc, _, err = await ninferctl('stop')
    SERVED_MODEL = None
    if rc != 0:
        print(f'[ENGINE] stop failed (rc={rc}): {err}')
    else:
        print('[ENGINE] ninfer-serve stopped, VRAM released')


async def poweroff_pc() -> None:
    rc, _, err = await ninferctl('poweroff')
    # systemctl poweroff queues the job and returns, so rc should be 0; a
    # dropped connection as the machine goes down is still a success.
    if rc != 0:
        print(f'[POWER] poweroff returned rc={rc}: {err}')
    print('[POWER] Inference machine powering off')


async def is_dnd_active() -> bool:
    """Owner has claimed the machine.  POSIX `test -e`, not PowerShell."""
    rc, _, _ = await ssh('test', '-e', shlex.quote(DND_FLAG))
    return rc == 0


async def is_pc_reachable() -> bool:
    # Linux ping flags -- this runs on the homeserver, not on the PC.
    proc = await asyncio.create_subprocess_exec(
        'ping', '-c', '1', '-W', '2', PC_IP,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.DEVNULL,
    )
    return await proc.wait() == 0


async def is_engine_running() -> bool:
    """Probe the OpenAI surface and remember which model is loaded.

    NInfer has no /health, but it does serve /v1/models, which doubles as a
    liveness check and as the source of truth for SERVED_MODEL.
    """
    global SERVED_MODEL

    try:
        result = await HTTP_CLIENT.get(f'{ENGINE_URL}/v1/models', timeout=3)
    except Exception:
        return False

    if result.status_code != 200:
        return False

    try:
        data = result.json().get('data', [])
        if data:
            SERVED_MODEL = data[0].get('id')
    except Exception:
        # Alive but unparseable -- still alive, which is what was asked.
        pass

    return True


def check_model(model_id: str | None) -> None:
    if not STRICT_MODEL_CHECK or model_id is None or SERVED_MODEL is None:
        return
    if model_id != SERVED_MODEL:
        raise ModelMismatch(
            f'This engine serves "{SERVED_MODEL}" and cannot switch models at '
            f'runtime; the request asked for "{model_id}".'
        )


# --------------------------------------------------------------------------- #
#  Background loops
# --------------------------------------------------------------------------- #

async def idle_watchdog() -> None:
    global PC_STATE, WE_BOOTED_PC

    while True:
        await asyncio.sleep(IDLE_POLL)

        # 'starting' -- a boot is in flight.  'off' -- nothing to do.
        # 'do-not-disturb' -- the owner is using the machine; never power off a
        # PC someone is sitting in front of.
        if PC_STATE in ('off', 'starting', 'do-not-disturb'):
            continue

        idle = time.time() - LAST_REQUEST_TIME
        if idle < STOP_ENGINE_AFTER:
            continue

        if PC_STATE == 'ready':
            print(f'[IDLE] {int(idle / 60)} min idle, stopping engine')
            await stop_engine()
            PC_STATE = 'unknown'

        if idle >= POWEROFF_AFTER and WE_BOOTED_PC:
            # Re-check live rather than trusting cached state: the owner may
            # have sat down at the machine since the last availability sweep.
            if await is_dnd_active():
                PC_STATE = 'do-not-disturb'
                continue
            print(f'[IDLE] {int(idle / 60)} min idle, powering machine off')
            await poweroff_pc()
            PC_STATE = 'off'
            WE_BOOTED_PC = False


async def check_availability() -> None:
    global PC_STATE

    while True:
        await asyncio.sleep(AVAILABILITY_POLL)

        # Never race the boot sequence: it owns PC_STATE while it runs.
        if PC_STATE == 'starting':
            continue

        if not await is_pc_reachable():
            PC_STATE = 'off'
            continue

        if await is_dnd_active():
            if PC_STATE == 'ready':
                print('[DND] Do-not-disturb flag present, releasing the GPU')
                await stop_engine()
            PC_STATE = 'do-not-disturb'
        elif PC_STATE == 'do-not-disturb':
            PC_STATE = 'unknown'


# --------------------------------------------------------------------------- #
#  Readiness
# --------------------------------------------------------------------------- #

async def ensure_inference_ready(model_id: str | None) -> None:
    global PC_STATE, WE_BOOTED_PC

    # Fast path, no lock: the overwhelmingly common case is "already up".
    if PC_STATE == 'do-not-disturb':
        raise RuntimeError('[DND] Request blocked by the owner of the machine')
    if PC_STATE == 'starting':
        raise RuntimeError('[BUSY] The inference machine is still starting, retry shortly')
    if PC_STATE == 'ready':
        check_model(model_id)
        return

    async with BOOT_LOCK:
        # Double-checked locking: whoever held the lock before us may have
        # finished the whole boot while we were queued.
        if PC_STATE == 'do-not-disturb':
            raise RuntimeError('[DND] Request blocked by the owner of the machine')
        if PC_STATE == 'ready':
            check_model(model_id)
            return

        PC_STATE = 'starting'
        try:
            if not await is_pc_reachable():
                print('[BOOT] Waking the inference machine')
                await send_wol()
                WE_BOOTED_PC = True

                for _ in range(BOOT_POLL[0]):
                    await asyncio.sleep(BOOT_POLL[1])
                    if await is_pc_reachable():
                        break
                else:
                    PC_STATE = 'off'
                    raise RuntimeError('[BOOT] Machine did not come up; Wake-on-LAN unsuccessful')

                print('[BOOT] Machine is up, giving sshd a moment')
                # ping answers before sshd binds; without this the first
                # ninferctl call reliably fails with "connection refused".
                await asyncio.sleep(10)

            if not await is_engine_running():
                await start_engine()
                for _ in range(ENGINE_POLL[0]):
                    await asyncio.sleep(ENGINE_POLL[1])
                    if await is_engine_running():
                        break
                else:
                    raise RuntimeError('[ENGINE] ninfer-serve did not become ready in time')

            print(f'[READY] Engine serving "{SERVED_MODEL}"')
            PC_STATE = 'ready'
        except BaseException:
            # Never leave the state pinned at 'starting': every later request
            # would 503 with "still starting" forever.
            if PC_STATE == 'starting':
                PC_STATE = 'unknown'
            raise

    check_model(model_id)


# --------------------------------------------------------------------------- #
#  App
# --------------------------------------------------------------------------- #

@asynccontextmanager
async def lifespan(app: FastAPI):
    global BOOT_LOCK, HTTP_CLIENT

    print('[SERVICE] Starting llama-proxy')
    BOOT_LOCK = asyncio.Lock()
    HTTP_CLIENT = httpx.AsyncClient(
        limits=httpx.Limits(max_connections=10, max_keepalive_connections=0),
        # httpx defaults to a 5 s read timeout, which is shorter than the
        # prefill of a large context and far shorter than a non-streamed
        # completion.  Long read budget, short connect budget.
        timeout=httpx.Timeout(connect=5.0, read=600.0, write=60.0, pool=10.0),
    )

    tasks = [
        asyncio.create_task(idle_watchdog()),
        asyncio.create_task(check_availability()),
    ]

    yield

    print('[SERVICE] Shutting down llama-proxy')
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

    # Releases the GPU when the proxy goes away.  Note the tradeoff: the module
    # sets restartTriggers on this file, so editing it and rebuilding drops a
    # warm model.  Delete this line if you would rather keep the engine up
    # across proxy restarts and let the idle watchdog collect it later.
    await stop_engine()
    await HTTP_CLIENT.aclose()


app = FastAPI(lifespan=lifespan)


# Registered before the catch-all, because FastAPI matches routes in
# registration order and "/{path:path}" would otherwise swallow this.  Lets you
# inspect the state machine without waking the PC.
@app.get('/proxy/status')
async def proxy_status():
    return {
        'pc_state': PC_STATE,
        'served_model': SERVED_MODEL,
        'idle_seconds': int(time.time() - LAST_REQUEST_TIME),
        'woken_by_proxy': WE_BOOTED_PC,
    }


@app.api_route('/{path:path}', methods=['GET', 'POST', 'DELETE'])
async def proxy(request: Request, path: str):
    global LAST_REQUEST_TIME
    LAST_REQUEST_TIME = time.time()

    body = await request.body()
    headers = dict(request.headers)
    headers.pop('host', None)
    headers.pop('accept-encoding', None)

    model_id = None
    if request.method == 'POST' and body:
        try:
            # Both the OpenAI and the Anthropic surfaces carry the model in a
            # top-level "model" field, so one parse covers /v1/chat/completions,
            # /v1/responses and /v1/messages alike.
            model_id = json.loads(body).get('model')
        except Exception:
            pass

    try:
        await ensure_inference_ready(model_id)
    except ModelMismatch as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=503, detail=str(e))

    req = HTTP_CLIENT.build_request(
        method=request.method,
        url=f'{ENGINE_URL}/{path}',
        headers=headers,
        content=body,
        params=request.query_params,
    )
    resp = await HTTP_CLIENT.send(req, stream=True)

    async def body_iterator():
        try:
            async for chunk in resp.aiter_raw():
                yield chunk
        finally:
            await resp.aclose()

    response_headers = {
        k: v for k, v in resp.headers.items()
        if k.lower() not in ('content-length', 'transfer-encoding', 'connection', 'content-encoding')
    }

    return StreamingResponse(
        body_iterator(),
        status_code=resp.status_code,
        headers=response_headers,
        media_type=resp.headers.get('content-type'),
    )


if __name__ == '__main__':
    uvicorn.run(app, host='0.0.0.0', port=8090)
