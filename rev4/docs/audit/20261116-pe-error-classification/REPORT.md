# PE input error classification

The classifier consumes accepted PE transaction inputs (packed weights, activations, weight/activation scales, format, column base and token mask). It predicts the two error metadata bits implemented by tile_pe_v3, without accepting observed output or error signals.

Malformed format/base/mask yields transaction error bit 1 and suppresses numeric decode. Numeric bit 0 detects low-seven-bit 127 weight codes only for formats 1..3, UE8M0 255 weight scales only for formats 0/1 and enabled columns, and low-seven-bit 127 activations or scale 255 only for enabled token lanes. This is the RTL's explicit encoding validity rule, not a general IEEE arithmetic exception detector.

Four directed tests passed, sweeping all 128 activation positions and masked lanes, all eight weight-scale columns across six formats, both reserved-code signs, scale lane masks, column bounds and malformed transaction priority. No dynamic RTL comparison has been performed for this new classifier.

Remaining integration: independently reconstruct packed operands from memory and X/H streams at each predicted PE acceptance, propagate error metadata through the PE pipeline, apply top-level sticky-edge detection, and feed AlarmReplay using the actual slot identity. The outstanding real-credit mismatch is not yet resolved. No fixed event cycle or observed ALARM payload is used to generate errors.
