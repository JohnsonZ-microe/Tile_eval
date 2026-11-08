"""Independent ROM audit and arithmetic probes; standard library only."""
from decimal import Decimal, localcontext
from fractions import Fraction
from pathlib import Path
import struct


def round_fp32_positive(value):
    ratio = Fraction(value)
    if not ratio:
        return 0
    numerator, denominator = ratio.numerator, ratio.denominator
    exponent = numerator.bit_length() - denominator.bit_length()
    if ratio < Fraction(2) ** exponent:
        exponent -= 1
    quantum = max(exponent - 23, -149)
    scaled = ratio / (Fraction(2) ** quantum)
    retained, remainder = divmod(scaled.numerator, scaled.denominator)
    twice = remainder * 2
    retained += twice > scaled.denominator or (
        twice == scaled.denominator and retained & 1)
    if exponent < -126:
        return retained
    if retained >= (1 << 24):
        retained >>= 1
        exponent += 1
    return ((exponent + 127) << 23) | (retained & 0x7fffff)


def sigmoid_decimal(code, precision=100, double_contract=False):
    magnitude = code & 0x7fff
    if magnitude > 0x7f80:
        return 0x7fc00000
    if magnitude == 0x7f80:
        return 0 if code & 0x8000 else 0x3f800000
    exponent = (magnitude >> 7) - 134
    significand = magnitude & 127
    if magnitude >> 7:
        significand += 128
    else:
        exponent = -133
    exact = Fraction(significand) * Fraction(2) ** exponent
    if code & 0x8000:
        exact = -exact
    if exact > 256:
        return 0x3f800000
    if exact < -256:
        return 0
    with localcontext() as context:
        context.prec = precision
        value = Decimal(exact.numerator) / Decimal(exact.denominator)
        if double_contract:
            exponential = float((-abs(value)).exp())
            result = (1.0 if value >= 0 else exponential) / (1.0 + exponential)
            return struct.unpack('>I', struct.pack('>f', result))[0]
        result = Decimal(1) / (Decimal(1) + (-value).exp())
        return round_fp32_positive(result)


def audit_rom(path, double_contract=True):
    words = Path(path).read_text().split()
    if len(words) != 65536:
        raise ValueError('ROM must contain exactly 65536 words')
    failures = []
    for code, text in enumerate(words):
        expected = sigmoid_decimal(code, double_contract=double_contract)
        actual = int(text, 16)
        if actual != expected:
            failures.append(dict(code=code, actual=actual, expected=expected))
    return failures
