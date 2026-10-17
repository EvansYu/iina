#!/usr/bin/env python3
"""Compare actual framebuffer output with/without FLIP_Y, including subtitles.

Requires ffmpeg and Pillow; builds a static letterboxed sample to avoid timing
noise. This deliberately does not use mpv's separate screenshot render path.
"""
import argparse
from pathlib import Path
import subprocess
from PIL import Image, ImageChops, ImageStat

parser = argparse.ArgumentParser()
parser.add_argument('probe', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
sample = args.output / 'orientation.mp4'
subtitle = args.output / 'orientation.srt'
subtitle.write_text('1\n00:00:00,000 --> 00:01:40,000\nSubtitle ABC 123 left -> RIGHT\n')
subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
                '-f', 'lavfi', '-i', 'testsrc2=size=640x272:rate=24:duration=0.042',
                '-vf', 'tpad=stop_mode=clone:stop_duration=100', '-t', '100',
                '-c:v', 'libx264', '-preset', 'ultrafast', str(sample)], check=True)
images = []
for flip in (0, 1):
    output = args.output / f'flip{flip}.ppm'
    with (args.output / f'flip{flip}.log').open('w') as log:
        subprocess.run([str(args.probe.resolve()), str(sample), str(output),
                        'no', str(flip), str(subtitle)], check=True,
                       stdout=log, stderr=log, timeout=30)
    image = Image.open(output).convert('RGB')
    image.save(args.output / f'flip{flip}.png')
    images.append(image)
error = ImageStat.Stat(ImageChops.difference(*images)).mean
print('Normalized framebuffer RGB MAE:', error)
assert max(error) < 0.5, 'Video/subtitle orientation differs under FLIP_Y'
print('PASS: letterboxed video and subtitles share output orientation')
