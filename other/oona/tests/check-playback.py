#!/usr/bin/env python3
"""Exercise an explicitly launched test player's mpv IPC socket (not user sessions)."""
import argparse
import json
from pathlib import Path
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument('socket')
parser.add_argument('--sdr', type=Path)
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()

client = socket.socket(socket.AF_UNIX)
client.settimeout(10)
client.connect(args.socket)
stream = client.makefile('rb')
request_id = 0


def command(*args):
    global request_id
    request_id += 1
    client.sendall((json.dumps({'command': args, 'request_id': request_id}) + '\n').encode())
    while True:
        reply = json.loads(stream.readline())
        if reply.get('request_id') == request_id:
            assert reply['error'] == 'success', reply
            return reply.get('data')


def get(name):
    return command('get_property', name)


def wait_position(minimum, maximum, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = get('time-pos')
        if minimum <= value <= maximum:
            return value
        time.sleep(0.1)
    raise AssertionError(f'Playback did not reach {minimum}..{maximum}: {value}')


original = get('path')
print('renderer:', get('current-vo'), 'decoder:', get('hwdec-current'))
print('source:', get('video-params'))
# Fail rather than silently fixing mute: persisted test settings must be detected.
assert not get('mute'), 'Audio is muted (check the file watch-later record)'
assert get('volume') > 0, 'Audio volume is zero'
assert get('aid') is not False, 'No audio track selected'
assert get('current-ao') in ('coreaudio', 'avfoundation'), 'No real audio output'
print('audio:', get('current-ao'), get('audio-device'), get('audio-out-params'))
command('set_property', 'pause', False)
start = get('time-pos')
time.sleep(2)
assert get('time-pos') > start + 1, 'Playback stalled'
assert get('audio-pts') is not None, 'Audio timestamps unavailable'
print('PASS: real audio output, unmuted nonzero volume, active audio timestamps')
command('set_property', 'pause', True)
time.sleep(0.2)
paused = get('time-pos')
time.sleep(0.5)
assert abs(get('time-pos') - paused) < 0.1, 'Pause failed'
command('seek', 30, 'absolute+exact')
wait_position(29.9, 30.1)
command('set_property', 'pause', False)
wait_position(31, 34)
command('seek', 90, 'absolute+exact')
wait_position(90, 94)
command('set_property', 'pause', True)
print('PASS: progress, pause, backward seek, resume, forward seek')
if args.output_dir:
    args.output_dir.mkdir(parents=True, exist_ok=True)
    image = args.output_dir.resolve() / 'app-dv.png'
    command('screenshot-to-file', str(image), 'video')
    assert image.stat().st_size > 1000
    command('set_property', 'sid', 2)
    # Wait for subtitle decoder startup before sampling the rendered overlay.
    time.sleep(1)
    image = args.output_dir.resolve() / 'app-dv-subs.png'
    command('screenshot-to-file', str(image), 'subtitles')
    assert image.stat().st_size > 1000
    print('PASS: video and subtitle screenshots without crash')
if args.sdr:
    command('loadfile', str(args.sdr.resolve()))
    time.sleep(1)
    command('set_property', 'pause', False)
    start = get('time-pos')
    time.sleep(2)
    assert get('time-pos') > start + 1
    assert get('video-params/colormatrix') != 'dolbyvision'
    print('PASS: DV to SDR transition:', get('video-params/colormatrix'))
    command('loadfile', original)
    time.sleep(1)
    command('seek', 60, 'absolute+exact')
    command('set_property', 'pause', False)
    wait_position(61, 64)
    assert get('video-params/colormatrix') == 'dolbyvision'
    command('set_property', 'pause', True)
    print('PASS: SDR to DV transition')
stream.close()
client.close()
