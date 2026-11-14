#!/usr/bin/env python3
"""Scan all rev4 RTL files for use-before-declaration in assign statements.

SystemVerilog requires identifiers to be declared before use in module scope.
This script finds `assign` statements whose RHS references identifiers that
are first declared LATER in the same file (potential IND errors).
"""
import re
import sys
from pathlib import Path

RTL = Path(__file__).resolve().parents[1] / 'rtl'

# match declarations: logic/wire name;  logic [N:0] name;  typedef ... name;
DECL = re.compile(
    r'^\s*(?:logic|wire|bit|reg|integer|int|string)\s+'
    r'(?:\[[^\]]+\]\s*)?(\w+)')
TYPEDEF = re.compile(r'typedef\s+\S+\s+(\w+)')
ENUM_VAL = re.compile(r'\b([A-Z][A-Z0-9_]*)\b')
ASSIGN = re.compile(r'^\s*assign\s+(\w+)\s*=\s*(.+?);?\s*$')
IDENT = re.compile(r'\b([a-zA-Z_]\w*)\b')
SKIP = {'assign','logic','wire','bit','signed','unsigned','int','integer',
        'string','true','false','or','and','not','xor'}

def scan(path):
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    declared = set()
    issues = []
    for i, line in enumerate(lines, 1):
        # track port declarations (input/output/inout logic [..] name)
        pm = re.match(r'\s*(?:input|output|inout)\s+\w+[^,)]*?(\w+)\s*[,);]', line)
        if pm:
            declared.add(pm.group(1))
        m = DECL.match(line)
        if m:
            declared.add(m.group(1))
        m = TYPEDEF.search(line)
        if m:
            declared.add(m.group(1))
        for m in ENUM_VAL.finditer(line):
            if m.group(1).isupper() and len(m.group(1)) > 1:
                declared.add(m.group(1))
        # also collect parameter/localparam
        pm = re.match(r'\s*(?:parameter|localparam)\s+.*?(\w+)\s*=', line)
        if pm:
            declared.add(pm.group(1))
        m = ASSIGN.match(line)
        if m:
            rhs = m.group(2)
            for idm in IDENT.finditer(rhs):
                ident = idm.group(1)
                if ident in SKIP or ident in declared or ident == m.group(1):
                    continue
                # check if declared later
                for j in range(i, len(lines)):
                    if re.search(
                        r'(?:logic|wire|bit|reg|integer|int|string)\s+'
                        rf'.*\b{ident}\b', lines[j]):
                        issues.append(f"  {path.name}:{i} "
                                      f"assign {m.group(1)} uses '{ident}' "
                                      f"first declared at line {j+1}")
                        break
                    dm = TYPEDEF.search(lines[j])
                    if dm and dm.group(1) == ident:
                        issues.append(f"  {path.name}:{i} "
                                      f"assign {m.group(1)} uses '{ident}' "
                                      f"(typedef) first at line {j+1}")
                        break
    return issues

for f in sorted(RTL.glob('*.sv')):
    issues = scan(f)
    if issues:
        print(f"{f.name}:")
        for issue in issues:
            print(issue)
print("--- scan complete ---")
