#!/usr/bin/env python3
"""Real Codex voice smoke test. Requires macOS say, ffmpeg, Python aiortc==1.13.0.

Uses a disposable directory/thread and synthetic speech, never a microphone.
No Platform keys, OAuth tokens, SDP or auth headers are printed or persisted.
Exit 0 requires spoken input, an actual Codex file read, and audible spoken output.
"""
import argparse
import asyncio
import fractions
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import wave

from aiortc import AudioStreamTrack, RTCPeerConnection, RTCSessionDescription
from av import AudioFrame


def sanitize(value):
    text = str(value)
    try:
        error = json.loads(text).get("error", {})
        text = f"{error.get('code', 'backend_error')}: {error.get('message', 'Call rejected')}"
    except (ValueError, AttributeError):
        pass
    for pattern in (r"(?i)Bearer\s+[^\s\"<>]+", r"eyJ[A-Za-z0-9_.-]+", r"sk-[A-Za-z0-9_-]+"):
        text = re.sub(pattern, "[redacted]", text)
    if "<html" in text.lower() or "<!doctype" in text.lower():
        text = "Unexpected HTTP response from the voice backend"
    return text[:1800]


class SpeechTrack(AudioStreamTrack):
    def __init__(self, path):
        super().__init__()
        with wave.open(str(path), "rb") as wav:
            assert (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) == (48000, 1, 2)
            self.pcm = wav.readframes(wav.getnframes())
        self.samples = 0
        self.started = None
        self.speech_frames = 0

    async def recv(self):
        if self.started is None:
            self.started = time.monotonic()
        await asyncio.sleep(max(0, self.started + self.samples / 48000 - time.monotonic()))
        offset = (self.samples - 48000) * 2  # One second of leading silence.
        pcm = self.pcm[offset:offset + 1920] if offset >= 0 else b""
        if any(pcm):
            self.speech_frames += 1
        frame = AudioFrame(format="s16", layout="mono", samples=960)
        frame.planes[0].update(pcm.ljust(1920, b"\0"))
        frame.sample_rate, frame.pts, frame.time_base = 48000, self.samples, fractions.Fraction(1, 48000)
        self.samples += 960
        return frame


