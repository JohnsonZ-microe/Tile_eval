from fractions import Fraction

CANON_NAN = 0x7FC00000
INF = 0x7F800000
FORMATS = ('fp4', 'fp8', 'fp8-f32', 'fp8-bf16', 'int4', 'bf16')


def power2(exponent):
    return Fraction(1 << exponent) if exponent >= 0 else Fraction(1, 1 << -exponent)


def fp_value(bits):
    sign = -1 if bits >> 31 else 1
    exponent = (bits >> 23) & 255
    mantissa = bits & 0x7FFFFF
    if exponent == 255:
        return 'nan' if mantissa else ('-inf' if sign < 0 else 'inf')
    return sign * (mantissa if exponent == 0 else (1 << 23) + mantissa) * power2(-149 if exponent == 0 else exponent - 150)


def round_even(value):
    quotient, remainder = divmod(value.numerator, value.denominator)
    return quotient + int(2 * remainder > value.denominator or (2 * remainder == value.denominator and quotient & 1))


def round_fp32(value, negative_zero=False):
    if isinstance(value, str):
        return {'nan': CANON_NAN, 'inf': INF, '-inf': INF | 0x80000000}[value]
    value = Fraction(value)
    sign = 0x80000000 if value < 0 or (value == 0 and negative_zero) else 0
    value = abs(value)
    if not value:
        return sign
    exponent = value.numerator.bit_length() - value.denominator.bit_length()
    if value < power2(exponent):
        exponent -= 1
    if exponent < -126:
        return sign | round_even(value / power2(-149))
    if exponent > 127:
        return sign | INF
    significand = round_even(value / power2(exponent - 23))
    if significand == 1 << 24:
        significand >>= 1
        exponent += 1
    if exponent > 127:
        return sign | INF
    return sign | ((exponent + 127) << 23) | (significand - (1 << 23))


def fp_add(left_bits, right_bits):
    left, right = fp_value(left_bits), fp_value(right_bits)
    if left == 'nan' or right == 'nan':
        return CANON_NAN
    if isinstance(left, str) or isinstance(right, str):
        if isinstance(left, str) and isinstance(right, str) and left != right:
            return CANON_NAN
        return round_fp32(left if isinstance(left, str) else right)
    return round_fp32(left + right, negative_zero=bool(left_bits & right_bits & 0x80000000))


def fp_mul(left_bits, right_bits):
    left, right = fp_value(left_bits), fp_value(right_bits)
    negative = bool((left_bits ^ right_bits) & 0x80000000)
    if left == 'nan' or right == 'nan':
        return CANON_NAN
    if isinstance(left, str) or isinstance(right, str):
        if left == 0 or right == 0:
            return CANON_NAN
        return INF | (0x80000000 if negative else 0)
    return round_fp32(left * right, negative_zero=negative)


def fp_shift(bits, amount):
    value = fp_value(bits)
    if isinstance(value, str):
        return round_fp32(value)
    return round_fp32(value * power2(amount), negative_zero=bool(bits >> 31))


def decode(code, fmt):
    if fmt == 5:
        return fp_value(code << 16)
    if fmt == 4:
        return Fraction(code - 16 if code & 8 else code)
    if fmt == 0:
        return (-1 if code & 8 else 1) * (Fraction(0), Fraction(1, 2), Fraction(1), Fraction(3, 2), Fraction(2), Fraction(3), Fraction(4), Fraction(6))[code & 7]
    if code & 127 == 127:
        return Fraction(0)
    exponent, mantissa = (code >> 3) & 15, code & 7
    return (-1 if code & 128 else 1) * (mantissa * power2(-9) if exponent == 0 else (8 + mantissa) * power2(exponent - 10))


def decode_bf16(code, fmt):
    if fmt == 5:
        return code
    negative_zero = (fmt == 0 and code == 8) or (fmt in (1, 2, 3) and code == 128)
    return round_fp32(decode(code, fmt), negative_zero=negative_zero) >> 16


def dot32(weight_codes, activation_codes, fmt):
    total = Fraction(0)
    infinity_signs = set()
    for weight_code, activation_code in zip(weight_codes, activation_codes):
        weight = decode(weight_code, fmt)
        activation = decode(activation_code, 1)
        if weight == 'nan':
            return CANON_NAN
        if isinstance(weight, str):
            if activation == 0:
                return CANON_NAN
            infinity_signs.add((weight == '-inf') != (activation < 0))
        else:
            total += weight * activation
    if len(infinity_signs) == 2:
        return CANON_NAN
    if infinity_signs:
        return INF | (0x80000000 if True in infinity_signs else 0)
    return round_fp32(total)


def apply_scale(partial, fmt, activation_scale, weight_scale):
    activation_exp = 0 if activation_scale == 255 else activation_scale - 127
    if fmt in (0, 1):
        weight_code = weight_scale & 255
        weight_exp = 0 if weight_code == 255 else weight_code - 127
        return fp_shift(partial, activation_exp + weight_exp)
    intermediate = fp_shift(partial, activation_exp)
    if fmt == 5:
        return intermediate
    return fp_mul(intermediate, weight_scale if fmt == 2 else (weight_scale & 65535) << 16)


def unpack(value, width, count):
    return [(value >> (width * index)) & ((1 << width) - 1) for index in range(count)]


def pack(values, width):
    return sum(value << (index * width) for index, value in enumerate(values))


class ArrayReference:
    def __init__(self):
        self.rf = [[0] * 4 for _ in range(80)]

    def execute(self, transaction):
        fmt = transaction['fmt']
        ncols = 8 if fmt in (0, 4) else (2 if fmt == 5 else 4)
        error = 0
        results = [0] * 32
        mask = transaction['mask']
        base = transaction['base']
        if fmt > 5 or base + ncols > 80 or not mask:
            return dict(results=0, error=2, colmask=0, mask=0, done=0)
        width = 4 if fmt in (0, 4) else (16 if fmt == 5 else 8)
        weights = unpack(transaction['weights'], width, ncols * 32)
        activations = unpack(transaction['activations'], 8, 128)
        ascales = unpack(transaction['ascales'], 8, 4)
        wscales = unpack(transaction['wscales'], 32, 8)
        if fmt in (1, 2, 3) and any(code & 127 == 127 for code in weights):
            error |= 1
        if fmt in (0, 1) and any(code & 255 == 255 for code in wscales[:ncols]):
            error |= 1
        for lane in range(4):
            if not (mask >> lane) & 1:
                continue
            activation = activations[lane * 32:(lane + 1) * 32]
            if ascales[lane] == 255 or any(code & 127 == 127 for code in activation):
                error |= 1
            for column in range(ncols):
                partial = dot32(weights[column * 32:(column + 1) * 32], activation, fmt)
                scaled = apply_scale(partial, fmt, ascales[lane], wscales[column])
                result = scaled if transaction['first'] else fp_add(self.rf[base + column][lane], scaled)
                self.rf[base + column][lane] = result
                results[column * 4 + lane] = result
        return dict(results=pack(results, 32), error=error, colmask=(1 << ncols) - 1, mask=mask, done=transaction['last'])
