#!/usr/bin/env python3
"""Overrun one sample's last NAL length field, the way a damaged remux carries it (AE#561).

No encoder writes this file for you. A reporter's Blu-ray remux carried HEVC packets whose last
length prefix declared 384137139 bytes with 350873 left in the packet, and the shape matters
because the two consumers answer it differently: libavcodec logs "Invalid NAL unit size" and skips
the frame, so the file plays in mpv, while Apple's fMP4 parser answers the whole SEGMENT with
CoreMediaErrorDomain -19602, which ends the session and every reload onto that segment. MKVToolNix
drops the unparsable tail on remux, which is why remuxing such a file fixes it.

The patch is four bytes wide and moves nothing else: same file size, same block boundaries, same
timestamps, so the healthy source is a true control arm rather than a second encode.

    # several NALs per packet, so the truncation leaves a picture behind rather than nothing
    ffmpeg -f lavfi -i testsrc=size=1280x720:rate=25:duration=8 -c:v libx265 -preset ultrafast \\
           -x265-params "bframes=3:keyint=50:slices=4:aud=1:log-level=0" -pix_fmt yuv420p healthy.mkv
    python3 Scripts/nal-overrun-fixture.py healthy.mkv damaged.mkv

    aetherctl play --seconds 14 file://$PWD/healthy.mkv    # control: VERDICT: OK
    aetherctl play --seconds 14 file://$PWD/damaged.mkv    # before the fix: -19602 at once

Works on any mp4/mkv whose video track is length-prefixed (avcC / hvcC framing); Annex B sources
carry no length fields to overrun and are rejected here.
"""
import argparse
import shutil
import struct
import subprocess
import sys

# The reporter's own impossible length, kept verbatim so a log line from the fixture and one from
# the field read the same.
OVERRUN_LENGTH = 0x16E577B3


def packet_rows(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v", "-show_packets",
         "-show_entries", "packet=pts_time,size,pos", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True).stdout.strip().split("\n")
    rows = []
    for line in out:
        pts, size, pos = line.split(",")[:3]
        if pos == "N/A" or size == "N/A":
            continue
        rows.append((float(pts) if pts != "N/A" else 0.0, int(size), int(pos)))
    return rows


def chain(blob):
    """The NAL lengths in `blob`, or None when it is not a clean length-prefixed run."""
    offset, units = 0, []
    while offset + 4 <= len(blob):
        length = struct.unpack(">I", blob[offset:offset + 4])[0]
        if length == 0 or offset + 4 + length > len(blob):
            return None
        units.append((offset, length))
        offset += 4 + length
    return units if offset == len(blob) else None


def locate_payload(data, pos, size):
    """ffprobe reports the element's position, not the frame's; the payload sits a few bytes in."""
    for delta in range(-8, 40):
        units = chain(data[pos + delta:pos + delta + size])
        if units:
            return pos + delta, units
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("destination")
    ap.add_argument("--after", type=float, default=3.0,
                    help="patch the first eligible packet past this presentation time (s)")
    ap.add_argument("--min-units", type=int, default=2,
                    help="how many NAL units the packet must hold, so the cut leaves something")
    args = ap.parse_args()

    data = open(args.source, "rb").read()
    for pts, size, pos in packet_rows(args.source):
        if pts < args.after:
            continue
        payload, units = locate_payload(data, pos, size)
        if units and len(units) >= args.min_units:
            break
    else:
        sys.exit("no length-prefixed packet with %d units past %.3fs (Annex B source?)"
                 % (args.min_units, args.after))

    last_offset, last_length = units[-1]
    shutil.copyfile(args.source, args.destination)
    with open(args.destination, "r+b") as handle:
        handle.seek(payload + last_offset)
        handle.write(struct.pack(">I", OVERRUN_LENGTH))

    print("packet pts=%.3fs size=%d units=%s" % (pts, size, [n for _, n in units]))
    print("last length %d -> %d, with %d bytes left in the packet"
          % (last_length, OVERRUN_LENGTH, size - last_offset - 4))


if __name__ == "__main__":
    main()
