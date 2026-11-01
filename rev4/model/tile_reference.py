"""Rev4 tile-level golden reference (bit-exact contract of RTL-TILE-FFN-004).

Imports the frozen revision-1 oracle (../../model/reference.py, hash-checked
by scripts/run.py) for FP32/dot32/scale semantics and adds:
  - fp32_to_bf16 / bf16 widen, V4.1 clamp helpers
  - sigmoid ROM table (identical bytes to scripts/gen_sigmoid_rom.py)
  - SwiGLU activation (V4.1 preset), mirroring pe4_act
  - h quantizer (pe4_quant): amax/e-selection/E4M3 encode incl. P5-5 rules
  - fp32 multiply (pe4_fmul mirror; cross-checked against oracle fp_mul)
  - TileReference: consumes a down-flit scenario and produces the expected
    up beats, mirroring the pe4_sched/pe4_yacc datapath exactly.
"""
import hashlib
import importlib.util
import math
import struct
import sys
from fractions import Fraction
from pathlib import Path


def _load_oracle():
    here = Path(__file__).resolve()
    for base in [here.parents[2] / 'model' / 'reference.py',
                 here.parents[1] / 'oracle' / 'reference.py',
                 here.parent / 'reference.py']:
        if base.exists():
            spec = importlib.util.spec_from_file_location('reference', base)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    raise ImportError('frozen revision-1 oracle reference.py not found')


reference = _load_oracle()
ArrayReference = reference.ArrayReference
CANON_NAN = reference.CANON_NAN
FORMATS = reference.FORMATS
fp_add = reference.fp_add
fp_mul = reference.fp_mul
fp_shift = reference.fp_shift
fp_value = reference.fp_value
round_fp32 = reference.round_fp32

NEG_INF32 = 0xFF800000
FP32_INF = 0x7F800000


def fp32(x):
    return struct.unpack('>I', struct.pack('>f', x))[0]


def of_fp32(bits):
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def is_nan32(b):
    return (b >> 23 & 0xFF) == 0xFF and (b & 0x7FFFFF) != 0


def fp32_to_bf16(x):
    """RNE truncate; NaN stays NaN (arith_cells 8), inf/finite take the
    rounding path. Mirrors pe4_pkg::fp32_to_bf16."""
    if (x >> 23 & 0xFF) == 0xFF and (x & 0x7FFFFF):
        return (x & 0x80000000) >> 16 | 0x7FC0   # canonical BF16 NaN
    t = (x + 0x7FFF + (x >> 16 & 1)) & 0xFFFFFFFF
    return t >> 16 & 0xFFFF


def widen(code):
    return (code << 16) & 0xFFFFFFFF


def fp32_ge(a, b):
    if a & 0x7FFFFFFF == 0 and b & 0x7FFFFFFF == 0:
        return True
    if (a >> 31) != (b >> 31):
        return not (a >> 31)
    if a >> 31:
        return (b & 0x7FFFFFFF) >= (a & 0x7FFFFFFF)
    return (a & 0x7FFFFFFF) >= (b & 0x7FFFFFFF)


def clamp(x, lo, hi):
    if is_nan32(x):
        return x
    if not fp32_ge(x, lo):
        return lo
    if not fp32_ge(hi, x):
        return hi
    return x


def _sigmoid_entry(code):
    if (code & 0x7F80) == 0x7F80 and (code & 0x7F):
        return 0x7FC00000
    v = of_fp32(widen(code))
    if math.isnan(v):
        return 0x7FC00000
    if math.isinf(v):
        return fp32(1.0 if v > 0 else 0.0)
    # frozen reference form (arith_cells 5): stable split, double -> FP32.
    # No cutoffs: the far negative tail keeps FP32 subnormals (R4-009)
    if v >= 0.0:
        s = 1.0 / (1.0 + math.exp(-v))
    else:
        e = math.exp(v)
        s = e / (1.0 + e)
    return fp32(s)


_CACHE = {}


def sigmoid(code):
    if not _CACHE:
        for c in range(65536):
            _CACHE[c] = _sigmoid_entry(c)
    return _CACHE[code]