async def verify(codex, root, report):
    environment = dict(os.environ)
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "AZURE_OPENAI_API_KEY", "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"):
        environment.pop(key, None)
    version = subprocess.run([codex, "--version"], env=environment, check=True, capture_output=True, text=True).stdout.strip()
    report.update(codexVersion=version, client="nocturne", platformKeysPresent=False, inheritedIdentityOverride=False)
    proc = await asyncio.create_subprocess_exec(codex, "app-server", cwd=root, env=environment,
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, limit=2 * 1024 * 1024)
    peer = RTCPeerConnection()
    speech = SpeechTrack(root / "speech.wav")
    peer.addTrack(speech)
    channel = peer.createDataChannel("oai-events")
    pending, serial = {}, 0
    thread, failure = None, None
    answer = asyncio.get_running_loop().create_future()
    evidence = dict(userTranscribed=False, fileRead=False, agentCompleted=False, agentAnswer=False, spokenAnswer=False)
    inbound_frames, audible_frames = 0, 0
    media_tasks = []

    def log(phase):
        print(json.dumps({"phase": phase}), flush=True)

    async def write(value):
        proc.stdin.write((json.dumps(value) + "\n").encode())
        await proc.stdin.drain()

    async def call(method, params, timeout=45):
        nonlocal serial
        serial += 1
        future = asyncio.get_running_loop().create_future()
        pending[serial] = future
        await write({"id": serial, "method": method, "params": params})
        response = await asyncio.wait_for(future, timeout)
        if "error" in response:
            raise RuntimeError(sanitize(json.dumps(response["error"])))
        return response.get("result", {})

    async def read():
        nonlocal failure
        while line := await proc.stdout.readline():
            value = json.loads(line)
            if "id" in value and "method" not in value:
                future = pending.pop(value["id"], None)
                if future and not future.done():
                    future.set_result(value)
                continue
            method, params = value.get("method"), value.get("params", {})
            if "id" in value:
                # The disposable read should need no elevated/interactive approval.
                failure = "The verification task requested an unexpected interactive action"
                await write({"id": value["id"], "error": {"code": -32601, "message": failure}})
                continue
            if params.get("threadId") != thread:
                continue
            if method == "thread/realtime/sdp" and not answer.done():
                answer.set_result(params["sdp"])
            elif method == "thread/realtime/error":
                failure = sanitize(params.get("message", "Voice failed"))
                if not answer.done():
                    answer.set_exception(RuntimeError(failure))
            elif method == "thread/realtime/transcript/done":
                text = params.get("text", "").lower()
                if params.get("role") == "user" and "voice-probe" in text:
                    evidence["userTranscribed"] = True
                if params.get("role") == "assistant" and re.search(r"427|four[ -]+two[ -]+seven|four hundred(?: and)? twenty[ -]+seven", text):
                    evidence["spokenAnswer"] = True
            elif method == "item/completed":
                item = params.get("item", {})
                if item.get("type") == "commandExecution" and "427" in item.get("aggregatedOutput", ""):
                    evidence["fileRead"] = True
                if item.get("type") == "agentMessage" and "427" in item.get("text", ""):
                    evidence["agentAnswer"] = True
            elif method == "turn/completed" and params.get("turn", {}).get("status") == "completed":
                evidence["agentCompleted"] = True
        if not answer.done():
            answer.set_exception(RuntimeError("Codex App Server exited before answering"))

    @peer.on("track")
    def track_received(track):
        async def consume():
            nonlocal inbound_frames, audible_frames
            while True:
                try:
                    frame = await track.recv()
                    inbound_frames += 1
                    if abs(frame.to_ndarray()).max() > 100:
                        audible_frames += 1
                except Exception:
                    return
        media_tasks.append(asyncio.create_task(consume()))

    reader = asyncio.create_task(read())
    try:
        await call("initialize", {"clientInfo": {"name": "nocturne", "title": "Nocturne", "version": "1.0"}, "capabilities": {"experimentalApi": True}})
        await write({"method": "initialized"})
        account = await call("account/read", {"refreshToken": False})
        report["accountType"] = (account.get("account") or {}).get("type")
        if report["accountType"] != "chatgpt":
            raise RuntimeError("Codex-managed ChatGPT sign-in required; no API-key fallback")
        settings = (await call("config/read", {"includeLayers": False, "cwd": str(root)})).get("config", {})
        provider = settings.get("model_providers", {}).get("openai", {})
        headers = {name.lower() for field in ("http_headers", "env_http_headers") for name in (provider.get(field) or {})}
        if any(provider.get(field) is not None for field in ("env_key", "experimental_bearer_token", "auth", "aws")) or headers.intersection({"authorization", "api-key", "x-api-key"}):
            raise RuntimeError("Remove custom API-key authentication from Codex's OpenAI provider first")
        report["customProviderAuthPresent"] = False
        log("chatgpt-signed-in")
        result = await call("thread/start", {"cwd": str(root), "ephemeral": True, "modelProvider": "openai", "approvalPolicy": "on-request", "sandbox": "workspace-write"})
        thread = result["thread"]["id"]
        await peer.setLocalDescription(await peer.createOffer())
        await call("thread/realtime/start", {"threadId": thread, "version": "v3", "outputModality": "audio", "transport": {"type": "webrtc", "sdp": peer.localDescription.sdp}, "voiceSessionId": "nocturne-webrtc-verification"})
        await peer.setRemoteDescription(RTCSessionDescription(sdp=await asyncio.wait_for(answer, 35), type="answer"))
        log("sdp-answer-applied")
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if failure:
                raise RuntimeError(failure)
            if all(evidence.values()) and audible_frames >= 50 and channel.readyState == "open":
                break
            if peer.connectionState in ("failed", "closed"):
                raise RuntimeError("WebRTC media connection failed")
            await asyncio.sleep(.25)
        stats = await peer.getStats()
        report.update(evidence, peerState=peer.connectionState, dataChannel=channel.readyState,
            outboundSpeechFrames=speech.speech_frames, inboundAudioFrames=inbound_frames, audibleFrames=audible_frames,
            packetsSent=sum(getattr(s, "packetsSent", 0) for s in stats.values() if s.type == "outbound-rtp"),
            packetsReceived=sum(getattr(s, "packetsReceived", 0) for s in stats.values() if s.type == "inbound-rtp"))
        if not all(evidence.values()) or audible_frames < 50 or peer.connectionState != "connected":
            raise RuntimeError("Incomplete voice/agent evidence; see report flags")
        report["result"] = "passed"
    finally:
        if thread:
            try:
                await call("thread/realtime/stop", {"threadId": thread}, 5)
            except Exception:
                pass
        await peer.close()
        for task in media_tasks + [reader]:
            task.cancel()
        if proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), 3)
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = {"result": "failed", "physicalMicrophoneTested": False, "physicalBackgroundTested": False}
    try:
        if not args.codex:
            raise RuntimeError("Install Codex and sign in with ChatGPT first")
        with tempfile.TemporaryDirectory(prefix="nocturne-webrtc-") as temporary:
            root = Path(temporary)
            (root / "voice-probe.txt").write_text("Nocturne voice verification 427.\n")
            sentence = "Hello. Please ask Codex to read the file voice-probe dot txt in the current directory, and tell me the exact verification number from that file. Please actually read the file using Codex."
            subprocess.run(["say", "-v", "Samantha", "-o", str(root / "speech.aiff"), sentence], check=True, capture_output=True)
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(root / "speech.aiff"), "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(root / "speech.wav")], check=True, capture_output=True)
            asyncio.run(verify(args.codex, root, report))
    except Exception as error:
        report["error"] = sanitize(error)
    output = json.dumps(report, indent=2) + "\n"
    print(output, end="")
    if args.report:
        args.report.write_text(output)
    return 0 if report["result"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
