def normalize(magnitude, quantum):
    if not magnitude:
        return 0, -126
    leading = magnitude.bit_length()-1
    exponent = max(leading+quantum, -126)
    distance = exponent-26-quantum
    if distance > 0:
        significand = (magnitude >> distance) | int(bool(magnitude & ((1 << distance)-1)))
    else:
        significand = magnitude << -distance
    return significand, exponent


def rounded(negative, magnitude, quantum):
    significand, exponent = normalize(magnitude, quantum)
    mantissa = (significand >> 3) + int(bool(significand & 4) and bool(significand & 11))
    if mantissa >= 1 << 24:
        mantissa >>= 1
        exponent += 1
    sign = int(negative) << 31
    if exponent > 127:
        return sign | 0x7f800000
    if not mantissa:
        return sign
    if exponent == -126 and mantissa < 1 << 23:
        return sign | mantissa
    return sign | ((exponent+127) << 23) | (mantissa & 0x7fffff)


def parts(value):
    exponent = (value >> 23) & 255
    mantissa = (value & 0x7fffff) | ((1 << 23) if exponent else 0)
    return value >> 31, exponent, mantissa


def nan(value):
    return value & 0x7fffffff > 0x7f800000


def inf(value):
    return value & 0x7fffffff == 0x7f800000


def add(left, right):
    if nan(left) or nan(right) or (inf(left) and inf(right) and (left ^ right) >> 31):
        return 0x7fc00000
    if inf(left) or inf(right):
        return left if inf(left) else right
    larger, smaller = sorted([left, right], key=lambda value: value & 0x7fffffff, reverse=True)
    sign, exponent, mantissa = parts(larger)
    small_sign, small_exp, small_mantissa = parts(smaller)
    distance = max(exponent, 1)-max(small_exp, 1)
    aligned = small_mantissa << 3
    aligned = (aligned >> distance) | int(bool(aligned & ((1 << distance)-1)))
    magnitude = (mantissa << 3)-aligned if sign != small_sign else (mantissa << 3)+aligned
    if magnitude == 0 and sign != small_sign:
        sign = 0
    return rounded(sign, magnitude, max(exponent, 1)-153)


def mul(left, right):
    sign, exponent, mantissa = parts(left)
    right_sign, right_exp, right_mantissa = parts(right)
    sign ^= right_sign
    if nan(left) or nan(right) or (inf(left) and not right_mantissa) or (inf(right) and not mantissa):
        return 0x7fc00000
    if inf(left) or inf(right):
        return (sign << 31) | 0x7f800000
    return rounded(sign, mantissa*right_mantissa, max(exponent, 1)+max(right_exp, 1)-300)


def shift(value, amount):
    if nan(value):
        return 0x7fc00000
    if inf(value):
        return value
    sign, exponent, mantissa = parts(value)
    return rounded(sign, mantissa, max(exponent, 1)-150+amount)


def scale(value, fmt, activation_scale, weight_scale):
    activation_exp = 0 if activation_scale == 255 else activation_scale-127
    if fmt in (0, 1):
        weight_exp = 0 if weight_scale & 255 == 255 else (weight_scale & 255)-127
        return shift(value, activation_exp+weight_exp)
    intermediate = shift(value, activation_exp)
    return intermediate if fmt == 5 else mul(intermediate, weight_scale if fmt == 2 else (weight_scale & 65535) << 16)
