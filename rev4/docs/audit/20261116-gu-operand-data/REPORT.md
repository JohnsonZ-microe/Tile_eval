# Logical GU operand data reconstruction

select_gu_operands selects lower/upper 256-bit halves from raw X flits by kb%2 and the XS byte by kb%64, packing enabled token lanes as pe4_staging does. It rejects missing/duplicate active-lane identities and non-down observations. It assumes validated ownership and order, and does not model physical SRAM overwrite or data arrival timing. Inactive lanes are explicitly canonicalized to zero for masked classification only.

Two tests passed, including all 160 blocks across 1..4 tokens and negative input cases. checks.json records reserved activation codes and invalid activation scales reconstructed from the first GU of the received ordinary trace. Weight and weight-scale validity are not checked here, so this cannot establish the first numeric error or its timing. The actual-credit replay remains incomplete until operands and memory weights are paired with predicted accepted transactions.