def sigmoid_table_sha():
    payload = ''.join('%08x' % _sigmoid_entry(c) for c in range(65536))
    return hashlib.sha256(payload.encode() + b'\n' * 0).hexdigest()


def act_v41(g_bits, u_bits, w_bits, gb=0, ub=0):
    """V4.1 SwiGLU with GU bias (arith_cells 5):
    g1 = bf16(fp32(g + gb)), u1 = bf16(fp32(u + ub)) (gb/ub = +0.0 -> the
    add normalises -0), then clamp, sigmoid, v = fp32(fp32(g2*s)*u2),
    h = bf16(fp32(w * v)). Mirrors pe4_act."""
    g0 = fp_add(g_bits, widen(gb))
    u0 = fp_add(u_bits, widen(ub))
    g1 = widen(fp32_to_bf16(g0))
    u1 = widen(fp32_to_bf16(u0))
    g2 = clamp(g1, NEG_INF32, fp32(10.0))
    u2 = clamp(u1, fp32(-10.0), fp32(10.0))
    s = sigmoid(g2 >> 16)
    m1 = fp_mul(g2, s)
    m2 = fp_mul(m1, u2)
    m3 = fp_mul(m2, w_bits)
    return fp32_to_bf16(m3)


def fmul(a, b):
    """pe4_fmul mirror; unit-tested against the oracle fp_mul."""
    sa = a >> 31
    sb = b >> 31
    nan = is_nan32(a) or is_nan32(b)
    inf_a = (a >> 23 & 0xFF) == 0xFF and (a & 0x7FFFFF) == 0
    inf_b = (b >> 23 & 0xFF) == 0xFF and (b & 0x7FFFFF) == 0
    zero_a = (a & 0x7FFFFFFF) == 0
    zero_b = (b & 0x7FFFFFFF) == 0
    if nan:
        return CANON_NAN
    if (inf_a and zero_b) or (inf_b and zero_a):
        return CANON_NAN
    if inf_a or inf_b:
        return FP32_INF | ((sa ^ sb) << 31)
    if zero_a or zero_b:
        return (sa ^ sb) << 31
    ea = a >> 23 & 0xFF
    eb = b >> 23 & 0xFF
    if ea == 0:
        ma, ev = a & 0x7FFFFF, -149
    else:
        ma, ev = (a & 0x7FFFFF) | 0x800000, ea - 150
    if eb == 0:
        mb = b & 0x7FFFFF
        ev += -149
    else:
        mb = (b & 0x7FFFFF) | 0x800000
        ev += eb - 150
    prod = ma * mb
    sign = (sa ^ sb) << 31
    if prod == 0:
        return sign
    msb = prod.bit_length() - 1
    te = ev + msb                     # exponent for a [1,2) significand
    if te > 127:
        return FP32_INF | sign
    if te >= -126:
        if msb >= 23:
            shift = msb - 23
            sig = prod >> shift
            guard = (prod >> (shift - 1)) & 1 if shift > 0 else 0
            sticky = prod & ((1 << (shift - 1)) - 1) if shift > 0 else 0
            if guard and (sticky or sig & 1):
                sig += 1
        else:
            sig = prod << (23 - msb)
        if sig == 1 << 24:
            sig >>= 1
            te += 1
        if te > 127:
            return FP32_INF | sign
        return sign | ((te + 127) << 23) | (sig & 0x7FFFFF)
    # subnormal result
    shift = -(ev + 149)
    if shift >= 49:
        return sign
    q = prod >> shift
    guard = (prod >> (shift - 1)) & 1 if shift > 0 else 0
    sticky = prod & ((1 << (shift - 1)) - 1) if shift > 0 else 0
    if guard and (sticky or q & 1):
        q += 1
    if q >= 1 << 23:
        return sign | (1 << 23)
    if q == 0:
        return sign
    return sign | q


