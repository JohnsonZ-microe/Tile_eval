"""Vector generation for rev4 (model/vectors.py).

Builds unit vectors (tb_math_v4) and full tile scenarios (tb_tile_v4) from
the golden reference, writing text files into <outdir>. Deterministic under
--seed. Writes: math.txt, rram.hex, flits.txt, expect.txt, checks.json.
"""
import argparse
import json
import random
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tile_reference import (TileRef, act_v41, e4m3_decode, e4m3_encode,  # noqa: E402
                            fmul, quantize_block, sigmoid, widen)
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tile_reference import fp_value  # noqa: E402

CTX_BASE = 64  # rev4 test image places the first expert at word 64


def make_ctx_words(fmt, base, bias_en=False):
    sfmt = 3 if fmt == 5 else (2 if fmt == 2 else (1 if fmt in (3, 4) else 0))
    act = [0x3F800000, 0xFF800000, 0x41200000, 0xC1200000,
           0x41200000, 0, 0, 0]
    return [5120 | (160 << 16), 36 | (2304 << 16),
            (fmt & 7) | ((sfmt & 3) << 3) | ((1 << 5) if fmt in (2, 3) else 0)
            | ((1 << 6) if bias_en else 0) | (0 << 7) | (0 << 8),
            1, base, 0, 0, 0] + act


def make_bias_tail(rng, image, base, count=3):
    """Bias tail words: gate(36) up(36) down(80) BF16, 64 entries/word.
    Finite values only (exp field < 0x7F) so no inf/NaN enters ACT/y."""
    for w in range(count):
        word = 0
        for j in range(64):
            e = 64 * w + j
            if e < 152:
                mag = rng.randrange(0, 0x3000)      # small finite magnitudes
                code = mag | (rng.choice([0, 1]) << 15)
                word |= code << (16 * j)
        image[base + w] = word
    return count


