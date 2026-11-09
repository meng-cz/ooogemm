#!/usr/bin/env python3
"""Specialize the synthv2 hierarchy without synthesizing or flattening RTL.

Verilator supplies elaborated values and hierarchy; the token editor only
changes declarations, instance types, and heterogeneous generate loops.
Run from any directory. --check regenerates in a temporary tree and validates
both the checked-in files and every independent compilation file list.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import csv
from dataclasses import dataclass, field
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "staticsrc"
CACHE = ROOT / "build/staticsrc"
SCHEMA_VERSION = 1
TOKEN = re.compile(
    r'\s+|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\\\S+'
    r"|(?:\d+)?'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+|'[01xXzZ]"
    r'|[a-zA-Z_$][\w$]*|\d[\w.]*|::|\+\+|--|<=|>=|==|!=|&&|\|\||[^\s]',
    re.S,
)
INDEXED_SCOPE = re.compile(r"^(.*)\[(-?\d+)\]$")
STATIC_SCOPE = re.compile(r"^(.*)__static_(m\d+|\d+)$")


class GenerationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise GenerationError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def xml_name(name):
    # Verilator XML mixes display names and its internal escaping of '__'.
    return re.sub(r"__0([0-9A-Fa-f]{2})", lambda m: chr(int(m[1], 16)), name)


@dataclass(frozen=True)
class Token:
    text: str
    start: int
    end: int


def tokenize(text):
    return [Token(m[0], m.start(), m.end()) for m in TOKEN.finditer(text)
            if not m[0].isspace() and not m[0].startswith(("//", "/*"))]


def pairs(tokens):
    result, stack = {}, []
    closing = {")": "(", "]": "[", "}": "{", "end": "begin"}
    for i, token in enumerate(tokens):
        if token.text in ("(", "[", "{", "begin"):
            stack.append(i)
        elif token.text in closing:
            require(stack and tokens[stack[-1]].text == closing[token.text],
                    f"Unbalanced token {token.text} at offset {token.start}")
            start = stack.pop()
            result[start] = i
            result[i] = start
    require(not stack, "Unbalanced delimiters in source")
    return result


def split_parameters(tokens, matched, start, end):
    """Parse declaration boundaries, not constant expressions (including a,b)."""
    result, current_type, i = [], None, start
    while i < end:
        first, j = i, i
        while j < end and tokens[j].text != "=":
            if tokens[j].text in ("(", "[", "{"):
                j = matched[j] + 1
            else:
                j += 1
        require(j < end, "Parameter without initializer")
        name = tokens[j - 1].text
        if tokens[first].text == "parameter":
            first += 1
            current_type = " ".join(t.text for t in tokens[first:j - 1])
        elif j - 1 > first:
            current_type = " ".join(t.text for t in tokens[first:j - 1])
        require(current_type, f"Untyped parameter {name} is not supported")
        result.append((name, current_type))
        i = j + 1
        while i < end and tokens[i].text != ",":
            if tokens[i].text in ("(", "[", "{"):
                i = matched[i] + 1
            else:
                i += 1
        i += 1
    return result


@dataclass
class Site:
    module: str
    start: int
    type_end: int
    name_offset: int
    end: int
    override: tuple[int, int] | None


@dataclass
class Loop:
    start: int
    end: int
    body_start: int
    body_end: int
    label: str
    variable: str


@dataclass
class Unit:
    name: str
    path: Path
    text: str
    package: bool = False
    leading: str = ""
    tokens: list[Token] = field(init=False)
    matched: dict = field(init=False)
    name_span: tuple = field(init=False)
    parameter_span: tuple | None = field(init=False, default=None)
    parameters: list = field(init=False, default_factory=list)
    header_end: int = field(init=False)
    sites: list[Site] = field(init=False, default_factory=list)
    loops: list[Loop] = field(init=False, default_factory=list)

    def __post_init__(self):
        self.tokens = t = tokenize(self.text)
        self.matched = m = pairs(t)
        self.name_span = (t[1].start, t[1].end)
        i = 2
        if not self.package and t[i].text == "#":
            end = m[i + 1]
            self.parameter_span = (t[i].start, t[end].end)
            self.parameters = split_parameters(t, m, i + 2, end)
            i = end + 1
        if t[i].text == "(":
            i = m[i] + 1
        require(t[i].text == ";", f"Unsupported header: {self.name}")
        self.header_end = t[i].end

    def discover(self, names):
        t, m = self.tokens, self.matched
        for i, token in enumerate(t):
            if token.text in names and i + 2 < len(t):
                j, override = i + 1, None
                if t[j].text == "#" and t[j + 1].text == "(":
                    end = m[j + 1]
                    override = (t[j].start, t[end].end)
                    j = end + 1
                if j + 1 < len(t) and re.fullmatch(r"[\w$]+", t[j].text) and t[j + 1].text == "(":
                    end = m[j + 1] + 1
                    require(t[end].text == ";", f"Multiple instances per statement: {self.name}")
                    self.sites.append(Site(token.text, token.start, token.end,
                                           t[j].start, t[end].end, override))
            if token.text != "for" or i + 1 >= len(t) or t[i + 1].text != "(":
                continue
            close = m[i + 1]
            b = close + 1
            if b + 2 >= len(t) or t[b].text != "begin" or t[b + 1].text != ":":
                continue
            v = i + 2 + (t[i + 2].text == "genvar")
            end = m[b]
            # Named procedural loops are not used by the current source tree.
            self.loops.append(Loop(token.start, t[end].end, t[b + 2].end,
                                   t[end].start, t[b + 2].text, t[v].text))

    def offset(self, line, column):
        return sum(len(s) for s in self.text.splitlines(keepends=True)[:line - 1]) + column - 1


def load_units(paths):
    units = {}
    for path in paths:
        source = path.read_text()
        tokens = tokenize(source)
        i, previous_end = 0, 0
        while i < len(tokens):
            kind = tokens[i].text
            if kind not in ("module", "package"):
                i += 1
                continue
            name = tokens[i + 1].text
            end_kind = "endmodule" if kind == "module" else "endpackage"
            j = i + 2
            while j < len(tokens) and tokens[j].text != end_kind:
                j += 1
            require(j < len(tokens), f"Unterminated {kind} {name}")
            require(name not in units, f"Duplicate definition: {name}")
            units[name] = Unit(name, path, source[tokens[i].start:tokens[j].end],
                               package=(kind == "package"), leading=source[previous_end:tokens[i].start])
            previous_end = tokens[j].end
            i = j + 1
    names = {n for n, u in units.items() if not u.package}
    for unit in units.values():
        if not unit.package:
            unit.discover(names)
    return units


def constant(text):
    match = re.fullmatch(r"(\d+)'([sS]?)([bBoOdDhH])([\da-fA-F_]+)", text)
    require(match, f"Unsupported elaborated constant: {text}")
    width, sign, base, digits = match.groups()
    width = int(width)
    number = int(digits.replace("_", ""), {"b": 2, "o": 8, "d": 10, "h": 16}[base.lower()])
    if sign and number & (1 << (width - 1)):
        number -= 1 << width
    return number


class Types:
    def __init__(self, table):
        self.nodes = {x.get("id"): x for x in table.iter() if x.get("id")}
        self.cache = {}

    def get(self, ident):
        if ident in self.cache:
            return self.cache[ident]
        node = self.nodes[ident]
        kind = node.tag
        if kind == "refdtype":
            result = self.get(node.get("sub_dtype_id"))
        elif kind == "basicdtype":
            result = {"kind": kind, "name": node.get("name"),
                      "signed": node.get("signed") == "true"}
            if node.get("left") is not None:
                result["range"] = [int(node.get("left")), int(node.get("right"))]
        elif kind in ("packarraydtype", "unpackarraydtype"):
            result = {"kind": kind, "element": self.get(node.get("sub_dtype_id")),
                      "range": [constant(x.get("name")) for x in node.find("range")]}
        elif kind in ("structdtype", "uniondtype"):
            result = {"kind": kind, "signed": node.get("signed") == "true",
                      "members": [[x.get("name"), self.get(x.get("sub_dtype_id"))] for x in node]}
        elif kind == "enumdtype":
            result = {"kind": kind, "base": self.get(node.get("sub_dtype_id")),
                      "items": [[x.get("name"), constant(x.find("const").get("name"))] for x in node]}
        else:
            raise GenerationError(f"Unsupported public datatype: {kind}")
        self.cache[ident] = result
        return result


def typed_parameter(var, types):
    typ = types.get(var.get("dtype_id"))
    require(typ["kind"] == "basicdtype", f"Non-integral parameter: {var.get('name')}")
    width = abs(typ["range"][0] - typ["range"][1]) + 1 if "range" in typ else 1
    value = constant(var.find("const").get("name")) % (1 << width)
    signed = typ["signed"]
    if signed and value & (1 << (width - 1)):
        value -= 1 << width
    return {"type": typ, "value": value,
            "literal": (f"{width}'{'s' if signed else ''}d{value}" if value >= 0 else
                        f"{width}'sh{value % (1 << width):x}")}


def identity(original, parameters):
    return canonical([original, {n: {"type": p["type"], "value": p["value"]}
                                 for n, p in sorted(parameters.items())}])


def readable_name(original, parameters):
    if not parameters:
        return original
    templates = {
        "pe": [("L", "GEMM_LANE_NUM"), ("P", "PACC_NUM")],
        "sa": [("M", "SUBTILE_M"), ("N", "SUBTILE_N"), ("L", "LANE_NUM"), ("P", "PACC_NUM")],
        "paccreg": [("P", "PACC_NUM"), ("E", "PACC_EXP_WIDTH"), ("S", "PACC_SIG_WIDTH")],
        "fdot8e4m3": [("A", "ACC_WIDTH"), ("I", "PACC_IDX_WIDTH")],
        "sram1r1w": [("D", "SIZE"), ("W", "WIDTH")],
        "sram2r1w": [("D", "SIZE"), ("W", "WIDTH")],
    }
    fields = templates.get(original, [(n, n) for n in list(parameters)[:3]])
    summary = "_".join(label + str(parameters[name]["value"]).replace("-", "m")
                       for label, name in fields)
    return f"{original}__{summary}__{hashlib.sha256(identity(original, parameters).encode()).hexdigest()[:12]}"


@dataclass
class Occurrence:
    offset: int
    child: str
    scopes: tuple[str, ...]
    instance: str = ""
    connections: str = ""


@dataclass
class Spec:
    unit: Unit
    parameters: dict
    name: str
    ports: list
    occurrences: list[Occurrence]
    indexed_scopes: list[tuple[str, ...]]
    children: Counter
    expanded: list = field(default_factory=list)

    @property
    def key(self):
        return identity(self.unit.name, self.parameters)

    def connection_signatures(self):
        return Counter((o.child, tuple(normalized_scope(s) for s in o.scopes),
                        o.instance, o.connections) for o in self.occurrences)


def scope_matches(scopes, context):
    return all(f"{label}[{value}]" in scopes for label, value in context)


def apply_edits(text, start, end, edits):
    out, cursor = [], start
    for left, right, replacement in sorted(edits):
        require(cursor <= left <= right <= end, f"Overlapping source edits at {left}")
        out.extend((text[cursor:left], replacement))
        cursor = right
    out.append(text[cursor:end])
    return "".join(out)


def render_spec(spec, names):
    unit = spec.unit
    by_site = defaultdict(list)
    for occurrence in spec.occurrences:
        by_site[occurrence.offset].append(occurrence)

    def render(start, end, context=()):
        edits, unroll = [], []
        sites = [s for s in unit.sites if start <= s.start and s.end <= end]
        for site in sites:
            active = [o for o in by_site[site.name_offset] if scope_matches(o.scopes, context)]
            if len({o.child for o in active}) <= 1:
                continue
            loops = [loop for loop in unit.loops
                     if start <= loop.start <= site.start < site.end <= loop.end <= end
                     and loop.label not in dict(context)]
            require(loops, f"Cannot resolve heterogeneous instance in {spec.name} at {site.name_offset}")
            unroll.append(min(loops, key=lambda loop: loop.start))
        selected = []
        for loop in sorted(unroll, key=lambda loop: (loop.start, -loop.end)):
            if not any(x.start <= loop.start and loop.end <= x.end for x in selected):
                selected.append(loop)
        for loop in selected:
            values = set()
            for scopes in spec.indexed_scopes:
                if not scope_matches(scopes, context):
                    continue
                for scope in scopes:
                    match = INDEXED_SCOPE.fullmatch(scope)
                    if match and match[1] == loop.label:
                        values.add(int(match[2]))
            require(values, f"Missing elaborated iterations for {spec.name}.{loop.label}")
            blocks = []
            for value in sorted(values):
                body = render(loop.body_start, loop.body_end, context + ((loop.label, value),))
                label = loop.label + "__static_" + str(value).replace("-", "m")
                blocks.append(f"if (1) begin : {label}\n"
                              f"    localparam int {loop.variable} = {value};\n{body}\nend")
            edits.append((loop.start, loop.end, "\n".join(blocks)))
            entry = {"label": loop.label, "indices": sorted(values)}
            if entry not in spec.expanded:
                spec.expanded.append(entry)
        for site in sites:
            if any(loop.start <= site.start < loop.end for loop in selected):
                continue
            active = {o.child for o in by_site[site.name_offset] if scope_matches(o.scopes, context)}
            require(len(active) <= 1, f"Ambiguous source site in {spec.name}")
            if not active:
                edits.append((site.start, site.end, "/* Inactive instance in this fixed configuration. */"))
            else:
                edits.append((site.start, site.type_end, names[next(iter(active))]))
                if site.override:
                    edits.append((*site.override, ""))
        if start == 0:
            edits.append((*unit.name_span, spec.name))
            if unit.parameter_span:
                edits.append((*unit.parameter_span, ""))
            if unit.parameters:
                declarations = "\n\n    // Fixed elaborated parameters; this module has no overrides.\n"
                header = unit.text[slice(*unit.parameter_span)]
                comments = [m[0] for m in TOKEN.finditer(header) if m[0].startswith(("//", "/*"))]
                declarations += "".join("    " + comment + "\n" for comment in comments)
                for name, typ in unit.parameters:
                    declarations += f"    localparam {typ} {name} = {spec.parameters[name]['literal']};\n"
                edits.append((unit.header_end, unit.header_end, declarations))
        return apply_edits(unit.text, start, end, edits)

    return (f"// Generated by tools/generate_staticsrc.py; do not edit.\n"
            f"// Source: {unit.path.relative_to(ROOT).as_posix()}\n"
            + unit.leading + "\n`default_nettype none\n\n" + render(0, len(unit.text)) +
            "\n\n`default_nettype wire\n")


def parse_xml(path):
    # Verilator may put XML-1.0-invalid control references (e.g. &#30;) in
    # truncated diagnostic filenames. Preserve their spelling as text rather
    # than interpreting them as characters. RTL and valid references are intact.
    references = re.compile(r"&#(?:x[0-9a-fA-F]+|[0-9]+);")
    def valid_reference(match):
        token = match[0]
        number = int(token[3:-1], 16) if token.startswith("&#x") else int(token[2:-1])
        valid = number in (9, 10, 13) or 0x20 <= number <= 0xD7FF or 0xE000 <= number <= 0xFFFD or 0x10000 <= number <= 0x10FFFF
        return token if valid else "&amp;" + token[1:]
    parser = ET.XMLParser()
    tail = ""
    with path.open() as source:
        while chunk := source.read(1024 * 1024):
            text = tail + chunk
            split = text.rfind("&", max(0, len(text) - 32))
            if split < 0:
                split = len(text)
            parser.feed(references.sub(valid_reference, text[:split]))
            tail = text[split:]
    parser.feed(references.sub(valid_reference, tail))
    return parser.close()


class Verilator:
    def __init__(self):
        self.executable = shutil.which("verilator")
        require(self.executable, "verilator is not on PATH")
        self.version = subprocess.check_output([self.executable, "--version"], text=True).split()[1]
        self.cache = CACHE / "xml"
        self.cache.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="staticsrc-capability-") as tmp:
            path = Path(tmp)
            (path / "probe.sv").write_text("module probe; endmodule\n")
            result = subprocess.run([self.executable, "--xml-only", "-Wno-fatal", "--xml-output", str(path / "probe.xml"),
                                     "--Mdir", str(path / "obj"), str(path / "probe.sv")],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            require(result.returncode == 0 and (path / "probe.xml").exists(),
                    "This generator requires Verilator's XML interface (tested with 5.040); "
                    "use the matching Verilator version.\n" + result.stdout[-1500:])

    def elaborate(self, top, sources):
        logical_sources = []
        for path in sources:
            try:
                logical_path = path.relative_to(ROOT).as_posix()
            except ValueError:
                logical_path = path.name
            logical_sources.append([logical_path, path.read_text()])
        key = digest([self.version, top, logical_sources])
        output = self.cache / (key + ".xml")
        if not output.exists():
            with tempfile.TemporaryDirectory(prefix="staticsrc-verilator-") as tmp:
                result = subprocess.run(
                    [self.executable, "--xml-only", "--xml-output", str(output),
                     "--Mdir", str(Path(tmp) / "obj"), "--top-module", top,
                     "-Wno-fatal", *[str(p) for p in sources]], cwd=ROOT,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                (self.cache / (key + ".log")).write_text(result.stdout)
                if result.returncode:
                    output.unlink(missing_ok=True)
                    raise GenerationError(f"Elaboration failed for {top}:\n{result.stdout[-4000:]}")
        return parse_xml(output)


def port_signatures(module, types):
    return [{"name": v.get("origName", v.get("name")), "direction": v.get("dir"),
             "type": types.get(v.get("dtype_id"))} for v in module.findall("var") if v.get("dir")]


def expression_signature(node, types):
    """Ignore source locations and XML-local type ids, not connection logic."""
    attrs = {k: xml_name(v) for k, v in node.attrib.items() if k not in ("loc", "dtype_id")}
    if node.get("dtype_id"):
        attrs["datatype"] = types.get(node.get("dtype_id"))
    return [node.tag, attrs, [expression_signature(c, types) for c in node]]


def instance_connections(instance, types):
    return canonical([expression_signature(p, types) for p in instance])


def extract_specs(root, units):
    types = Types(root.find("./netlist/typetable"))
    files = {x.get("id"): Path(x.get("filename")) for x in root.find("files")}
    modules = root.findall("./netlist/module")
    keys, params = {}, {}
    for module in modules:
        original = module.get("origName", module.get("name"))
        require(original in units, f"Unknown elaborated module: {original}")
        parameters = {v.get("origName", v.get("name")): typed_parameter(v, types)
                      for v in module.findall("var") if v.get("param") == "true"}
        require(set(parameters) == {n for n, _ in units[original].parameters},
                f"Incomplete elaborated parameters for {original}")
        keys[module.get("name")] = identity(original, parameters)
        params[module.get("name")] = parameters
    specs = {}
    for module in modules:
        original = module.get("origName", module.get("name"))
        unit = units[original]
        occurrences, indexed = [], []
        source = unit.path.read_text()
        module_start = source.index(unit.text)
        line_starts = [0]
        line_starts.extend(m.end() for m in re.finditer("\n", source))

        def visit(node, scopes=()):
            for child in node:
                if child.tag == "begin":
                    inner = scopes + ((child.get("name"),) if child.get("name") else ())
                    if child.get("name") and INDEXED_SCOPE.fullmatch(child.get("name")):
                        indexed.append(inner)
                    visit(child, inner)
                elif child.tag == "instance":
                    file_id, line, column, *_ = child.get("loc").split(",")
                    require(files[file_id].resolve() == unit.path.resolve(),
                            f"Included instantiations not supported in {original}")
                    offset = line_starts[int(line) - 1] + int(column) - 1 - module_start
                    occurrences.append(Occurrence(offset, keys[child.get("defName")], scopes,
                                                  child.get("origName", child.get("name")),
                                                  instance_connections(child, types)))
                else:
                    visit(child, scopes)
        visit(module)
        known_sites = {s.name_offset for s in unit.sites}
        require(all(o.offset in known_sites for o in occurrences),
                f"Unmatched instance source location in {original}")
        p = params[module.get("name")]
        spec = Spec(unit, p, readable_name(original, p), port_signatures(module, types),
                    occurrences, indexed, Counter(o.child for o in occurrences))
        if spec.key in specs:
            require(spec.children == specs[spec.key].children and spec.ports == specs[spec.key].ports
                    and spec.connection_signatures() == specs[spec.key].connection_signatures(),
                    f"Inconsistent equivalent specializations in XML: {original}")
        else:
            specs[spec.key] = spec
    return specs


def package_dependencies(unit, packages):
    t = unit.tokens
    return {t[i].text for i in range(len(t) - 1)
            if t[i].text in packages and t[i + 1].text == "::"}


def dependency_order(start, edges):
    seen, active, ordered = set(), set(), []
    def visit(name):
        require(name not in active, f"Dependency cycle: {name}")
        if name in seen:
            return
        active.add(name)
        for child in sorted(edges[name]):
            visit(child)
        active.remove(name)
        seen.add(name)
        ordered.append(name)
    for name in sorted(start):
        visit(name)
    return ordered


def recursive_counts(key, specs):
    counts = Counter({key: 1})
    for child, multiplicity in specs[key].children.items():
        for descendant, count in recursive_counts(child, specs).items():
            counts[descendant] += multiplicity * count
    return counts


def generate(tool, output):
    paths = sorted((ROOT / "src").rglob("*.sv")) + sorted((ROOT / "synthv2").glob("*.sv"))
    units = load_units(paths)
    packages = {n: u for n, u in units.items() if u.package}
    pkg_edges = {n: package_dependencies(u, packages) for n, u in packages.items()}
    pkg_order = dependency_order(packages, pkg_edges)
    # Files defining packages precede all other source files, including when a
    # file contains both a package and a module (as in paccreg and sa).
    first = list(dict.fromkeys(packages[n].path for n in pkg_order))
    sources = first + [p for p in paths if p not in first]
    tops = [p.stem for p in sorted((ROOT / "synthv2").glob("*.sv"))]
    require(len(tops) == 9, f"Expected nine synthv2 tops, found {len(tops)}")
    specs, top_keys = {}, {}
    for top in tops:
        print(f"Resolve {top}", flush=True)
        current = extract_specs(tool.elaborate(top, sources), units)
        for key, spec in current.items():
            if key in specs:
                require(spec.children == specs[key].children and spec.ports == specs[key].ports
                        and spec.connection_signatures() == specs[key].connection_signatures(),
                        f"Inconsistent shared specialization: {spec.name}")
            else:
                specs[key] = spec
        top_keys[top] = identity(top, {})
    names = {k: s.name for k, s in specs.items()}
    require(len(set(names.values())) == len(names), "Specialization name/hash collision")
    module_files = {}
    result = {}
    for key, spec in sorted(specs.items(), key=lambda item: item[1].name):
        directory = Path("tops") if spec.unit.name in tops else spec.unit.path.relative_to(ROOT / "src").parent
        filename = (directory / (spec.name + ".sv")).as_posix()
        module_files[key] = filename
        result[filename] = render_spec(spec, names)
    pkg_files = {n: f"packages/{n}.sv" for n in packages}
    for name, unit in packages.items():
        result[pkg_files[name]] = ("// Generated shared package; do not edit.\n"
                                   f"// Source: {unit.path.relative_to(ROOT).as_posix()}\n"
                                   + unit.leading + "\n`default_nettype none\n\n" + unit.text + "\n\n`default_nettype wire\n")
    edges = {k: set(s.children) for k, s in specs.items()}
    filelists = {}
    for key, spec in sorted(specs.items(), key=lambda item: item[1].name):
        ordered = dependency_order([key], edges)
        needed_packages = set()
        for k in ordered:
            needed_packages.update(package_dependencies(specs[k].unit, packages))
        needed_packages = dependency_order(needed_packages, pkg_edges)
        files = [pkg_files[n] for n in needed_packages] + [module_files[k] for k in ordered]
        filelists[spec.name] = files
        # -F resolves each entry relative to this file list, independent of cwd.
        result[f"filelists/{spec.name}.f"] = "".join("../" + p + "\n" for p in files)
    totals = {top: recursive_counts(key, specs) for top, key in top_keys.items()}
    module_records = []
    for key, spec in sorted(specs.items(), key=lambda item: item[1].name):
        module_records.append({
            "name": spec.name, "original_module": spec.unit.name,
            "source": spec.unit.path.relative_to(ROOT).as_posix(), "file": module_files[key],
            "parameters": spec.parameters, "ports": spec.ports,
            "children": [{"module": names[k], "count": n} for k, n in
                         sorted(spec.children.items(), key=lambda item: names[item[0]])],
            "instances_by_top": {top: totals[top][key] for top in tops},
            "expanded_generate_blocks": spec.expanded,
        })
    sram_rows = []
    for key, spec in sorted(specs.items(), key=lambda item: item[1].name):
        if spec.unit.name not in ("sram1r1w", "sram2r1w"):
            continue
        depth, width = (spec.parameters[n]["value"] for n in ("SIZE", "WIDTH"))
        row = {"module": spec.name, "kind": spec.unit.name, "depth": depth, "width": width,
               "capacity_bits": depth * width, "read_ports": 1 if spec.unit.name == "sram1r1w" else 2,
               "write_ports": 1, "read_latency_cycles": 1, "same_address_read_write": "READ_FIRST"}
        for top in tops:
            row[top + "_instances"] = totals[top][key]
            row[top + "_total_bits"] = totals[top][key] * depth * width
        sram_rows.append(row)
    csv_buffer = io.StringIO(newline="")
    writer = csv.DictWriter(csv_buffer, fieldnames=list(sram_rows[0]), lineterminator="\n")
    writer.writeheader()
    writer.writerows(sram_rows)
    result["sram_inventory.csv"] = csv_buffer.getvalue()
    manifest = {"schema_version": SCHEMA_VERSION, "verilator_version": tool.version,
                "tops": tops, "packages": [{"name": n, "file": pkg_files[n],
                    "source": packages[n].path.relative_to(ROOT).as_posix()} for n in pkg_order],
                "modules": module_records, "filelists": filelists}
    result["manifest.json"] = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    result["README.md"] = render_readme(tops, specs, totals, sram_rows, names)
    for filename, text in result.items():
        path = output / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return specs, names, filelists, tops, result


def render_readme(tops, specs, totals, rows, names):
    lines = ["# Fixed SystemVerilog hierarchy", "",
             "Generated from the nine `synthv2` tops and their reachable `src` modules.",
             "Do not edit generated files; regenerate from the repository root:", "", "```bash",
             "python3 tools/generate_staticsrc.py", "python3 tools/generate_staticsrc.py --check", "```", "",
             f"There are **{len(specs)} unique modules**, including nine unchanged top names.",
             "Original overrideable parameters are fixed typed localparams. Fixed generate loops",
             "remain compact; only loops selecting different child specializations are expanded.",
             "Functions, sequential logic, reset behavior and simulation checks remain RTL.",
             "`OOOGEMM_ABLATION` is undefined. Existing `SYNTHESIS` guards are retained.", "",
             "Names contain readable configuration fields and a 12-digit SHA-256 suffix over",
             "the original module name and every effective typed parameter (including defaults).",
             "Identical parameter values share a module even when supplied with different expressions.",
             "Different original module names are never merged. Packages are defined once.", "",
             "Each `filelists/<module>.f` contains the complete standalone dependency closure.",
             "Use Verilator `-F`, which resolves entries relative to the file list:", "", "```bash",
             "verilator --lint-only -Wno-fatal --top-module L4W32 -F staticsrc/filelists/L4W32.f", "```", "",
             "No `src` or `synthv2` files are needed to compile this tree. For other tools, resolve",
             "file-list entries against their containing directory before passing source paths.",
             "`manifest.json` records all parameters, public port types, direct child counts and",
             "recursive per-top counts. It also records locally expanded generate labels/indices.", "",
             "## Explicit SRAM specializations", "",
             "Only `sram1r1w` and `sram2r1w` wrappers are inventoried. Internal arrays in other",
             "modules are not extracted or reclassified as SRAMs. These are behavioral RTL",
             "models, not precompiled hardware macros. All reads are synchronous (one cycle),",
             "writes are synchronous, and same-address simultaneous reads return the old value.", "",
             "| Module | Depth | Width | Bits/instance | Read/write ports |", "| --- | ---: | ---: | ---: | --- |"]
    for row in rows:
        lines.append(f"| `{row['module']}` | {row['depth']} | {row['width']} | {row['capacity_bits']} | {row['read_ports']}R1W |")
    lines += ["", "### SRAM counts per top", "",
              "| Top | 1R1W instances | 2R1W instances | Total explicit SRAM bits |",
              "| --- | ---: | ---: | ---: |"]
    for top in tops:
        one = sum(r[top + "_instances"] for r in rows if r["kind"] == "sram1r1w")
        two = sum(r[top + "_instances"] for r in rows if r["kind"] == "sram2r1w")
        bits = sum(r[top + "_total_bits"] for r in rows)
        lines.append(f"| `{top}` | {one} | {two} | {bits} |")
    lines += ["", "The CSV includes each specialization's count and total bits for every top.", "",
              "## Validation", "", "`--check` regenerates in a temporary directory, compares every generated file,",
              "elaborates all nine tops, and checks every specialization as an independent top.",
              "It compares public port datatypes, instance connections, child configurations and",
              "recursive counts against the original hierarchy. It rejects residual module",
              "parameters, parameter overrides and duplicate definitions. Unit tests additionally",
              "exercise typed deduplication, source editing and differential SRAM simulation.",
              "No synthesis, place-and-route or nine full C++ system simulations are run.", "",
              "Requires Python 3.10+ and an XML-capable Verilator (tested with 5.040).",
              "Verilator XML and logs are cached under ignored `build/staticsrc/`.", ""]
    return "\n".join(lines)


def normalized_scope(name):
    name = xml_name(name)
    match = STATIC_SCOPE.fullmatch(name)
    if match:
        value = match[2].replace("m", "-", 1)
        return f"{match[1]}[{value}]"
    return name


def validate(tool, output, specs, names, filelists, tops):
    expected = {s.name: s for s in specs.values()}
    inverse = {name: key for key, name in names.items()}
    generated_units = load_units(sorted(output.rglob("*.sv")))
    require(set(generated_units) == set(expected) | {u.name for u in generated_units.values() if u.package},
            "Generated definitions differ from manifest")
    for unit in generated_units.values():
        require(not unit.parameters and all(not site.override for site in unit.sites),
                f"Residual parameters/overrides: {unit.name}")
        require(not any(t.text in ("parameter", "defparam") for t in unit.tokens),
                f"Residual parameter declaration: {unit.name}")
    visited = set()
    ordered_names = tops + sorted(set(expected) - set(tops))
    for name in ordered_names:
        sources = [output / f for f in filelists[name]]
        root = tool.elaborate(name, sources)
        types = Types(root.find("./netlist/typetable"))
        modules = root.findall("./netlist/module")
        for module in modules:
            actual = xml_name(module.get("origName", module.get("name")))
            require(actual in expected, f"Unexpected generated child: {actual}")
            require(not any(v.get("param") == "true" for v in module.findall("var")),
                    f"Elaborated module still parameterized: {actual}")
            spec = expected[actual]
            require(port_signatures(module, types) == spec.ports, f"Port type mismatch: {actual}")
            aliases = {}
            for m in modules:
                for attr in ("name", "origName"):
                    aliases[m.get(attr)] = xml_name(m.get("origName", m.get("name")))
            children = Counter(inverse[aliases[i.get("defName")]] for i in module.iter("instance"))
            require(children == spec.children, f"Child configuration/count mismatch: {actual}")
            connections = Counter()
            def visit(node, scopes=()):
                for child in node:
                    if child.tag == "begin":
                        inner = scopes + ((normalized_scope(child.get("name")),) if child.get("name") else ())
                        visit(child, inner)
                    elif child.tag == "instance":
                        connections[(inverse[aliases[child.get("defName")]], scopes,
                                     child.get("origName", child.get("name")),
                                     instance_connections(child, types))] += 1
                    else:
                        visit(child, scopes)
            visit(module)
            require(connections == spec.connection_signatures(), f"Instance connection mismatch: {actual}")
            visited.add(actual)
        print(f"Validate {name}", flush=True)
    require(visited == set(expected), "Some specializations were not validated")


def compare_tree(output, rendered):
    existing = {p.relative_to(output).as_posix(): p.read_text() for p in output.rglob("*") if p.is_file()}
    differences = sorted(k for k in set(existing) | set(rendered) if existing.get(k) != rendered.get(k))
    require(not differences, "Generated tree is stale: " + ", ".join(differences[:12]))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="regenerate, compare and validate without changing staticsrc")
    args = parser.parse_args(argv)
    try:
        tool = Verilator()
        with tempfile.TemporaryDirectory(prefix="staticsrc-stage-") as tmp:
            stage = Path(tmp)
            specs, names, filelists, tops, rendered = generate(tool, stage)
            if args.check:
                compare_tree(OUTPUT, rendered)
                validate(tool, stage, specs, names, filelists, tops)
            else:
                old = OUTPUT / "manifest.json"
                # Remove only files owned by the previous generated manifest.
                if old.exists():
                    previous = json.loads(old.read_text())
                    owned = {m["file"] for m in previous["modules"]}
                    owned.update(p["file"] for p in previous["packages"])
                    owned.update("filelists/" + n + ".f" for n in previous["filelists"])
                    for filename in owned - set(rendered):
                        (OUTPUT / filename).unlink(missing_ok=True)
                for filename, text in rendered.items():
                    destination = OUTPUT / filename
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text(text)
            print(f"{'CHECK PASSED' if args.check else 'GENERATED'}: {len(tops)} tops, "
                  f"{len(specs)} unique modules, "
                  f"{sum(s.unit.name in ('sram1r1w', 'sram2r1w') for s in specs.values())} SRAM variants")
        return 0
    except (GenerationError, OSError, ET.ParseError, subprocess.SubprocessError) as exc:
        print(f"staticsrc: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