def e4m3_encode(x_bits, e):
    """Mirror of pe4_pkg::e4m3_encode: E4M3(x / 2^e) with x a finite FP32."""
    s = x_bits >> 31
    exp = (x_bits >> 23) & 0xFF
    if exp == 0:
        m25 = x_bits & 0x7FFFFF
        ex = -126
        if m25 == 0:
            return 0x80 if s else 0x00
    else:
        m25 = 0x800000 | (x_bits & 0x7FFFFF)
        ex = exp - 127
    ny = ex - e
    if ny >= -6:
        kept = m25 >> 20
        up = ((m25 >> 19) & 1) and (((m25 & 0x7FFFF) != 0) or (kept & 1))
        if up:
            kept = (kept + 1) & 0xF
            if kept == 0:
                kept = 8
                ny += 1
        if ny > 8 or (ny == 8 and (kept & 7) > 6):
            return 0xFE if s else 0x7E
        return (s << 7) | ((ny + 7) << 3) | (kept & 7)
    shift = 14 - ny
    if shift >= 26:
        return 0x80 if s else 0x00
    kept = m25 >> shift
    guard = (m25 >> (shift - 1)) & 1
    sticky = m25 & ((1 << (shift - 1)) - 1)
    if guard and (sticky or kept & 1):
        kept += 1
    if kept >= 8:
        return 0x88 if s else 0x08
    return (s << 7) | (kept & 7)


def e4m3_decode(code):
    """Exact Fraction value of an E4M3 code (test oracle)."""
    m = code & 7
    e = (code >> 3) & 0xF
    if e == 0:
        v = Fraction(m, 512)
    else:
        v = Fraction(8 + m, 8) * Fraction(2) ** (e - 7)
    return -v if code & 0x80 else v


def quantize_block(h_codes):
    """32 BF16 codes -> (32 E4M3 codes, se). Mirrors pe4_quant exactly."""
    FLOOR = 0x38D1B717
    nf = any((c & 0x7F80) == 0x7F80 for c in h_codes)
    amag = max([c & 0x7FFF for c in h_codes] + [FLOOR >> 16 & 0x7FFF])
    amax_bits = amag << 16
    e_norm = (amax_bits >> 23) - 127
    e_sel = e_norm - 8 if (amax_bits & 0x7FFFFF) <= 0x600000 else e_norm - 7
    out = []
    for c in h_codes:
        if (c & 0x7F80) == 0x7F80 and (c & 0x7F) != 0:
            out.append(0x00)                            # NaN -> 0
        elif (c & 0x7F80) == 0x7F80:
            out.append(0xFE if c & 0x8000 else 0x7E)    # +-inf -> +-448
        else:
            out.append(e4m3_encode(c << 16, 120 if nf else e_sel))
    se = 247 if nf else e_sel + 127
    return out, se


def e4m3_from_value(value, e, negative=False):
    """Independent brute-force E4M3 rounding oracle for unit tests."""
    target = Fraction(value) / (Fraction(2) ** e)
    best, bestd = 0, None
    for code in range(0x100):
        if code == 0x7F:
            continue                                   # NaN slot
        d = abs(e4m3_decode(code) - target)
        if bestd is None or d < bestd or (d == bestd and (code & 1) == 0
                                          and (best & 1) == 1):
            best, bestd = code, d
    if target > e4m3_decode(0x7E):
        best = 0x7E
    if target < e4m3_decode(0xFE):
        best = 0xFE
    if best in (0x00, 0x80) and bestd == abs(target):
        best = 0x80 if (negative or target < 0) else 0x00  # -0 -> 0x80
    return best


