#!/usr/bin/env python3
"""Convert static GEMM trace CSV rows into concrete batched GEMM sequences."""

from __future__ import annotations

import ast
import csv
import re
import sys
from dataclasses import dataclass
from pathlib import Path


NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class ExprError(ValueError):
    pass


@dataclass(frozen=True)
class Gemm:
    module: str
    op_kind: str
    b: int
    m: int
    n: int
    k: int


def usage() -> str:
    return (
        "usage: process_gemm_mnk.py INPUT.csv OUTPUT.txt VAR=VALUE [VAR=VALUE ...]\n"
        "example: process_gemm_mnk.py split_csv/Model_Prefill.csv out.txt B=1 S=2048 QH=40"
    )


def parse_bindings(args: list[str]) -> dict[str, int]:
    bindings: dict[str, int] = {}
    for arg in args:
        if "=" not in arg:
            raise ExprError(f"invalid argument {arg!r}; expected VAR=VALUE")
        name, raw_value = arg.split("=", 1)
        if not NAME_RE.match(name):
            raise ExprError(f"invalid variable name {name!r}")
        try:
            value = int(raw_value, 0)
        except ValueError as exc:
            raise ExprError(f"invalid value for {name}: {raw_value!r}; expected integer") from exc
        if value < 0:
            raise ExprError(f"invalid value for {name}: {value}; expected non-negative integer")
        bindings[name] = value
    return bindings


def eval_expr(expr: str, bindings: dict[str, int], *, row_desc: str) -> int:
    expr = expr.strip()
    if not expr:
        return 1
    try:
        tree = ast.parse(expr, mode="eval")
    except SyntaxError as exc:
        raise ExprError(f"{row_desc}: invalid expression {expr!r}") from exc
    value = eval_node(tree.body, bindings, expr, row_desc)
    if not isinstance(value, int):
        raise ExprError(f"{row_desc}: expression {expr!r} did not evaluate to an integer")
    return value


def eval_node(node: ast.AST, bindings: dict[str, int], expr: str, row_desc: str) -> int:
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.Name):
        if node.id not in bindings:
            raise ExprError(
                f"{row_desc}: unknown variable {node.id!r} in expression {expr!r}; "
                f"rerun with {node.id}=1 or the intended value"
            )
        return bindings[node.id]
    if isinstance(node, ast.UnaryOp):
        value = eval_node(node.operand, bindings, expr, row_desc)
        if isinstance(node.op, ast.UAdd):
            return value
        if isinstance(node.op, ast.USub):
            return -value
    if isinstance(node, ast.BinOp):
        lhs = eval_node(node.left, bindings, expr, row_desc)
        rhs = eval_node(node.right, bindings, expr, row_desc)
        if isinstance(node.op, ast.Add):
            return lhs + rhs
        if isinstance(node.op, ast.Sub):
            return lhs - rhs
        if isinstance(node.op, ast.Mult):
            return lhs * rhs
        if isinstance(node.op, ast.FloorDiv):
            if rhs == 0:
                raise ExprError(f"{row_desc}: division by zero in expression {expr!r}")
            return lhs // rhs
        if isinstance(node.op, ast.Div):
            if rhs == 0:
                raise ExprError(f"{row_desc}: division by zero in expression {expr!r}")
            if lhs % rhs != 0:
                raise ExprError(f"{row_desc}: expression {expr!r} is not integral")
            return lhs // rhs
    raise ExprError(f"{row_desc}: unsupported expression syntax {expr!r}")


def expr_references_name(expr: str, name: str, *, row_desc: str) -> bool:
    expr = expr.strip()
    if not expr:
        return False
    try:
        tree = ast.parse(expr, mode="eval")
    except SyntaxError as exc:
        raise ExprError(f"{row_desc}: invalid expression {expr!r}") from exc
    return any(isinstance(node, ast.Name) and node.id == name for node in ast.walk(tree))


def split_m_batch(expr: str, m: int, batch_count: int, bindings: dict[str, int], *, row_desc: str) -> tuple[int, int]:
    if batch_count != 1 or "B" not in bindings or not expr_references_name(expr, "B", row_desc=row_desc):
        return batch_count, m

    batch_size = bindings["B"]
    if batch_size <= 0:
        return batch_count, m
    no_batch_bindings = dict(bindings)
    no_batch_bindings["B"] = 1
    m_without_batch = eval_expr(expr, no_batch_bindings, row_desc=row_desc)
    if m == batch_size * m_without_batch:
        return batch_size, m_without_batch
    return batch_count, m


def projection_name(module: str) -> str:
    return module.rsplit(".", 1)[-1]


def merge_group(rows: list[Gemm]) -> Gemm | None:
    first = rows[0]
    if any(row.op_kind != "linear" for row in rows):
        return None
    if any(row.b != first.b or row.n != first.n or row.k != first.k for row in rows):
        return None
    return Gemm(
        module="+".join(projection_name(row.module) for row in rows),
        op_kind=first.op_kind,
        b=first.b,
        m=sum(row.m for row in rows),
        n=first.n,
        k=first.k,
    )


def merge_consecutive(gemms: list[Gemm]) -> list[Gemm]:
    merged: list[Gemm] = []
    i = 0
    while i < len(gemms):
        names3 = [projection_name(row.module) for row in gemms[i : i + 3]]
        if names3 == ["q_proj", "k_proj", "v_proj"]:
            group = merge_group(gemms[i : i + 3])
            if group is not None:
                merged.append(group)
                i += 3
                continue

        names2 = [projection_name(row.module) for row in gemms[i : i + 2]]
        if names2 == ["gate_proj", "up_proj"]:
            group = merge_group(gemms[i : i + 2])
            if group is not None:
                merged.append(group)
                i += 2
                continue

        merged.append(gemms[i])
        i += 1
    return merged


def read_gemms(path: Path, bindings: dict[str, int]) -> list[Gemm]:
    gemms: list[Gemm] = []
    with path.open(newline="") as fp:
        reader = csv.DictReader(fp)
        required = {"op_id", "module", "op_kind", "batch_dims", "M", "N", "K"}
        missing = required.difference(reader.fieldnames or [])
        if missing:
            raise ExprError(f"{path}: missing required columns: {', '.join(sorted(missing))}")
        for row in reader:
            row_desc = f"{path}:{reader.line_num} op_id={row.get('op_id', '')}"
            m = eval_expr(row["M"], bindings, row_desc=row_desc)
            n = eval_expr(row["N"], bindings, row_desc=row_desc)
            k = eval_expr(row["K"], bindings, row_desc=row_desc)
            batch_count = eval_expr(row["batch_dims"], bindings, row_desc=row_desc)
            if m <= 0 or n <= 0 or k <= 0:
                raise ExprError(f"{row_desc}: M/N/K must be positive, got {m} {n} {k}")
            if batch_count <= 0:
                raise ExprError(f"{row_desc}: batch_dims must be positive, got {batch_count}")
            b, m = split_m_batch(row["M"], m, batch_count, bindings, row_desc=row_desc)
            gemms.append(Gemm(row["module"], row["op_kind"], b, m, n, k))
    return gemms


def write_mnk(path: Path, gemms: list[Gemm]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as fp:
        for gemm in gemms:
            fp.write(f"{gemm.b} {gemm.m} {gemm.n} {gemm.k}\n")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(usage(), file=sys.stderr)
        return 2

    input_path = Path(argv[1])
    output_path = Path(argv[2])
    try:
        bindings = parse_bindings(argv[3:])
        gemms = merge_consecutive(read_gemms(input_path, bindings))
        write_mnk(output_path, gemms)
    except ExprError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