def make_image(rng, fmt, count_words):
    image = {}
    w = 4 if fmt in (0, 4) else (16 if fmt == 5 else 8)
    for a in range(count_words):
        v = 0
        for i in range(1024 // w):
            if fmt in (1, 2, 3):
                code = rng.randrange(0, 127)          # legal E4M3 (no NaN)
            elif fmt == 0:
                code = rng.randrange(0, 16)
            elif fmt == 4:
                code = rng.randrange(0, 16)
            else:
                code = rng.randrange(0, 1 << 16) & 0x7FFF if rng.random() < 0.9 \
                    else rng.randrange(0, 1 << 16)
            v |= code << (w * i)
        image[a] = v
    return image


def scale_entry(rng, fmt):
    if fmt in (0, 1):
        return rng.randrange(120, 135)
    if fmt == 2:
        return 0x3F000000 | rng.randrange(0, 1 << 23)
    return 0x3F00 | rng.randrange(0, 128)          # 16-bit BF16 code


def make_stream(rng, ref, base, nkb, ngroups, cols):
    """Build the RRAM image for one phase following the rev4 layout."""
    words = []
    kb = 0
    while kb < nkb:
        if ref.sw and kb % ref.period == 0:
            for _ in range(ref.sw):
                word = 0
                eper = 1024 // ref.wbits
                for col in range(cols):
                    if col // eper >= ref.sw:
                        continue
                    e = scale_entry(rng, ref.fmt)
                    word |= e << (ref.wbits * (col % eper))
                words.append(word)
        for _ in range(ngroups):
            words.append(make_image_word(rng, ref.fmt))
        kb += 1
    for off, word in enumerate(words):
        ref.image[base + off] = word
    return len(words)


def make_image_word(rng, fmt):
    w = 4 if fmt in (0, 4) else (16 if fmt == 5 else 8)
    v = 0
    for i in range(1024 // w):
        if fmt in (1, 2, 3):
            code = rng.randrange(0, 127)
        elif fmt == 5:
            code = rng.randrange(0, 1 << 16) & 0x7FFF
        else:
            code = rng.randrange(0, 16)
        v |= code << (w * i)
    return v


def build_pass(rng, fmt, n_tok, pass_id, base, expert=0):
    """One GU+D pass: returns (cmd fields, flit list builder info)."""
    ref = TileRef({}, fmt)
    weights = [0x3F800000 | rng.randrange(0, 1 << 20) for _ in range(4)]
    slots = [expert * 4 + l for l in range(4)]
    make_stream(rng, ref, base, 160, ref.ng_gu, 72)
    make_stream(rng, ref, base + ref.gu_words, 72, ref.ng_d, 80)
    return dict(ref=ref, base=base, n_tok=n_tok, pass_id=pass_id,
                weights=weights, slots=slots, fmt=fmt)


def unit_vectors(rng, out):
    lines = []
    # fmul: random + corner pairs vs the mirror (also vs oracle in the test)
    corners = [0, 0x80000000, 0x3F800000, 0x7F800000, 0xFF800000, 0x7FC00000,
               0x00800000, 0x00000001, 0x7F7FFFFF, 0x3FC00000, 0x40490FDB]
    pairs = [(rng.randrange(0, 1 << 32), rng.randrange(0, 1 << 32))
             for _ in range(300)]
    pairs += [(a, b) for a in corners for b in corners]
    for a, b in pairs:
        lines.append('FM %08x %08x %08x' % (a, b, fmul(a, b)))
    # act: random gate/up pairs (FP32 magnitudes) + clamp corners, 4 lanes/line
    ten = 0x41200000
    samples = [(rng.randrange(0, 1 << 32) & 0x7FFFFFFF)
               | (rng.choice([0, 1]) << 31) for _ in range(800)]
    samples += [0, 0x80000000, ten, ten + 1, ten - 1, 0xC1200000,
                0x411FFFFF, 0x7F800000, 0xFF800000, 0x41200080]
    idx = 0
    for _ in range(240):
        gp = up = wp = hp = 0
        for lane in range(4):
            g = samples[(idx + 2 * lane) % len(samples)]
            u = samples[(idx + 2 * lane + 1) % len(samples)]
            w = 0x3F800000 if rng.random() < 0.5 else \
                0x3F000000 | rng.randrange(0, 1 << 20)
            gp |= g << (32 * lane)
            up |= u << (32 * lane)
            wp |= w << (32 * lane)
            hp |= act_v41(g, u, w) << (16 * lane)
        idx = (idx + 9) % len(samples)
        lines.append('AC %032x %032x %032x %016x' % (gp, up, wp, hp))
    # quantizer: random BF16 blocks + specials
    for t in range(200):
        codes = [rng.randrange(0, 1 << 16) & 0x7FBF for _ in range(32)]
        q, se = quantize_block(codes)
        lines.append('QU %s %s %02x' % (''.join('%04x' % c for c in codes),
                                        ''.join('%02x' % c for c in q), se))
    for codes in [[0x7F80] * 4 + [0] * 28, [0xFF80] * 32,
                  [0x7FC0, 0, 0x3F80, 0x4000] + [0] * 28,
                  [0] * 32, [0x0001] * 32]:
        q, se = quantize_block(codes)
        lines.append('QU %s %s %02x' % (''.join('%04x' % c for c in codes),
                                        ''.join('%02x' % c for c in q), se))
    # sigmoid: sampled codes incl. specials
    sg = set([0x0000, 0x8000, 0x7F80, 0xFF80, 0x7FC0, 0x3F80, 0xBF80,
              0x4120, 0x4220])
    while len(sg) < 2000:
        sg.add(rng.randrange(0, 1 << 16))
    for c in sorted(sg):
        lines.append('SG %04x %08x' % (c, sigmoid(c)))
    (out / 'math.txt').write_text('\n'.join(lines) + '\n')
    return len(lines)


def cmd_payload(phase, n_tok, base, hbank, ybank, slots, weights, step_id):
    p = phase & 3
    p |= 7 << 2                       # visit slot
    p |= 0 << 9                       # class routed
    p |= 0 << 11                      # CTX0
    p |= 0 << 12                      # virtual index 0
    p |= 1 << 20                      # first
    p |= 1 << 21                      # last
    p |= (base & 0x1FFFFF) << 22
    p |= (n_tok & 7) << 43
    p |= (ybank & 1) << 46
    p |= (hbank & 1) << 47
    p |= 1 << 48                      # STEP_BEGIN
    p |= 1 << 49                      # STEP_END
    for l in range(4):
        p |= (slots[l] & 0x3F) << (96 + 40 * l)
        p |= (weights[l] & 0xFFFFFFFF) << (102 + 40 * l)
    p |= (step_id & 0xFFFFFFFF) << 256
    return p


def dn_line(kind, pass_id, lane, idx, payload):
    types = {'CMD': 0, 'X': 1, 'XS': 2, 'H': 3, 'CTRL': 4, 'PGM': 5}
    sb = (types[kind] & 7) | ((pass_id & 0xFF) << 3) \
        | ((lane & 7) << 11) | ((idx & 0x3FF) << 14)
    return 'D %d %08x %0128x' % (sb, 0, payload & ((1 << 512) - 1))


def ctrl_line(pass_id, op, addr, data):
    payload = (op & 0xF) | (0x7F << 4) | ((addr & 0xFFF) << 11) \
        | ((data & 0xFFFFFFFF) << 23)
    return dn_line('CTRL', pass_id, 0, 0, payload)


def initial_numeric_alarm(staging, pass_id):
    invalid = any(((word >> (8 * byte)) & 0x7f) == 0x7f
                  for word in staging['x'].values() for byte in range(64))
    if not invalid:
        raise ValueError('Tile error scenario requires a reserved activation '
                         'in the first GU; no NUMERIC alarm may be assumed')
    return dict(type=2, tag=0xF3, last=True, segment=0,
                payload=(pass_id << 40) | (18 << 32) | (1 << 18))


def build_scenarios(rng, out):
    """Full-loop scenarios: six formats x n_tok {1,4}, then error flits."""
    flits = []
    expect = []
    checks = {'errors': [], 'sync1_gu': 0, 'sync1_d': 0}
    image = {}
    n_scen = 0
    for fmt in range(6):
        for n_tok in (1, 4):
            base = 64 + n_scen * 8192
            bias_en = (n_scen % 2 == 0)          # even scenarios run bias
            ref = TileRef(image, fmt, bias_en)
            make_stream(rng, ref, base, 160, ref.ng_gu, 72)
            make_stream(rng, ref, base + ref.gu_words, 72, ref.ng_d, 80)
            if bias_en:
                make_bias_tail(rng, image, base + ref.gu_words + ref.d_words)
            weights = [0x3F800000 | rng.randrange(0, 1 << 20) for _ in range(4)]
            slots = [(n_scen % 8) * 8 + l for l in range(4)]
            cmd = dict(base=base, n_tok=n_tok, weights=weights, slots=slots,
                       mask=(1 << n_tok) - 1)
            ctxw = make_ctx_words(fmt, base, bias_en)
            for i, wv in enumerate(ctxw):
                flits.append(ctrl_line(0, 1, 0x100 + 4 * i, wv))
            flits.append(ctrl_line(0, 1, 0x140, 0))
            pass_id = 5 + n_scen
            hbank = n_scen % 2
            ybank = n_scen % 2
            flits.append(dn_line('CMD', pass_id, 0, 0,
                                 cmd_payload(0, n_tok, base, hbank, ybank,
                                             slots, weights, n_scen)))
            staging = {'x': {}, 'xs': {}}
            for grp in range(3):
                for lane in range(n_tok):
                    val = int.from_bytes(
                        bytes(rng.randrange(120, 135) for _ in range(64)),
                        'little')
                    staging['xs'][(lane, grp)] = val
                    flits.append(dn_line('XS', pass_id, lane, grp, val))
                limit = 16 if grp == 2 else 32
                for i in range(limit):
                    for lane in range(n_tok):
                        val = int.from_bytes(
                            bytes(rng.randrange(1, 247) for _ in range(64)),
                            'little')
                        staging['x'][(lane, 32 * grp + i)] = val
                        flits.append(dn_line('X', pass_id, lane,
                                             32 * grp + i, val))
            if n_scen == 0:
                expect.append(initial_numeric_alarm(staging, pass_id))
                checks['errors'].append('NUMERIC')
            h = ref.gu(cmd, staging)
            expect.extend(ref.hup_beats(h, n_tok, pass_id))
            checks['sync1_gu'] += 1
            flits.append(dn_line('CMD', pass_id, 0, 0,
                                 cmd_payload(1, n_tok, base, hbank, ybank,
                                             slots, weights, n_scen)))
            # R4-025: true closed loop — the H broadcast carries this tile's
            # own golden h output in its 36 local columns (blocks 0 and 1);
            # columns 36..71 model the other tiles' gathered contributions
            for lane in range(n_tok):
                for idx in range(72):
                    hcodes = []
                    for j in range(32):
                        col = idx * 32 + j
                        if col < 36 and lane < n_tok:
                            hcodes.append(h[lane][col])
                        else:
                            hcodes.append(rng.choice(
                                [0x0000, 0x3F80, 0x4000, 0x4048, 0xBF80,
                                 0x4120, 0x38D1, 0x42F6]))
                    payload = 0
                    for j, c in enumerate(hcodes):
                        payload |= c << (16 * j)
                    flits.append(dn_line('H', pass_id, lane, idx, payload))
                    ref.store_h(lane, idx, *quantize_block(hcodes))
            ref.dphase(cmd, n_tok)
            ref.commit_y(cmd, ybank)
            checks['sync1_d'] += 1
            for lane in range(n_tok):
                tag = (ybank << 7) | (slots[lane] << 1)
                expect.extend(ref.drain_beats(ybank, slots[lane], 0, 80, 0,
                                              True, tag))
                flits.append(ctrl_line(0, 0,
                                       (ybank << 6) | slots[lane],
                                       (1 << 16) | (80 << 8)))
            n_scen += 1
    flits.append(dn_line('PGM', 0, 0, 0, 0))
    checks['errors'].append('RPGM')
    checks['errors'].append('UNSUPPORTED')
    flits.append(dn_line('CMD', 9, 0, 0,
                         cmd_payload(3, 0, 64, 0, 0, [0] * 4, [0] * 4, 0)))
    checks['errors'].append('CMD_ILLEGAL')
    checks['expected_err_status'] = (1 << 18) | (1 << 17) | (1 << 19) | (1 << 2)
    (out / 'flits.txt').write_text('\n'.join(flits) + '\n')
    (out / 'expect.txt').write_text('\n'.join(
        'U %d %02x %d %d %032x' % (b['type'], b['tag'], b['last'],
                                   b['segment'], b['payload'])
        for b in expect) + '\n')
    (out / 'rram.hex').write_text('\n'.join(
        '%08x %0256x' % (a, image[a]) for a in sorted(image)) + '\n')
    (out / 'checks.json').write_text(json.dumps(checks, indent=1))
    return dict(scenarios=n_scen, flits=len(flits), beats=len(expect),
                words=len(image))


def main_wrapper(outdir, seed=817):
    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(seed)
    stats = {'unit_lines': unit_vectors(random.Random(seed), out)}
    stats.update(build_scenarios(rng, out))
    return stats


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--outdir', required=True)
    ap.add_argument('--seed', type=int, default=817)
    args = ap.parse_args()
    print(json.dumps(main_wrapper(args.outdir, args.seed)))
    return 0


if __name__ == '__main__':
    sys.exit(main())


