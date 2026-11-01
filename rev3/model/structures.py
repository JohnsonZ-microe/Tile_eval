def cpa(left, right, width, chunk=32):
    blocks = (width+chunk-1)//chunk
    mask = (1 << chunk)-1
    sums = [((left >> (index*chunk)) & mask)+((right >> (index*chunk)) & mask) for index in range(blocks)]
    generate = [value >> chunk for value in sums]
    propagate = [(value & mask) == mask for value in sums]
    output = 0
    for index in range(blocks):
        carry = any(generate[origin] and all(propagate[origin+1:index]) for origin in range(index))
        output |= ((sums[index]+int(carry)) & mask) << (index*chunk)
    return output & ((1 << width)-1)


def compress(operands, width):
    mask = (1 << width)-1
    result = []
    for start in range(0, len(operands)-2, 3):
        first, second, third = operands[start:start+3]
        result += [first ^ second ^ third, ((first & second) | (first & third) | (second & third)) << 1 & mask]
    result += operands[len(operands)//3*3:]
    return result


def multiply24(left, right):
    mask = (1 << 12)-1
    operands = [(left & mask)*(right & mask), (left & mask)*(right >> 12) << 12,
                (left >> 12)*(right & mask) << 12, (left >> 12)*(right >> 12) << 24]
    operands = compress(compress(operands,48),48)
    return cpa(operands[0],operands[1],48,24)


def signed_sum(magnitudes, signs, width):
    mask = (1 << width)-1
    operands = [(value ^ mask) if negative else value for value,negative in zip(magnitudes,signs)]
    operands.append(sum(signs))
    while len(operands)>2:
        operands = compress(operands,width)
    return cpa(operands[0],operands[1],width)
