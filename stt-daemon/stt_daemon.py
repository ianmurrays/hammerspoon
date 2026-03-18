#!/usr/bin/env python3
"""TCP daemon for speech-to-text using parakeet-mlx.

Holds the Parakeet model in memory. Records audio on command,
transcribes the full recording on stop, returns the result.

Protocol:
  Server -> Client: {"type": "ready"}
  Client -> Server: {"cmd": "start"|"stop"|"status"|"quit"}
  Server -> Client: {"type": "transcribing"}
  Server -> Client: {"type": "final", "text": "...", "wav_path": "..."|null}
  Server -> Client: {"type": "error", "message": "...", "wav_path": "..."|null}
  Server -> Client: {"type": "status", "model_loaded": bool, "recording": bool}
"""

import json
import os
import socket
import sys
import tempfile
import threading
import time
import wave

import mlx.core as mx
import numpy as np
import sounddevice as sd
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

# Globals
model = None
sample_rate = None


def send_json(conn, obj):
    """Send a JSON message followed by newline."""
    try:
        conn.sendall((json.dumps(obj) + "\n").encode())
    except (BrokenPipeError, ConnectionResetError, OSError):
        pass


def write_temp_wav(audio_array, sr):
    """Save audio to a temp WAV file. Returns path or None on failure."""
    try:
        fd, path = tempfile.mkstemp(suffix=".wav", prefix="stt-")
        os.close(fd)
        samples = (audio_array * 32767).clip(-32768, 32767).astype(np.int16)
        with wave.open(path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(int(sr))
            wf.writeframes(samples.tobytes())
        size_kb = os.path.getsize(path) / 1024
        print(f"Saved temp WAV: {path} ({size_kb:.0f} KB)", file=sys.stderr)
        return path
    except Exception as e:
        print(f"Failed to save WAV: {e}", file=sys.stderr)
        return None


def recording_session(conn, stop_event):
    """Record audio until stop, then transcribe and send result."""
    try:
        dev = sd.query_devices(kind="input")
        print(
            f"Input device: {dev['name']}, sr={dev['default_samplerate']}, "
            f"ch={dev['max_input_channels']}",
            file=sys.stderr,
        )
    except Exception as e:
        print(f"Could not query input device: {e}", file=sys.stderr)

    audio_chunks = []
    first_logged = False
    last_rms_log = 0.0

    def audio_callback(indata, frames, time_info, status):
        nonlocal first_logged, last_rms_log
        if status:
            print(f"Audio status: {status}", file=sys.stderr)
        if stop_event.is_set():
            return
        chunk = indata[:, 0].copy()
        audio_chunks.append(chunk)

        if not first_logged:
            print(
                f"First audio chunk: shape={chunk.shape}, dtype={chunk.dtype}",
                file=sys.stderr,
            )
            first_logged = True

        now = time.monotonic()
        if now - last_rms_log >= 1.0:
            rms = float(np.sqrt(np.mean(chunk**2)))
            print(
                f"Audio RMS: {rms:.6f} (peak={float(np.max(np.abs(chunk))):.4f})",
                file=sys.stderr,
            )
            last_rms_log = now

    try:
        with sd.InputStream(
            samplerate=sample_rate,
            channels=1,
            dtype="float32",
            callback=audio_callback,
            blocksize=int(sample_rate * 0.1),
        ):
            while not stop_event.is_set():
                time.sleep(0.1)
    except Exception as e:
        print(f"Mic error: {e}", file=sys.stderr)
        send_json(conn, {"type": "error", "message": f"Mic error: {e}"})
        return

    if not audio_chunks:
        send_json(conn, {"type": "final", "text": ""})
        return

    audio = np.concatenate(audio_chunks)
    duration = len(audio) / sample_rate
    print(f"Recorded {duration:.1f}s of audio, transcribing...", file=sys.stderr)

    wav_path = write_temp_wav(audio, sample_rate)
    send_json(conn, {"type": "transcribing"})

    try:
        audio_mx = mx.array(audio)
        mel = get_logmel(audio_mx, model.preprocessor_config)
        results = model.generate(mel)
        text = results[0].text if results else ""
        print(f"Result: '{text[:200]}'", file=sys.stderr)
        send_json(conn, {"type": "final", "text": text, "wav_path": wav_path})
    except Exception as e:
        print(f"Transcription error: {e}", file=sys.stderr)
        send_json(conn, {"type": "error", "message": str(e), "wav_path": wav_path})


def handle_client(conn, addr):
    """Handle a single client connection."""
    print(f"Client connected: {addr}", file=sys.stderr)
    conn.settimeout(1.0)
    send_json(conn, {"type": "ready"})

    stop_event = threading.Event()
    recording_thread = None
    buffer = ""

    try:
        while True:
            try:
                data = conn.recv(4096)
            except (socket.timeout, TimeoutError):
                continue
            if not data:
                break

            buffer += data.decode()
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                if not line:
                    continue

                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    send_json(conn, {"type": "error", "message": "Invalid JSON"})
                    continue

                cmd = msg.get("cmd")
                print(f"Received command: {cmd}", file=sys.stderr)

                if cmd == "start":
                    if recording_thread and recording_thread.is_alive():
                        send_json(
                            conn, {"type": "error", "message": "Already recording"}
                        )
                        continue
                    stop_event.clear()
                    recording_thread = threading.Thread(
                        target=recording_session,
                        args=(conn, stop_event),
                        daemon=True,
                    )
                    recording_thread.start()

                elif cmd == "stop":
                    print("Setting stop_event...", file=sys.stderr)
                    stop_event.set()
                    if recording_thread:
                        print("Joining recording thread...", file=sys.stderr)
                        recording_thread.join(timeout=30)
                        print("Recording thread done", file=sys.stderr)
                        recording_thread = None

                elif cmd == "status":
                    send_json(
                        conn,
                        {
                            "type": "status",
                            "model_loaded": model is not None,
                            "recording": recording_thread is not None
                            and recording_thread.is_alive(),
                        },
                    )

                elif cmd == "quit":
                    stop_event.set()
                    if recording_thread:
                        recording_thread.join(timeout=30)
                    return

    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        stop_event.set()
        if recording_thread and recording_thread.is_alive():
            recording_thread.join(timeout=30)
        try:
            conn.close()
        except OSError:
            pass
        print(f"Client disconnected: {addr}", file=sys.stderr)


def main():
    global model, sample_rate

    print("Loading parakeet-mlx model...", file=sys.stderr)
    try:
        model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v3")
        sample_rate = model.preprocessor_config.sample_rate
    except Exception as e:
        print(f"Failed to load model: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Model loaded (sample_rate={sample_rate})", file=sys.stderr)

    host, port = "127.0.0.1", 9876
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen(1)

    print(f"Listening on {host}:{port}", file=sys.stderr)

    try:
        while True:
            conn, addr = server.accept()
            handle_client(conn, addr)
    except KeyboardInterrupt:
        print("\nShutting down...", file=sys.stderr)
    finally:
        server.close()


if __name__ == "__main__":
    main()
