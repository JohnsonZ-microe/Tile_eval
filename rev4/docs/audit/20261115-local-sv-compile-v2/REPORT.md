# Local SystemVerilog semantic compilation — 2026-11-15

## Result and boundary

pyslang 12.1.0 parsed and elaborated all eight distinct regression tops:
cells, math, compute, protocol, memory, yacc, control and tile. All returned
zero errors. The runner's `modules` selector aliases math and is not a ninth
distinct testbench. `checks.json` binds the compiler script, file list, RTL and
testbench bytes to this result. Individual compiler outputs are retained.

This is not VCS execution, RTL simulation, coverage closure, synthesis, timing
closure or PPA evidence. The CMD/retire admission-loss risk remains unresolved.
There is no newly received CMD_RETIRE VCS run in this audit.

## Defect corrected

The CMD_RETIRE probe referenced dn_valid, dn_payload and dn_sideband before
their module variable declarations. The first local compiler invocation
reported 14 use-before-declaration diagnostics. Those three declarations now
precede the probe; logic and initialization values were not changed.

The final tile compile has three warnings: the pre-existing scheduler empty
if body and two bench procedural static initializations. The seven other tops
each report the scheduler empty-body warning. Warnings are preserved in logs.

## Reproduction

Use a separate Python tools environment with `pyslang==12.1.0` installed, then:

    python -B Tile_eval/rev4/scripts/check_sv.py --test all --out <new-audit-directory>
    python -B -m unittest discover -s Tile_eval/rev4/model -p test_check_sv.py -v

The output directory must be new, so historic evidence cannot be overwritten.
The compiler is optional and is not added to the remote VCS dependencies.
In this session it was installed only under the Windows temporary tools path
and exposed with PYTHONPATH.

Three compiler-gate tests passed: valid HDL accepted, undeclared procedural
reference rejected, and probe-style use-before-declaration rejected. When the
optional dependency is absent these tests explicitly skip; they do not claim a
compiler pass. The checker itself exits with an error if the dependency is absent.

## Next hardware verification

Sync the corrected tb_tile_v4.sv before the directed VCS probe. The local
semantic pass does not establish that the same-edge command survives or that
its address/issuer/bank state is correct. Preserve the failing RTL snapshot
and directed VCS evidence before evaluating a scheduler repair.