class TileRef(object):
    """Scenario-level golden: down flits in, expected up beats out.

    Mirrors pe4_sched/pe4_yacc deterministically: phase results are a pure
    function of the complete flit set, so the engine computes them at the
    phase boundaries of the scenario order (CMD GU -> X/XS -> CMD D -> H ->
    DRAIN). Weight streams follow the rev4 layout (docs/SPEC.md 5).
    """

    def __init__(self, image, fmt, bias_en=False):
        self.image = image
        self.fmt = fmt
        self.bias_en = bias_en
        self.ncols = 8 if fmt in (0, 4) else (2 if fmt == 5 else 4)
        self.ng_gu = (72 + self.ncols - 1) // self.ncols
        self.ng_d = (80 + self.ncols - 1) // self.ncols
        self.sw = 0 if fmt == 5 else (
            (72 * 8 + 1023) // 1024 if fmt in (0, 1) else
            (72 * 32 + 1023) // 1024 if fmt == 2 else (72 * 16 + 1023) // 1024)
        self.period = 4 if fmt in (2, 3) else 1
        self.gu_words = self._phase_words(160, self.ng_gu)
        self.d_words = self._phase_words(72, self.ng_d)
        # bias tail (data_bus 4.6): gate(36) up(36) down(80) BF16, entries
        # packed 64/word; GU reads the words covering bytes [0,144) = 0..1,
        # D rereads the boundary and reads words 1..2 for bytes [144,304)
        self.tail_words = (2 * (2 * 36 + 80) + 127) // 128
        self.gu_tail = list(range(0, (4 * 36 + 127) // 128))
        self.d_tail = list(range((4 * 36) // 128, self.tail_words))
        self.gb = [0] * 36
        self.ub = [0] * 36
        self.db = [0] * 80
        self.wbits = 8 if fmt in (0, 1) else (32 if fmt == 2 else 16)
        self.rf = ArrayReference()
        self.x = {}
        self.xs = {}
        self.h = {}
        self.hse = {}
        self.y = {}
        self.v = [set(), set()]

    def load_bias(self, phase, base):
        """Read the phase's bias tail words (before its matrix stream)."""
        if not self.bias_en:
            return
        tail_base = base + self.gu_words + self.d_words
        words = self.gu_tail if phase == 'GU' else self.d_tail
        for w in words:
            word = self.image[tail_base + w]
            for j in range(64):
                e = 64 * w + j
                code = (word >> (16 * j)) & 0xFFFF
                if phase == 'GU':
                    if e < 36:
                        self.gb[e] = code
                    elif e < 72:
                        self.ub[e - 36] = code
                else:
                    if 72 <= e < 152:
                        self.db[e - 72] = code

    def _phase_words(self, nkb, ngroups):
        return ((nkb + self.period - 1) // self.period) * self.sw + nkb * ngroups

    def _stream(self, base, nkb, ngroups):
        off = 0
        kb = 0
        while kb < nkb:
            if self.sw and kb % self.period == 0:
                for swi in range(self.sw):
                    yield ('scale', kb, swi, self.image[base + off])
                    off += 1
            for g in range(ngroups):
                yield ('weight', kb, g, self.image[base + off])
                off += 1
            kb += 1

    def _scales(self, word, swi, cols):
        eper = 1024 // self.wbits
        out = {}
        for i in range(eper):
            col = swi * eper + i
            if col < cols:
                out[col] = (word >> (self.wbits * i)) & ((1 << self.wbits) - 1)
        return out

    def _wslot(self, code):
        # pe3_scale reads weight_scale[15:0] for non-FP32 formats and widens
        # it, so a 16-bit scale must live in the LOW half of the 32-bit slot
        if self.wbits == 8:
            return code & 0xFF
        if self.wbits == 16:
            return code & 0xFFFF
        return code

    def run_phase(self, base, acts, ascales, mask, nkb, ngroups, cols):
        wsh = {}
        for kind, kb, x, word in self._stream(base, nkb, ngroups):
            if kind == 'scale':
                for col, code in self._scales(word, x, cols).items():
                    wsh[col] = self._wslot(code)
            else:
                activations = 0
                for lane in range(4):
                    activations |= acts(lane, kb) << (256 * lane)
                asc = 0
                for lane in range(4):
                    asc |= (ascales(lane, kb) & 0xFF) << (8 * lane)
                ws = 0
                for i in range(8):
                    col = x * self.ncols + i
                    if i < self.ncols:
                        ws |= wsh.get(col, 0) << (32 * i)
                self.rf.execute(dict(fmt=self.fmt, weights=word,
                                     activations=activations, ascales=asc,
                                     wscales=ws, mask=mask,
                                     base=x * self.ncols, first=(kb == 0),
                                     last=False))

    def gu(self, cmd, staging):
        """Compute the GU phase; returns h[lane][col] BF16 codes."""
        base = cmd['base']
        mask = (1 << cmd['n_tok']) - 1
        self.load_bias('GU', base)

        def acts(lane, kb):
            blk = staging['x'].get((lane, kb // 2), 0)
            return (blk >> (256 * (kb % 2))) & ((1 << 256) - 1)

        def ascales(lane, kb):
            grp = staging['xs'].get((lane, kb // 64), 0)
            return (grp >> (8 * (kb % 64))) & 0xFF
        self.run_phase(base, acts, ascales, mask, 160, self.ng_gu, 72)
        h = [[0] * 36 for _ in range(4)]
        for c in range(36):
            for lane in range(4):
                if mask >> lane & 1:
                    g = self.rf.rf[c][lane]
                    u = self.rf.rf[c + 36][lane]
                    h[lane][c] = act_v41(g, u, cmd['weights'][lane],
                                         self.gb[c], self.ub[c])
        return h

    def hup_beats(self, h, n_tok, tag):
        elements = []
        for lane in range(4):
            elements.extend(h[lane][c] if lane < n_tok else 0 for c in range(36))
        beats = []
        n = (36 * n_tok + 7) // 8
        for b in range(n):
            payload = 0
            for e in range(8):
                idx = 8 * b + e
                code = elements[idx] if idx < len(elements) else 0
                payload |= code << (16 * e)
            beats.append(dict(type=0, tag=tag, last=(b == n - 1),
                              segment=0, payload=payload))
        return beats

    def store_h(self, lane, idx, codes, se):
        self.h[(lane, idx)] = codes
        self.hse[(lane, idx)] = se

    def dphase(self, cmd, n_tok):
        base = cmd['base'] + self.gu_words
        mask = (1 << n_tok) - 1
        self.load_bias('D', cmd['base'])

        def acts(lane, kb):
            codes = self.h.get((lane, kb), [0] * 32)
            v = 0
            for j, c in enumerate(codes):
                v |= c << (8 * j)
            return v

        def ascales(lane, kb):
            return self.hse.get((lane, kb), 127)
        self.run_phase(base, acts, ascales, mask, 72, self.ng_d, 80)

    def commit_y(self, cmd, ybank):
        """fcomb 7b, WPLACE=h, VACC=0 (arith_cells 7b): the adds always run
        (b = +0.0 when bias disabled or not first), w multiplies the bias:
        t = bf16(fp32(d + fp32(w*b))); y = V ? fp32(y_old+t) : fp32(+0.0+t)."""
        for lane in range(4):
            if not (cmd['mask'] >> lane & 1):
                continue
            slot = cmd['slots'][lane]
            w = cmd['weights'][lane]
            vsnap = slot in self.v[ybank]
            for col in range(80):
                d = self.rf.rf[col][lane]
                b = widen(self.db[col]) if self.bias_en else 0
                wb = fmul(w, b)
                t = widen(fp32_to_bf16(fp_add(d, wb)))
                key = (ybank, slot, col)
                old = self.y.get(key, 0)
                self.y[key] = fp_add(old, t) if vsnap else fp_add(0, t)
            self.v[ybank].add(slot)

    def drain_beats(self, ybank, slot, start, count, segment, last_seg, tag):
        v0 = slot not in self.v[ybank]
        rows = list(range(start // 8, (start + count - 1) // 8 + 1))
        beats = []
        for r in rows:
            payload = 0
            for c in range(8):
                col = 8 * r + c
                if start <= col < start + count and not v0:
                    payload |= fp32_to_bf16(self.y[(ybank, slot, col)]) << (16 * c)
            beats.append(dict(type=1, tag=tag, last=False,
                              segment=segment, payload=payload))
        beats[-1]['last'] = True
        if last_seg and not v0:
            self.v[ybank].discard(slot)
        return beats


